# BYO GitLab Runners on Tenant EC2 — Requirements & Recommendation

> Scope: allow a **tenant/customer AWS account** to provide the EC2 compute that runs
> their GitLab CI jobs ("BYO runners"), against our **self-managed GitLab Ultimate**
> instance. Covers the connection model, permissions, autoscaling, onboarding, cost
> tracking, and what config has to live in GitLab core.
> Status: research/planning — discharges the ticket's two ACs (define requirements,
> make recommendation).
> Verified against **GitLab / GitLab Runner 19.3** (latest release as of writing).
> Last updated: 2026-09-09.
>
> **Unconfirmed premise:** whether "customer account" means AWS accounts *inside our own
> Organization* (internal tenants) or accounts owned by *external* customers. The
> permission model differs materially — see §6. The companion audit prompt
> (`claude-prompt-audit-informal-byo-runners.md`) resolves this from the live AWS org.
>
> **Companion doc:** the platform-owned, instance-scoped **shared** fleet — and the
> provisioning options for it (cattle-ops Terraform module, AWS CodeBuild managed runners,
> Kubernetes executor) — is evaluated in `gitlab-shared-runner-eval.md`.

---

## TL;DR

- **A BYO runner is a trust decision, not a networking project.** The runner connects
  *outbound only* — HTTPS long-poll from the tenant's EC2 to our GitLab FQDN. We need
  **no inbound access to their VPC and no network path into their account** to make CI
  work. Most of the perceived "permissions required for access to EC2" disappears once
  that's understood; what's left is *operational* access, which is optional and should be
  time-bound.
- **Autoscaling is runner-driven, not ASG-driven.** One small persistent *runner manager*
  instance runs GitLab Runner Autoscaler (taskscaler → fleeting → `fleeting-plugin-aws`)
  and calls `SetDesiredCapacity` on an Auto Scaling Group whose own scaling policy is set
  to **none**. An ASG with target-tracking/step policies attached is a misconfiguration,
  not a feature.
- **Two clocks are already running.** `docker+machine` autoscaling was deprecated in
  17.5 and is **removed in GitLab 20.0 (May 2027)**; runner **registration tokens** are
  removed in the same release. Any existing runner using either is technical debt with a
  deadline.
- **GitLab will not tell you what these runners cost.** Compute minutes are *not*
  consumed by project or group runners — only by admin-managed instance runners and
  GitLab-hosted runners. All cost signal must come from the AWS side (resource tags →
  cost allocation tags → CUR). Activate those tags **before** the first onboard; tag
  activation is not retroactive.
- **Recommendation (§11):** `docker-autoscaler` executor + `fleeting-plugin-aws`, runner
  manager **in the tenant account**, runner registered **group-scoped** to the tenant's
  top-level group (never instance-scoped), shipped as a Terraform module we publish, with
  zero standing AWS access for us and a mandatory tag contract.

---

## 1. What "BYO runner" actually means here

| Concern | Owner | Notes |
|---|---|---|
| EC2 compute, AMI, ASG, VPC, egress | **Tenant** | They pay for it and it lives in their account. |
| `config.toml`, executor choice, concurrency | **Shared** | We publish the module + supported values; they apply it. |
| IAM instance profile on the runner manager | **Tenant** | Least-privilege policy we specify (§6.1). |
| Runner entity: scope, tags, `access_level`, `locked`, timeout | **Platform team (us)** | Lives in GitLab, not in their account. |
| Runner authentication token issue/rotate/revoke | **Platform team (us)** | Our only hard control point. |
| Job definitions (`.gitlab-ci.yml`, `tags:`) | **Tenant devs** | Against tag conventions we define (§3). |
| Fleet health, inventory, audit | **Platform team (us)** | Observable entirely from the GitLab side. |

The important consequence: **our leverage is the token and the runner record, not the
infrastructure.** If a tenant runner misbehaves, the remediation is "pause/delete the
runner in GitLab", which works without any access to their account.

---

## 2. How a tenant EC2 reaches GitLab core

### 2.1 Network model

- The runner **polls outbound** over HTTPS/443 to our GitLab FQDN (long polling for job
  requests, plus artifact/cache upload and trace streaming). There is **no inbound
  connection** from GitLab to the runner.
- Tenant-side requirement is therefore only **egress**: 443 to our GitLab FQDN (and to
  the object store endpoint if artifacts/cache go to S3 directly), plus whatever the jobs
  themselves need (package registries, Artifactory).
- If our GitLab is on a private FQDN, the tenant needs DNS resolution + a route —
  VPN/Transit Gateway/PrivateLink. **This is the one genuinely hard prerequisite** and it
  should be a gate in the intake form (§7).
- Behind a proxy: set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in the `gitlab-runner`
  systemd unit environment, not in the shell profile.
- Private CA on our GitLab: the runner needs the CA bundle at
  `/etc/gitlab-runner/certs/<gitlab-host>.crt`, and so do the *job* containers (they do
  not inherit the manager's trust store).

### 2.2 Token / registration model

Registration tokens are deprecated and removed in **20.0**. The current flow inverts the
old one — configuration is set in GitLab *first*, then the runner is registered:

1. Create the runner in GitLab (UI or `POST /user/runners`). At creation you set
   description, **tags**, run-untagged, protected, timeout, and the **scope** (instance /
   group / project).
2. GitLab returns a **runner authentication token** (`glrt-` prefix).
3. On the host: `gitlab-runner register --token "$GLRT" --url "https://<our-gitlab>"`
   — no `--tag-list`, no `--access-level`; those now live server-side.

One runner **record** can have many **runner managers** (each with its own `system_id`),
which is exactly the shape you get when a tenant runs an HA pair of managers. Audit at
the manager level, not the runner level — `GET /runners/:id/managers` exposes
`system_id`, `version`, `ip_address`, `executor`, `platform`, `architecture`,
`contacted_at`, `status`.

### 2.3 Verifying a runner is genuinely connected

`status` (`online` / `offline` / `stale` / `never_contacted`) plus `contacted_at` on each
manager. A `never_contacted` runner record with a live token issued is a **leaked-token
risk**, not a harmless leftover — treat unclaimed tokens as revocable after 7 days.

---

## 3. Runner scope — where to attach a tenant runner

| Scope | Who can create | Offered to | Queue | Use for tenant compute? |
|---|---|---|---|---|
| **Instance** | Admin only | **Every project on the instance** | Fair-usage | **Never.** Tenant-funded compute would run unrelated tenants' code. |
| **Group** | Group Owner | All projects + subgroups in that group | FIFO | **Yes — default choice.** Boundary matches the tenant boundary. |
| **Project** | Project Maintainer | One project (or several, if unlocked) | FIFO | Only for a genuinely single-project special case (e.g. a deploy runner holding prod credentials). |

Hardening to apply on every tenant runner record:

- `run_untagged = false` — force explicit `tags:` in `.gitlab-ci.yml`. Without this a
  tenant's runner silently picks up any untagged job in scope.
- `access_level = ref_protected` for anything that touches deployment credentials, so it
  only runs on protected branches/tags.
- `locked = true` on project runners, so they can't be spread to other projects.
- `maximum_timeout` set deliberately (a runaway job on an autoscaled fleet is a cost
  incident, not just a slow pipeline).
- **Disable instance runners for the tenant's group** if policy is "tenant compute only" —
  otherwise jobs quietly fall back to our shared fleet and we pay.

### Tag convention (mandatory — this is the CI capability contract)

`tenant:<slug>`, `env:<dev|test|prod>`, `arch:amd64|arm64`, `os:linux|windows`,
`exec:docker-autoscaler|instance|k8s`. Tags are the only thing a pipeline author sees, so
they must describe *capability*, and the runner record's description carries the
who/where.

---

## 4. Executor choice

| Executor | Job isolation | Autoscales EC2 | Fit |
|---|---|---|---|
| `shell` | None — jobs share the host | No | Never for multi-tenant. Found in the wild because it's the 5-minute setup. |
| `docker` | Container per job, fixed host | No | Fine for a small fixed-size runner; no elasticity. |
| **`docker-autoscaler`** | Container per job on an **ephemeral EC2 per job** | **Yes** | **Recommended** for containerised Linux/Windows jobs on EC2. |
| `instance` | **Whole VM per job** | Yes | When the job needs the raw VM: nested Docker, `privileged` builds, macOS/Windows. GA since Runner 17.1. |
| `kubernetes` | Pod per job | Via cluster autoscaler/Karpenter | Best answer **if the tenant already runs EKS** — no AMI to maintain, and it's what our Omni pipeline already assumes. |
| `docker+machine` | Container per job on ephemeral EC2 | Yes (legacy) | **Deprecated 17.5, removed 20.0.** Migration target only. |

---

## 5. Autoscaling — how it actually works

### 5.1 Architecture

```
GitLab core  ──(runner polls outbound 443)──  Runner manager EC2  (persistent, small)
                                                  │  taskscaler   (scaling logic/bookkeeping)
                                                  │  fleeting     (VM abstraction)
                                                  │  fleeting-plugin-aws
                                                  ▼
                                        Auto Scaling Group  (scaling policy = NONE)
                                                  │  SetDesiredCapacity / SetInstanceProtection
                                                  ▼
                                        Ephemeral job instances  ← manager connects over SSH
```

The runner manager is the only long-lived box. It is *not* in the ASG. Size it small
(t3.small/medium is ample for tens of concurrent jobs); it does no build work.

### 5.2 AWS prerequisites (all four are load-bearing)

1. **AMI** with Docker Engine installed and the login user in the `docker` group (plus
   git and the job toolchain if using the `instance` executor).
2. **ASG** with scaling policy **`none`** and **instance scale-in protection enabled** —
   the runner, not AWS, decides lifecycle. Without scale-in protection AWS will terminate
   instances mid-job.
3. **Suspend the `AZRebalance` process** if the ASG spans multiple AZs, or AWS will
   rebalance a running job out from under itself.
4. **IAM policy** on the runner manager's instance profile (§6.1).

### 5.3 Reference `config.toml` (docker-autoscaler + AWS)

```toml
concurrent = 10          # global ceiling on simultaneous jobs for this manager
check_interval = 3

[[runners]]
  name  = "tenant-acme-linux-amd64"
  url   = "https://gitlab.example.internal"
  token = "glrt-REDACTED"          # from the GitLab-side runner creation
  executor = "docker-autoscaler"

  [runners.docker]
    image = "public.ecr.aws/docker/library/alpine:3.20"
    privileged = false             # keep false; use the instance executor if a job needs more

  [runners.autoscaler]
    plugin = "aws"
    capacity_per_instance = 1      # one job per instance
    max_use_count         = 1      # instance destroyed after that job  → clean isolation
    max_instances         = 20     # hard cost ceiling

    [runners.autoscaler.plugin_config]
      name = "tenant-acme-runner-asg"   # the ASG name

    [runners.autoscaler.connector_config]
      username          = "ec2-user"
      use_external_addr = false     # manager and job instances share the VPC → private IPs

    [[runners.autoscaler.policy]]
      idle_count = 1                # warm capacity: latency vs money
      idle_time  = "20m0s"
```

### 5.4 Isolation vs cost — the one setting that matters

| Setting | Behaviour | Use when |
|---|---|---|
| `capacity_per_instance = 1`, `max_use_count = 1` | Ephemeral instance per job, destroyed after | **Default. Required for anything untrusted, MR pipelines from forks, or multi-team groups.** |
| `capacity_per_instance = 5+`, `max_use_count = 0` | Instances reused until idle timeout | Only for **trusted, single-team** jobs. GitLab's own docs are explicit that jobs sharing an instance have little isolation and can affect each other. |

`idle_count` is the main cost lever — idle warm instances bill 24/7. Start at 0–1 and
raise only if queue time (visible in the Ultimate fleet dashboard, §9) actually hurts.

### 5.5 Manager → job-instance connectivity

The manager connects to each job instance over **SSH**, pushing an ephemeral key via
`ec2-instance-connect:SendSSHPublicKey` (no long-lived key pair to manage — good). That
means a security group rule allowing **22 from the manager's SG to the job instances' SG**
inside the VPC. With `use_external_addr = false` no public IPs are needed and the fleet
can sit in private subnets with a NAT gateway for egress.

### 5.6 Spot instances

Supported (the IAM policy includes `ec2:DescribeSpotInstanceRequests`). An interruption
mid-job = a failed job, so pair it with job-level `retry:` and never put deploy jobs on
Spot. Good economics for build/test at `max_use_count = 1`.

---

## 6. Permissions — two different questions the ticket conflates

### 6.1 What the *runner* needs in the tenant account

Attach to the **runner manager's instance profile** (no IAM users, no static access keys
on disk). This is the plugin's own recommended policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:SetInstanceProtection",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "YOUR_AUTOSCALING_GROUP_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "ec2:DescribeInstances",
        "ec2:DescribeSpotInstanceRequests"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:GetPasswordData",
        "ec2-instance-connect:SendSSHPublicKey"
      ],
      "Resource": "arn:aws:ec2:YOUR_AWS_REGION:YOUR_AWS_ACCOUNT_ID:instance/*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/aws:autoscaling:groupName": "YOUR_AUTOSCALING_GROUP_NAME"
        }
      }
    }
  ]
}
```

Notes: `ec2:GetPasswordData` is **Windows only** — drop it for Linux fleets.
`SendSSHPublicKey` is only needed while `use_static_credentials = false` (the default).
If the ASG's launch template attaches an instance profile to job instances, the manager's
role also needs `iam:PassRole` scoped to that role. That's it — **nothing in this policy
touches data, S3, or secrets.** It is a defensible ask.

### 6.2 Where the runner manager lives — the real design fork

| | **Option A — manager in the tenant account** *(recommended)* | **Option B — central manager in our account** |
|---|---|---|
| IAM | Local instance profile, policy above | Cross-account `sts:AssumeRole`; the AWS fleeting plugin exposes only `profile` / `config_file` / `credentials_file`, so cross-account has to be done through an AWS **config profile** with `role_arn` + `credential_source = Ec2InstanceMetadata` — workable but undocumented by the plugin. **Verify before committing.** |
| Network | Manager and fleet in one VPC | Needs VPC peering / TGW for manager→job SSH |
| Blast radius | Contained per tenant | One compromised manager reaches every tenant |
| Our operational load | Tenant runs it; we own only the GitLab record | We run N managers |
| Cost attribution | Naturally lands in the tenant's bill | Manager cost lands on us, job cost on them |

**Take Option A.** Option B's only real advantage is central config, and that's better
solved by shipping a versioned Terraform module.

### 6.3 What *we* need in the tenant account

Start from **zero standing access** and justify upward. Runner health, job history, and
version drift are all visible through the GitLab API and the Ultimate fleet dashboard —
no AWS access required for day-to-day operations.

| | **Internal tenant accounts** (inside our AWS Org) | **External customer accounts** |
|---|---|---|
| Trust | Cross-account role assumed from our tooling account; conditions on our Org ID / principal | Customer-deployed role, trust policy **must** require an `ExternalId` we issue per customer |
| Scope | Read-only on EC2/ASG/IAM-read + SSM Session Manager for break-glass | Same, but expect them to negotiate it down |
| Enforcement | SCPs and org policy available to us | None — contractual only |
| Cost visibility | Free via Organization CUR in the payer account | **None.** We cannot see their Cost Explorer; cost is self-reported or estimated from job minutes |
| Onboarding artifact | Terraform module applied in their pipeline | CloudFormation/Terraform we publish, they apply, plus an attestation |

Hard rules either way:

- **No** `AdministratorAccess` / `PowerUserAccess` for us. Read-only + SSM.
- **No** long-lived IAM user access keys anywhere in the design.
- Break-glass access is **time-bound and audited** (assume-role with a session policy),
  via **SSM Session Manager**, never a shared SSH key.
- IMDSv2 required on manager and job instances (`http_tokens = required`) — the manager's
  role is precisely what a compromised job would want to steal.

---

## 7. Onboarding a tenant runner

### 7.1 Intake form (collect *before* any build)

| Field | Why it matters |
|---|---|
| AWS account ID + whether it's in our Organization | Decides the whole §6.3 permission model |
| Region(s) | Latency to GitLab, data residency |
| VPC / subnet IDs, NAT present?, egress path to our GitLab FQDN | The one hard prerequisite (§2.1) |
| GitLab top-level group path | Determines runner scope |
| Expected concurrency + peak | `concurrent`, `max_instances`, `idle_count` |
| **Job trust level** (single team / whole group / forks & MRs from outside) | Decides `max_use_count` (§5.4) |
| Job needs: Docker-in-Docker? GPU? Windows/macOS? arm64? | Executor + AMI + tags |
| Who pays, cost centre, owner, on-call contact | Cost tagging + who we page |
| Data classification of what the jobs touch | Whether Spot / instance reuse is acceptable at all |

### 7.2 Sequence

1. **Gate**: intake form complete; egress path to GitLab *proven* (a `curl` from a test
   instance in their subnet to our GitLab `/-/health`).
2. **Activate cost allocation tags** in the payer account if not already active — this is
   not retroactive, so it must precede the first instance (§8).
3. **Create the runner in GitLab** at group scope with tags, `run_untagged = false`,
   `access_level`, `maximum_timeout`. Record the runner ID.
4. **Tenant applies our Terraform module** (manager + ASG + launch template + instance
   profile + SGs + tags), passing the `glrt-` token via their secret store — never in a
   `.tfvars` in git.
5. **Register + verify**: manager appears under `GET /runners/:id/managers` with the
   expected version and executor.
6. **Canary pipeline**: a job tagged for that runner only, asserting it landed on the
   right runner, that a second concurrent job triggers a scale-out, and that the instance
   is terminated after the job.
7. **Record in the runner inventory** (our repo — the source of truth): runner ID, scope,
   tenant, account, region, ASG, owner, cost centre, executor, trust level, review date.
8. **Add to the review loop**: fleet dashboard, version-drift check, idle-cost check.

### 7.3 Offboarding (the half everyone forgets)

Delete the runner in **GitLab first** (kills the token and stops job assignment), *then*
destroy the AWS resources. Reverse order leaves jobs assigned to a dead fleet and a live
token in a decommissioned AMI. Sweep for stale runner records quarterly.

---

## 8. Cost tracking — yes, required, but not where you'd look

**GitLab gives you nothing here.** Compute minutes are consumed only by admin-managed
*instance* runners and GitLab-hosted runners; **project and group runners do not consume
compute minutes**. Since tenant runners should be group-scoped (§3), there is no
GitLab-side cost meter by design.

So cost tracking is an AWS exercise:

1. **Mandatory tag contract**, applied to the manager instance, the launch template
   (`propagate_at_launch = true`), the ASG, and the instance profile:

   | Tag | Example | Purpose |
   |---|---|---|
   | `gitlab:runner-id` | `4417` | Joins AWS spend to the GitLab runner record |
   | `gitlab:runner-scope` | `group/acme` | Which group's jobs |
   | `tenant` | `acme` | Attribution |
   | `cost-center` | `CC-4821` | Chargeback/showback key |
   | `owner` | `platform-team` / tenant email | Who to ask |
   | `env` | `prod` | Environment split |

2. **Activate them as cost allocation tags** in the payer account (only the payer can;
   takes up to ~24h and **is not retroactive** — activate before onboarding).
3. **Report from the CUR** grouped by `tenant` / `cost-center`. For internal tenants this
   feeds existing showback. For external customers the spend never hits our bill at all —
   our job is *attribution and guardrails*, not chargeback.
4. **The unit that matters is cost per job-minute.** Job minutes come from
   `GET /runners/:id/jobs`, or from the ClickHouse-backed fleet dashboard (§9). AWS spend
   ÷ job minutes is the number that tells you whether `idle_count` is set wrong.
5. **Guardrails, since the tenant's wallet is exposed:** `max_instances` as a hard
   ceiling, `maximum_timeout` on the runner record, an AWS budget alarm per tenant tag,
   and Spot for build/test where the data classification allows.

**Second-order cost the ticket doesn't mention:** Ultimate's security scanners (SAST,
DAST, dependency/container scanning) are *ordinary CI jobs*. Turning them on across
tenant projects increases tenant runner load — i.e. **the tenant pays for our compliance
programme**. Decide deliberately whether scanning jobs run on tenant runners or on a
platform-funded runner pinned by a pipeline execution policy. See
`gitlab-ultimate-what-we-get.md`.

---

## 9. What has to be associated with GitLab core

**In GitLab (ours to own):**

- The runner record: scope, description, `tag_list`, `access_level`, `run_untagged`,
  `locked`, `maximum_timeout`, paused state.
- Group CI/CD settings: instance runners enabled/disabled for the tenant group, group-level
  CI/CD variables (masked + protected), protected branches/environments that pair with
  `ref_protected`.
- **Runner fleet dashboard** (Admin → CI/CD → Runners → Fleet dashboard) — **Ultimate
  tier**, now unlocked. Shows CI errors caused by runner infrastructure, concurrent jobs
  on the busiest runners, and job queue times. *Runner usage* and *wait time to pick up
  job* additionally require the **ClickHouse integration** — treat that as a small
  follow-on project, and the main reason to bother is that it's the only place queue time
  is measured for you.
- **Audit events** for runner create/delete and token rotation.
- **Custom roles** (Ultimate) to create a runner-operator role instead of handing out
  group Owner just to manage runners.

**In the tenant account:** `config.toml`, AMI, ASG + launch template, instance profile,
security groups, tags.

**In our repo:** the Terraform module, the runner inventory, and the `tags:` convention
doc for pipeline authors.

---

## 10. Requirements (AC 1)

| # | Requirement | Priority | Ticket bullet |
|---|---|---|---|
| R1 | Runner connects outbound-only over 443 to our GitLab FQDN; no inbound path into the tenant VPC | MUST | permissions / connect to core |
| R2 | Tenant proves the egress/DNS path to our GitLab before any build | MUST | onboards |
| R3 | Runner registered with a **runner authentication token** (`glrt-`); no registration tokens | MUST | adding to GitLab config |
| R4 | Runner is **group-scoped** to the tenant's top-level group; never instance-scoped | MUST | adding to GitLab config |
| R5 | `run_untagged = false`; tags follow the `tenant:/env:/arch:/os:/exec:` convention | MUST | adding to GitLab config |
| R6 | Runner manager lives in the tenant account with a local instance profile | MUST | permissions |
| R7 | IAM limited to the fleeting recommended policy (§6.1); no admin, no static keys | MUST | permissions |
| R8 | Autoscaling via `docker-autoscaler` + `fleeting-plugin-aws`; ASG scaling policy `none`, scale-in protection on, `AZRebalance` suspended | MUST | autoscaling |
| R9 | `capacity_per_instance = 1`, `max_use_count = 1` unless the group is single-team and trusted | MUST | autoscaling |
| R10 | `max_instances` and `maximum_timeout` set as hard cost ceilings | MUST | cost tracking |
| R11 | Mandatory tag set applied and **activated as cost allocation tags before onboarding** | MUST | cost tracking |
| R12 | Cost reported from CUR by `tenant`/`cost-center`; cost per job-minute tracked | MUST | cost tracking |
| R13 | No standing AWS access for us; break-glass is time-bound assume-role via SSM | MUST | permissions |
| R14 | Every runner recorded in the inventory with owner, account, cost centre, trust level | MUST | onboards / documentation |
| R15 | Offboarding deletes the GitLab runner before destroying AWS resources | MUST | onboards |
| R16 | IMDSv2 required on manager and job instances | MUST | permissions |
| R17 | Delivered as a versioned Terraform module, not a runbook | SHOULD | onboards |
| R18 | ClickHouse integration enabled so fleet-dashboard queue-time metrics work | SHOULD | documentation to associate to core |
| R19 | Nothing left on `docker+machine` or registration tokens before **GitLab 20.0 (May 2027)** | SHOULD | — |
| R20 | External-customer variant uses `ExternalId` in the role trust policy | MUST *(if external)* | permissions |
| R21 | Decide who funds security-scanning jobs on tenant runners | SHOULD | cost tracking |

---

## 11. Recommendation (AC 2)

**Adopt a single supported pattern and refuse variants:**

> `docker-autoscaler` executor + `fleeting-plugin-aws`, runner manager **in the tenant
> account**, one manager per tenant per environment, runner registered **group-scoped**
> with mandatory tags and `run_untagged = false`, ephemeral single-use job instances,
> delivered as a versioned Terraform module, with **no standing AWS access for the
> platform team** and cost attributed through activated cost-allocation tags.

Choose `instance` executor only where jobs need the raw VM, and the `kubernetes` executor
where the tenant already runs EKS — same GitLab-side contract in both cases.

**Phasing:**

| Phase | Work | Exit criteria |
|---|---|---|
| 0 | **Audit the two existing informal runners** (see the companion prompt) | We know their scope, executor, IAM, provenance, whose account, and their risk register |
| 1 | Terraform module + intake form + one pilot tenant | Canary pipeline passes; scale-out and termination observed; tags visible in CUR |
| 2 | Bring the two informal runners onto the standard (or explicitly grandfather them with an expiry date) | Inventory complete; no `shell` executors; no registration tokens |
| 3 | Fleet dashboard + ClickHouse; version-drift and idle-cost reviews | Queue time and cost per job-minute reported monthly |

**Open questions to close before Phase 1:**

1. Internal tenants or genuine external customers? (Phase 0 answers this.)
2. Is our GitLab FQDN reachable from tenant VPCs today, or is TGW/PrivateLink work needed?
3. Who funds security-scanning compute (§8, R21)?
4. If anyone insists on Option B (central manager), verify cross-account assume-role
   through an AWS config profile actually works with `fleeting-plugin-aws` — it isn't
   documented as a plugin option.

---

## 12. Gotchas, ranked by how much they'll bite

1. **ASG scale-in protection off / own scaling policy attached** → AWS terminates
   instances mid-job. Presents as random, unreproducible job failures.
2. **Cost allocation tags not activated before onboarding** → the first weeks of spend are
   permanently unattributable. Not retroactive.
3. **`run_untagged = true` on a tenant runner** → it quietly picks up unrelated jobs in
   scope; the tenant funds work they didn't agree to.
4. **`max_use_count = 0` with untrusted jobs** → job-to-job contamination on a shared
   instance, which GitLab's own docs warn about explicitly.
5. **`idle_count` left high** → warm instances bill around the clock for queue latency
   nobody measured.
6. **`docker+machine` / registration tokens** → hard removal in **GitLab 20.0 (May
   2027)**. Silent today, breaking later.
7. **Multi-AZ ASG with `AZRebalance` active** → AWS rebalances a running job away.
8. **Private CA cert installed only on the manager** → jobs fail TLS inside containers.
9. **Deleting AWS resources before the GitLab runner record** → jobs assigned to a dead
   fleet, live token in a decommissioned image.
10. **`privileged = true` "to make Docker builds work"** → container escape onto the job
    instance, which holds the manager-adjacent IAM role. Use the `instance` executor or a
    rootless builder instead.

---

## Sources

- [GitLab Runner Autoscaling — overview](https://docs.gitlab.com/runner/runner_autoscale/)
- [GitLab Runner instance group autoscaler (taskscaler/fleeting architecture)](https://docs.gitlab.com/runner/runner_autoscale/gitlab-runner-autoscaler/)
- [Docker Autoscaler executor](https://docs.gitlab.com/runner/executors/docker_autoscaler/)
- [Instance executor](https://docs.gitlab.com/runner/executors/instance/)
- [`fleeting-plugin-aws` — recommended IAM policy & plugin_config](https://gitlab.com/gitlab-org/fleeting/plugins/aws)
- [Migrating to the new runner registration workflow](https://docs.gitlab.com/ci/runners/new_creation_workflow/)
- [Manage runners — instance/group/project scope](https://docs.gitlab.com/ci/runners/runners_scope/)
- [Runners API](https://docs.gitlab.com/api/runners/)
- [Compute minutes](https://docs.gitlab.com/ci/pipelines/compute_minutes/)
- [Runner fleet dashboard for administrators (Ultimate)](https://docs.gitlab.com/ci/runners/runner_fleet_dashboard/)
- [Plan and operate a fleet of instance or group runners](https://docs.gitlab.com/runner/fleet_scaling/)
- [Runner fleet configuration and best practices](https://docs.gitlab.com/topics/runner_fleet_design_guides/)
- [Docker Machine executor (deprecated 17.5, removed 20.0)](https://docs.gitlab.com/runner/executors/docker_machine/)
