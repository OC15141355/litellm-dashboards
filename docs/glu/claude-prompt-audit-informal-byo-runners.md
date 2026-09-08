# Claude Prompt — Audit the Two Informal BYO Tenant Runners

Copy the prompt below and give it to Claude Code **in the work environment**, in the repo
that holds our GitLab/AWS IaC (start it in the IaC repo root so it can grep provenance).

**Before you run it, make sure the session has:**

- `GITLAB_URL` and `GITLAB_TOKEN` exported — a PAT with `read_api` + `manage_runner`, held
  by an **Admin or Auditor** user (`GET /runners/all` and `/runners/:id/managers` need it).
- An authenticated AWS CLI (`aws sts get-caller-identity` succeeds), with the ability to
  assume into the tenant account(s) read-only.
- SSH or SSM Session Manager reachability to the two runner hosts.

This is a **read-only** audit. It exists to answer the questions
`gitlab-byo-runners.md` marks as unknown — above all: **are these EC2s in accounts inside
our own AWS Organization, or in a genuine external customer's account?**

---

## Prompt

You are auditing two informally-provisioned ("shadow") GitLab CI runners that already
exist on our self-managed GitLab instance, running on EC2 in what we believe is a
tenant/customer AWS account. Nobody documented them. I need a factual reconstruction of
how they are configured, who owns the compute, and what risk they carry.

**Deliverable:** write `docs/glu/byo-runner-audit-findings.md` containing the fact tables,
risk register, and gap analysis described in "Output" below. Do not summarise only in
chat — the file is the deliverable.

### Ground rules — read these first

- **Strictly read-only.** Do not register, pause, resume, delete, or edit any runner. Do
  not rotate or reset any token. Do not modify `config.toml`, restart `gitlab-runner`,
  apply Terraform, or change any AWS resource. No `terraform apply`, no `aws ec2 modify-*`,
  no `POST`/`PUT`/`DELETE` against the GitLab API.
- **Never print a secret.** Runner authentication tokens, CI/CD variable values, private
  keys, Artifactory creds: record only presence, location, and last 4 characters. If you
  find a secret committed in a repo or sitting world-readable on disk, record the file
  path and line number, mark it CRITICAL, and do not reproduce the value.
- **Cite every fact.** Each row in the output tables must name the command or file path it
  came from. If two sources disagree, record both and flag the conflict.
- **Say UNKNOWN.** If access is missing or a command fails, write `UNKNOWN — <reason>` and
  say exactly what access would resolve it. Do not infer a value from what is typical, and
  do not attempt to escalate your own permissions.
- Work through the phases in order. Phase 1 depends on Phase 0's output, and so on.

### Phase 0 — Establish ground truth from GitLab (do this first)

GitLab is authoritative for *what runners exist*. Start here so the AWS search in Phase 1
is targeted rather than a fishing expedition.

```bash
# All runners on the instance, with type and status
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/runners/all?per_page=100" | jq -r \
  '.[] | [.id, .runner_type, .name, .description, .active, .paused, .online, .status, (.tag_list|join(","))] | @tsv'
```

Then for each runner that looks non-standard (unfamiliar description, unexpected tags, an
executor or version out of line with the rest of the fleet):

```bash
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/runners/<ID>"          | jq .
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/runners/<ID>/managers" | jq .
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/runners/<ID>/jobs?per_page=100" | jq -r \
  '.[] | [.id, .status, .created_at, .started_at, .finished_at, .duration, .project.path_with_namespace, .ref, .user.username] | @tsv'
```

Record per runner: `id`, `runner_type` (instance/group/project), which group or projects it
is attached to, `tag_list`, `run_untagged`, `access_level` (`not_protected` vs
`ref_protected`), `locked`, `maximum_timeout`, `paused`, `description`, and from
`/managers`: every `system_id`, `version`, `executor`, `platform`, `architecture`,
`ip_address`, `contacted_at`, `status`.

From the jobs list, work out: which projects and namespaces actually use these runners,
how many jobs in the last 30 days, total job minutes, whether any job ran on a protected
ref, and whether any job came from a fork or an external contributor.

If a runner is **group-scoped**, also check whether instance runners are enabled for that
group (jobs may be silently falling back to our shared fleet, or vice versa).

State plainly which two runners you have identified as the informal ones and the evidence
you used. If more than two look informal, report all of them and say so.

### Phase 1 — Map each GitLab runner to real AWS resources, and identify the account

Use the `ip_address` from each runner manager as the pivot.

```bash
aws sts get-caller-identity
aws ec2 describe-network-interfaces \
  --filters "Name=addresses.private-ip-address,Values=<IP>" \
  --query 'NetworkInterfaces[].{Eni:NetworkInterfaceId,Instance:Attachment.InstanceId,Vpc:VpcId,Subnet:SubnetId}'
# fall back to public IP if the manager reports one
aws ec2 describe-instances --filters "Name=ip-address,Values=<IP>"
```

**Then answer the central question — whose account is this?**

```bash
aws organizations describe-organization                 # are we in an Org, and are we the payer?
aws organizations list-accounts --query 'Accounts[].{Id:Id,Name:Name,Email:Email,Status:Status}'
aws organizations describe-account --account-id <ACCOUNT_ID>
```

If the account ID hosting the runner appears in `list-accounts`, it is an **internal
tenant** account inside our Organization. If it does not — or if `describe-organization`
fails from our position — it may be a genuine **external customer** account; say so
explicitly and record how you established it (account ID, alias via
`aws iam list-account-aliases`, Org membership, and the role/path you used to reach it).
This single finding changes the entire permission model, so make it the first line of the
findings doc.

For each instance found, record: instance ID, account ID + alias, region, AZ, instance
type, AMI ID and its name/creation date, VPC/subnet, whether the subnet is public
(route to an IGW) or private, all security groups with their inbound/outbound rules, the
attached instance profile, IMDS configuration (`MetadataOptions.HttpTokens` — is IMDSv2
required?), all resource tags, and `LaunchTime`.

### Phase 2 — Is there any autoscaling at all?

```bash
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,LT:LaunchTemplate,Suspended:SuspendedProcesses,Protect:NewInstancesProtectedFromScaleIn,AZs:AvailabilityZones,Tags:Tags}'
aws autoscaling describe-policies --auto-scaling-group-name <ASG>
aws ec2 describe-launch-template-versions --launch-template-id <LT> --versions '$Latest'
```

Determine and state: is each runner a **standalone hand-built EC2** or backed by an ASG?
If an ASG exists, check the three settings that break autoscaled runners —
(a) is `NewInstancesProtectedFromScaleIn` **true**? (b) are there scaling policies
attached that should not be there (the runner must own capacity, so the ASG's own policy
should be none)? (c) if multi-AZ, is `AZRebalance` in `SuspendedProcesses`?

Decode the launch template's user-data (base64) and record what it does — especially
whether it installs `gitlab-runner`, whether it registers using a **registration token**
(legacy, removed in GitLab 20.0) or an authentication token (`glrt-` prefix), and whether
any credential is baked into user-data (CRITICAL if so — user-data is readable by anything
that can reach IMDS).

### Phase 3 — Reconstruct the runner configuration on the host

Prefer SSM Session Manager over SSH. Read, do not edit.

```bash
sudo cat /etc/gitlab-runner/config.toml          # REDACT the token: keep last 4 only
gitlab-runner --version
systemctl cat gitlab-runner
systemctl status gitlab-runner --no-pager
sudo ls -la /etc/gitlab-runner/                  # note file modes; config.toml should be 0600 root
ls -la /etc/gitlab-runner/certs/ 2>/dev/null
sudo journalctl -u gitlab-runner --since '7 days ago' | tail -200
docker info 2>/dev/null | head -30
ls -la ~/.aws /root/.aws 2>/dev/null             # static AWS keys on disk = finding
env | grep -i proxy
```

From `config.toml` record: `concurrent`, `check_interval`, and per `[[runners]]` the
`executor`, `url`, `[runners.docker]` settings (**`privileged`**, `volumes` — is
`/var/run/docker.sock` mounted?, `pull_policy`, `allowed_images`),
`[runners.autoscaler]` (`plugin`, `capacity_per_instance`, `max_use_count`,
`max_instances`, `plugin_config`, `connector_config`, and every
`[[runners.autoscaler.policy]]` `idle_count`/`idle_time`), or `[runners.machine]` if this
is the legacy `docker+machine` autoscaler, or `[runners.kubernetes]`.

Flag immediately: `executor = "shell"` (no isolation between jobs), `privileged = true`,
a mounted Docker socket, `[runners.machine]` (deprecated 17.5, **removed in GitLab 20.0**),
`capacity_per_instance` or `max_use_count` allowing instance reuse, absent `max_instances`,
and any static AWS credentials on disk instead of an instance profile.

### Phase 4 — Provenance: was any of this ever in code?

Search the IaC repos before concluding it was hand-built:

```bash
grep -rniE 'gitlab.runner|gitlab_runner|glrt-|runner[-_]?token|fleeting|docker-autoscaler|docker\+machine|taskscaler' . --include='*.tf' --include='*.tfvars' --include='*.yml' --include='*.yaml' --include='*.toml' --include='*.sh' --include='*.json' -l
grep -rniE '<instance-id>|<asg-name>|<ami-id>' . -l
```

Also check for Terraform state containing these resources, any Ansible/Chef/Packer
material that built the AMI, and `git log` on whatever you find (who created it, when,
which MR — or whether it was never in an MR at all).

Then classify each runner's provenance: **IaC-managed**, **IaC-drifted** (in code but the
live resource differs — say exactly how), or **hand-built** (no code at all).

Also check the IAM side of provenance:

```bash
aws iam get-instance-profile --instance-profile-name <NAME>
aws iam list-attached-role-policies --role-name <ROLE>
aws iam list-role-policies --role-name <ROLE>
aws iam get-role-policy --role-name <ROLE> --policy-name <POLICY>
aws iam get-role --role-name <ROLE>   # trust policy: who can assume it, is there an ExternalId?
```

Compare the effective permissions against the least-privilege baseline
(`autoscaling:SetDesiredCapacity`, `SetInstanceProtection`,
`TerminateInstanceInAutoScalingGroup` on one ASG ARN;
`autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeInstances`,
`ec2:DescribeSpotInstanceRequests`; `ec2-instance-connect:SendSSHPublicKey` scoped by ASG
tag). Call out every permission beyond that — especially any managed policy such as
`AmazonEC2FullAccess`, `AmazonS3FullAccess`, `PowerUserAccess`, or
`AdministratorAccess` — and whether the role can read Secrets Manager, S3 data buckets, or
assume other roles.

### Output — write `docs/glu/byo-runner-audit-findings.md`

Structure it as:

1. **Answer up front** — internal tenant account(s) or external customer account(s)? State
   the account IDs, aliases, and the evidence.
2. **Runner fact table**, one column per runner: GitLab ID, scope + attached group/projects,
   tags, `run_untagged`, `access_level`, `locked`, `maximum_timeout`, runner version,
   executor, autoscaling (none / docker-autoscaler / docker+machine / kubernetes), AWS
   account + region, instance ID(s), ASG or standalone, instance profile, IMDSv2 required?,
   tags present on the AWS resources, provenance, jobs in last 30 days, job minutes,
   projects served, last contact.
3. **Configuration detail** per runner — the redacted `config.toml` essentials and the
   decoded user-data behaviour.
4. **Risk register** — table of `ID | finding | severity (CRITICAL/HIGH/MED/LOW) | evidence
   (command or path) | why it matters | remediation`. Rank by severity. Include at minimum
   an explicit verdict on each of: token type in use, `shell` executor, `privileged`,
   Docker socket mount, IAM over-scope, static credentials on disk, IMDSv1 allowed, public
   subnet + public IP, missing scale-in protection, missing `max_instances`, instance reuse
   across untrusted jobs, `run_untagged = true`, instance-scoped runner funded by a tenant,
   secrets in user-data or git, and stale/never-contacted runner records.
5. **Gap analysis vs the target standard** — read `docs/glu/gitlab-byo-runners.md` in this
   repo and produce a table of its requirements R1–R21 with PASS / FAIL / N/A / UNKNOWN per
   runner, plus a one-line note on what closing each gap would take.
6. **Migration verdict per runner** — one of: *bring onto the standard* (list the changes),
   *rebuild from the module* (cheaper than fixing), or *decommission* (nobody uses it —
   support this with the job counts). Note explicitly whether it is blocked by the GitLab
   20.0 removals.
7. **UNKNOWNs and the access needed to close them.**

Do not make recommendations that require access you did not have. Where you could not
verify something, the finding is "unverified", not "fine".
