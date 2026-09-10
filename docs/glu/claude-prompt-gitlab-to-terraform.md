# Claude Prompt — Codify the GitLab Instance into Terraform

Copy the prompt below and give it to Claude Code **in the work environment**, started in
the repo that will hold the GitLab Terraform (or the existing IaC repo root).

**Before running it, the session needs:**

- `GITLAB_URL` and `GITLAB_TOKEN` — a PAT for an **Administrator** (or a dedicated
  **service account** with Admin) carrying `api` scope. Read-only work only, but the
  inventory endpoints require admin.
- `kubectl` context pointing at the cluster running GitLab, and `helm` on PATH.
- An authenticated AWS CLI for the account hosting the deployment.
- Terraform **1.5+** on PATH (needed for `import` blocks and
  `plan -generate-config-out`).

**Read first:** `docs/glu/gitlab-ultimate-best-practices.md` in this repo. It contains the
licence/activation rules, the two-layer split, the authoritative provider resource
inventory, and the traps (`gitlab_application_settings` being experimental with a no-op
destroy; project replacement destroying repositories). The prompt below assumes it.

**Answer to the question that prompted this ticket:** the licence must be **activated
first** — an unlicensed instance exposes Free features only, and ~a dozen provider
resources are Ultimate-gated. The licence itself is **not** codifiable (no provider
resource; the License API takes legacy licence strings, not cloud activation codes), so it
stays a human prerequisite. Phase 0 below verifies it before any other work.

---

## Prompt

You are codifying our existing **self-managed GitLab Ultimate** instance — currently a
**Helm chart deployment** — into Terraform. This is a **brownfield import**, not a
greenfield build: the instance is in production, holds real repositories, and must not be
disturbed.

**Deliverables** (write all of these; do not summarise only in chat):

1. `docs/glu/gitlab-terraform-migration-plan.md` — the discovery findings and the staged
   migration runbook.
2. `terraform/gitlab-config/` — the Layer 2 root module (GitLab provider), with `import`
   blocks and generated-then-curated resource configuration.
3. `terraform/gitlab-deploy/` — the Layer 1 root module skeleton (`helm_release` + data
   sources for the external services), with a **documented list of what would need
   importing** and an explicit recommendation on whether to import or leave it alone.
4. `docs/glu/application-settings-snapshot.json` — the raw pre-Terraform settings
   snapshot (Phase 0).

### Ground rules

- **Discovery is read-only. Never apply.** You may run `terraform init`, `validate`,
  `plan`, and `plan -generate-config-out`. You may **not** run apply, or any
  state-mutating command other than the imports described in Phase 4 — and those only
  after I have reviewed the import blocks. No `helm upgrade`, no `helm uninstall`, no
  `kubectl apply/delete/patch`, no AWS mutations, no `POST`/`PUT`/`DELETE` against the
  GitLab API.
- **Import, never recreate.** A plan that would create a `gitlab_project` that already
  exists, or that shows `# forces replacement` on one, would **destroy a repository**.
  If any plan output contains `forces replacement` or a destroy of a project, group,
  or user: **stop, report it, and do not proceed**.
- **Never print a secret.** GitLab tokens, chart secrets, DB passwords, the Rails secret:
  record only the secret's name, namespace, keys present, and last 4 characters of any
  value you must identify. Do not write secret values into Terraform files, the plan doc,
  or a `.tfvars`. Flag anything you find already committed in git as CRITICAL with a file
  path and line number, without reproducing it.
- **Cite every fact** with the command that produced it. If two sources disagree, record
  both and flag the conflict.
- **Say UNKNOWN.** Missing access is a finding, not something to work around. Do not
  attempt to escalate your own permissions.
- Work the phases in order. Phase 0 is a hard gate.

### Phase 0 — Gate: licence, version, and the settings snapshot

```bash
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/version" | jq .
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/license"  | jq \
  '{plan, starts_at, expires_at, user_limit, active_users, licensee: (.licensee|keys)}'
```

Report: the GitLab **version**, and whether the active plan is **ultimate**. Then:

- If the plan is **not** ultimate — or `/license` returns nothing — **stop and report
  it**. Codifying against an unlicensed instance makes Ultimate-gated resources fail or
  silently no-op; the licence has to be activated at **Admin → Subscription** first, and
  it cannot be Terraformed. Do not continue to Phase 2.
- Record the licence **expiry** and seat numbers; they belong in the plan doc as a
  prerequisite with a named owner.

Then take the snapshot that must exist before Terraform ever touches instance settings:

```bash
curl -sS --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/application/settings" | jq -S . \
  > docs/glu/application-settings-snapshot.json
```

`gitlab_application_settings` is **experimental**, is a singleton with ID `gitlab`, and
its destroy is a **no-op that cannot be reverted** — this file is the only rollback that
will exist. Confirm it is written and non-empty before continuing.

### Phase 1 — Layer 1 discovery: how is GitLab actually deployed?

```bash
helm list --all-namespaces
helm get metadata <release> -n <ns>          # chart name + version + app version
helm get values  <release> -n <ns>           # USER-SUPPLIED values (the important ones)
helm get values  <release> -n <ns> --all     # full computed values, for reference
kubectl -n <ns> get deploy,sts,cronjob -o wide
kubectl -n <ns> get pvc
kubectl -n <ns> get ingress,gateway,httproute -o wide 2>/dev/null
kubectl -n <ns> get secrets      # NAMES AND KEYS ONLY — never values
kubectl -n <ns> get cm
```

Determine and record:

- Chart name and **chart version**, and the **GitLab appVersion** it maps to (these are
  different numbering schemes).
- Which shape this is: **Cloud Native Hybrid** (stateless in-cluster, managed services
  outside) or everything in-cluster.
- **Is PostgreSQL external?** Is Redis? Is object storage in use, for which of
  artifacts / uploads / packages / registry / LFS? Where is Gitaly, and is it HA?
  In-cluster PostgreSQL or Redis is an unsupported configuration and must be called out
  as a finding, not just recorded.

```bash
aws rds describe-db-instances --query 'DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Ver:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Storage:AllocatedStorage,Endpoint:Endpoint.Address,Backup:BackupRetentionPeriod,DelProt:DeletionProtection}'
aws elasticache describe-replication-groups 2>/dev/null
aws elasticache describe-cache-clusters 2>/dev/null
aws s3api list-buckets --query 'Buckets[].Name'
# for each GitLab bucket:
aws s3api get-bucket-versioning --bucket <b>
aws s3api get-bucket-lifecycle-configuration --bucket <b> 2>/dev/null
aws eks describe-cluster --name <cluster> --query 'cluster.{Ver:version,Endpoint:endpoint,Vpc:resourcesVpcConfig}'
```

**Backup and DR posture** — this determines whether the migration is safe to start at all:

```bash
kubectl -n <ns> get cronjob | grep -i backup
kubectl -n <ns> logs job/<most-recent-backup-job> --tail=50 2>/dev/null
```

Record explicitly: when the last successful backup ran; whether the chart's backup covers
the databases only (it does not cover artifacts, uploads, packages, registry or LFS —
those rely on object storage and are **not** migrated on restore); whether the **chart
secrets, especially `gitlab-rails-secret`, are backed up outside the cluster**; and
whether a restore has ever been tested. Losing the Rails secret makes every encrypted
column permanently unreadable even with a perfect database backup — if it is not backed up
externally, that is the **highest-severity finding in the whole audit** and belongs at the
top of the plan doc.

### Phase 2 — Layer 2 inventory: what configuration exists in GitLab?

Enumerate the live configuration. Paginate properly (`per_page=100` and follow
`x-next-page`), and write the raw JSON to a scratch directory so the inventory is
reproducible.

```bash
G="--header PRIVATE-TOKEN:$GITLAB_TOKEN"
curl -sS $G "$GITLAB_URL/api/v4/groups?all_available=true&per_page=100&top_level_only=true"
curl -sS $G "$GITLAB_URL/api/v4/groups?all_available=true&per_page=100"          # incl. subgroups
curl -sS $G "$GITLAB_URL/api/v4/projects?per_page=100&simple=false&archived=false"
curl -sS $G "$GITLAB_URL/api/v4/users?per_page=100&without_project_bots=true"
curl -sS $G "$GITLAB_URL/api/v4/runners/all?per_page=100"
curl -sS $G "$GITLAB_URL/api/v4/hooks"                                            # system hooks
curl -sS $G "$GITLAB_URL/api/v4/admin/ci/variables"                               # instance variables
```

Per group: `members/all`, `variables`, `hooks`, `labels`, `badges`, `ldap_group_links`,
`saml_group_links`, `protected_environments`, `share` relationships, `access_tokens`
(names/scopes only), and service accounts.

Per project: `members/all`, `variables`, `protected_branches`, `protected_tags`,
`protected_environments`, `push_rule`, `approval_rules`, `approvals`, `hooks`,
`environments`, `deploy_keys`, `job_token_scope`, `integrations`, and the
`shared_with_groups` list.

Ultimate-specific (check whether these are REST or GraphQL-only on this version, and say
which you used): **custom roles** (`member_roles`, admin roles), **compliance frameworks**
and their requirements plus project attachments, **security policy attachments** and the
security-policy project each group/project points at, and **external status checks**.

Then produce an **inventory table**: object type, count, and a "codify / leave manual /
out of scope" call for each, with a one-line reason. Be honest about volume — if there are
300 projects, say so, because it changes the strategy from hand-written HCL to
`for_each` over a data file.

### Phase 3 — Layer split and module design

Design **two separate root modules with separate state**, per the best-practices doc §3:

- `terraform/gitlab-deploy/` (Layer 1) — `aws` + `helm` + `kubernetes` providers.
- `terraform/gitlab-config/` (Layer 2) — the `gitlab` provider only.

For Layer 1, make an explicit **recommendation rather than an assumption**: importing a
running `helm_release` and live RDS into Terraform is materially riskier than importing
GitLab configuration, because a bad plan there is an outage. State clearly whether you
recommend (a) importing the existing release, (b) adopting only the surrounding AWS
resources and leaving the Helm release managed by hand for now, or (c) a rebuild-in-place
later. Justify it from what you found in Phase 1 — particularly the backup posture.

For Layer 2, propose the file layout and the **data-driven** shape: groups and projects
driven by `for_each` over a checked-in data structure (YAML/JSON), not hand-copied
blocks. Note which resources are Ultimate-gated so a future non-Ultimate environment
fails loudly rather than silently.

Pin both the `gitlab` provider and the chart version explicitly, and state the pinned
values. The provider supports the latest 3 patch releases within a major and **its
compatibility with a given GitLab version cannot be inferred from the version numbers** —
record the pairing you validated against.

### Phase 4 — Import blocks and generated configuration

Use Terraform 1.5+ `import` blocks with config generation, in **dependency order and small
batches**: top-level groups → subgroups → projects → memberships → variables → protections
→ integrations → instance-level.

```hcl
import {
  to = gitlab_group.acme
  id = "acme"          # group full path or numeric ID, per the resource's import docs
}
```

```bash
terraform init
terraform plan -generate-config-out=generated-batch1.tf
```

Rules for this phase:

- **Check each resource's own import documentation for the ID format** — it varies
  (numeric ID, full path, or a composite like `project_id:variable_key:environment`).
  Do not guess; if the format is unclear, record it as UNKNOWN and move on.
- `-generate-config-out` emits **every** attribute, including computed and read-only ones,
  and will not validate cleanly as-is. Treat the generated file as a **draft to curate**:
  strip read-only attributes, replace hardcoded values with variables/locals where they
  belong, and never leave a secret value in it.
- **One batch at a time.** Get a clean plan for batch *n* before generating batch *n+1*.
- Add `lifecycle { prevent_destroy = true }` to every `gitlab_project` and
  `gitlab_group` you import.
- Do **not** import `gitlab_application_settings` in this pass. Propose it as a separate,
  later, deliberately small change — the snapshot from Phase 0 is its only rollback.

### Phase 5 — Prove it

The acceptance criterion for codification is a **clean plan**, not "the code exists".

```bash
terraform validate
terraform plan -detailed-exitcode
```

For each batch, record whether `plan` reports **no changes**. Where it does not:

- Record the exact diff and the reason (provider default differing from the live value, a
  read-only attribute, a genuinely undocumented field).
- **Do not "fix" a diff by changing the live instance to match the code.** Change the code
  to match reality, or record the resource as *not cleanly importable* and leave it out.
- Any `forces replacement` on a group, project, or user: stop, report, do not proceed.

### Phase 6 — Write the plan doc

`docs/glu/gitlab-terraform-migration-plan.md`, structured as:

1. **Blockers and highest-severity findings first** — licence state, backup posture,
   Rails-secret exposure, any unsupported topology (in-cluster PostgreSQL/Redis).
2. **Deployment facts** — chart/app versions, topology, which services are external,
   object-storage coverage, backup schedule and last success.
3. **Configuration inventory** — the counts table with codify / manual / out-of-scope
   calls.
4. **Recommended layer split** and the Layer 1 import-or-not recommendation, justified.
5. **Staged migration plan** — batches in dependency order, with the clean-plan gate
   between each, and an estimate of how many resources per batch.
6. **Risk register** — `ID | risk | severity | evidence | mitigation`, including at minimum:
   project replacement risk, application-settings irreversibility, provider/GitLab version
   coupling, state-file sensitivity (`gitlab_user_runner` and access-token resources put
   real tokens in state), and drift from UI changes.
7. **Prerequisites checklist** — reconciled against §12 of the best-practices doc, with
   PASS / FAIL / UNKNOWN.
8. **UNKNOWNs and the access needed to close them.**

### Explicitly do not

- Do not apply, or import anything, until I have reviewed the import blocks.
- Do not create, modify, or delete any GitLab object, Kubernetes object, Helm release, or
  AWS resource.
- Do not put secret values in Terraform files, `.tfvars`, the plan doc, or state you
  create — and note in the risk register that the Layer 2 state file is sensitive by
  nature.
- Do not codify the licence, security-policy **content** (only the attachment is a
  resource — the policy YAML lives in a security-policy project's repository), or anything
  behind a GitLab feature flag.
- Do not recommend anything that needs access you did not have. Where you could not
  verify something, the finding is "unverified", not "fine".
