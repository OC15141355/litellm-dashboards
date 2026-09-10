# GitLab / GitLab Ultimate — Best Practices (Self-Managed)

> Scope: operating practice for our **self-managed GitLab Ultimate** instance, currently a
> **Helm chart deployment**. Written primarily as **context for codifying GitLab into
> Terraform** (the codification ticket), and secondarily as a standing reference.
> Verified against **GitLab 19.3**. Last updated: 2026-09-11.
>
> Companion docs in this directory:
> `gitlab-ultimate-what-we-get.md` (licence entitlements) ·
> `gitlab-byo-runners.md` (tenant-funded runners) ·
> `gitlab-shared-runner-eval.md` (platform shared fleet) ·
> `claude-prompt-gitlab-to-terraform.md` (the migration prompt this doc feeds).

---

## TL;DR — the seven things that matter most

1. **Activate the licence before codifying, and never put it in Terraform.** An
   unlicensed instance runs **Free features only**, and roughly a dozen provider resources
   you'll want are Ultimate-gated. There is **no licence resource** in the provider. §1.
2. **There are two Terraform layers, not one** — the *deployment* (EKS, RDS, object
   storage, `helm_release`) and the *GitLab configuration* (groups, projects, settings, via
   the `gitlab` provider). Separate modules, separate state, separate credentials,
   separate cadence. Merging them is the single most expensive mistake available. §3.
3. **`gitlab_application_settings` is experimental, is a singleton with ID `gitlab`, and
   its destroy is a no-op you cannot revert.** Snapshot `GET /api/v4/application/settings`
   to a file before Terraform ever touches it. §4.
4. **Stateful components must not run in Kubernetes.** PostgreSQL and Redis in-cluster is
   *unsupported*; Gitaly in Kubernetes is non-HA only. External RDS/ElastiCache/S3. §2.
5. **The Helm chart's backup does not back up your data.** Artifacts, uploads, packages,
   registry and LFS live in object storage and are **not** migrated by the chart's
   backup/restore. Nor are the chart's secrets. §8.
6. **Losing `gitlab-rails-secret` is unrecoverable.** It holds `db_key_base` and the
   ActiveRecord encryption keys; without it every encrypted column — tokens, integrations,
   CI variables, 2FA — is permanently unreadable. Manage it yourself, back it up outside
   the cluster, and never rotate it casually. §8.
7. **Upgrades have required stops** at `x.2`, `x.5`, `x.8`, `x.11` (the pattern since
   17.5). You cannot jump. Plan the path, always take the latest patch of each stop, and
   let background migrations drain. §9.

---

## 1. Licence and activation — and the answer to "does it need activating first?"

**Yes. Activate before codifying.** Not because Terraform touches the licence, but because
the licence determines which resources exist.

### How activation works

| | |
|---|---|
| **Primary method** | **Cloud licensing**: a 24-character alphanumeric **activation code** from the subscription email / Customers Portal, entered at **Admin → Subscription** |
| **Network requirement** | Outbound **HTTPS 443 to `customers.gitlab.com`**. Verify with `curl --verbose "https://customers.gitlab.com/"` from inside the instance. If an SSL-inspection appliance sits in the path its CA must be trusted |
| **Offline / air-gapped** | A **licence file** (base64 ASCII, `.gitlab-license`) uploaded instead |
| **Before activation** | **Only Free features are enabled** |
| **Restart needed?** | No reconfigure/restart for standard activation |
| **Verify the active tier** | **Help → Help** shows edition and version; **Admin → Subscription** shows the plan |

### Helm-specific

- The chart accepts a licence via the **`global.gitlab.license`** keys, pointing at a
  Kubernetes secret holding the `.gitlab-license` file, and supports a
  **`GITLAB_ACTIVATION_CODE`** environment variable to activate during installation.
- **Both are install-time only.** Renewals and tier changes go through the Admin UI, not
  the chart. Do not model licence renewal as a `helm upgrade`.

### Why this blocks the codification ticket

The provider has **no `gitlab_license` / `gitlab_subscription` resource** (138 resources;
none of them is the licence). The **License API** (`POST /license`) accepts a legacy
licence *string*, not a cloud activation code, so even scripting it doesn't cover the
normal path. Meanwhile these provider resources are **Ultimate-gated** and will fail or
misbehave against a Free-tier instance:

`gitlab_admin_role` · `gitlab_member_role` (custom roles) · `gitlab_compliance_framework` ·
`gitlab_compliance_requirement` · `gitlab_project_compliance_frameworks` ·
`gitlab_group_security_policy_attachment` · `gitlab_project_security_policy_attachment` ·
`gitlab_project_external_status_check` · `gitlab_group_protected_environment` ·
`gitlab_project_approval_rule` (advanced rules) · plus tier-gated *fields* inside
`gitlab_application_settings`, `gitlab_project` and `gitlab_group`.

**Practice:** treat the licence as a **documented prerequisite with a human owner and a
renewal calendar reminder** — never a Terraform resource. Record the activation date,
expiry, and seat count in the repo README; assert the tier in a pre-flight check before
any apply.

---

## 2. Deployment topology

GitLab publishes **reference architectures** from 1k to 50k users, sized primarily by
**peak RPS (20–1000)** rather than headcount. Three shapes:

| Shape | What it is | Sizes |
|---|---|---|
| **Linux package (Omnibus)** | Everything on VMs | 1k–50k |
| **Cloud Native Hybrid** | Stateless components (Webservice, Sidekiq) on Kubernetes via Helm + external managed services | 2k–50k |
| **Cloud Native** | Fully Kubernetes with external managed services; **recommended for new deployments**, in four sizes (S/M/L/XL) | — |

Rules that are not negotiable:

- **Do not run PostgreSQL or Redis in Kubernetes** — explicitly unsupported. Use RDS /
  Cloud SQL / Azure Database, and Redis (or Valkey) in **standalone mode, not cluster
  mode**, HA via replication, with a deliberate eviction policy.
- **Gitaly in Kubernetes is non-HA only.** HA repository storage means an external Gitaly
  Cluster.
- **Object storage for everything that can use it** — artifacts, uploads, packages,
  registry, LFS. This is also a hard prerequisite for the chart's backups to be meaningful
  (§8).
- **HA from ~3,000 users.** Enable PostgreSQL load balancing with read replicas.
- **Avoid single-region**; GitLab **Geo** is the DR answer, not a second Helm release.
- Size **up** when unsure, then measure and come down.

Practical consequence for the codification ticket: identify which of these are already
external (RDS? ElastiCache? S3?) before writing any Terraform, because the answer
determines whether the deployment module is "a `helm_release` plus data sources" or "a
full platform build".

---

## 3. The two Terraform layers

This is the same category error as the runner evaluation: two different things get
compared, or worse, merged.

| | **Layer 1 — Deployment** | **Layer 2 — GitLab configuration** |
|---|---|---|
| Manages | EKS/nodes, RDS, ElastiCache, S3 buckets, IAM/IRSA, DNS/certs, `helm_release`, chart values, Kubernetes secrets | Groups, projects, members, protected branches/environments, CI/CD variables, integrations, hooks, custom roles, compliance frameworks, security-policy attachments |
| Provider | `aws`, `helm`, `kubernetes` | `gitlab` |
| Credential | AWS role | GitLab **service-account PAT** |
| Blast radius of a bad apply | **Instance outage / data loss** | Wrong permissions, deleted project (**also data loss** — see §4) |
| Change cadence | Rare, change-managed | Frequent, self-service via MR |
| Depends on | Nothing GitLab-side | Layer 1 being up **and licensed** |

**Practice:**

- Separate **root modules and state files**. Layer 2 cannot plan if Layer 1's endpoint is
  down, and you do not want a project-membership change queued behind an RDS diff.
- Layer 2 reads Layer 1's outputs (the URL) via a remote state data source or a variable —
  not by co-locating.
- Layer 1 is where you enforce `prevent_destroy` lifecycle blocks (RDS, S3, the
  `gitlab-rails-secret`).
- Chart values belong in version-controlled YAML consumed by `helm_release`, not inlined
  as a giant `set {}` soup — you want the values diffable on their own.

---

## 4. What the GitLab Terraform provider can and cannot manage

Provider: **`gitlabhq/gitlab`** (138 resource types). Requires Terraform ≥ 1.0 (**1.4+
recommended**; 1.5+ if you want `import` blocks, which you do — see the migration prompt).

### Coverage by area

| Area | Representative resources |
|---|---|
| **Groups** | `group`, `group_membership`, `group_variable`, `group_hook`, `group_label`, `group_badge`, `group_share_group`, `group_ldap_link`, `group_saml_link`, `group_branch_protection`, `group_protected_environment`, `group_level_mr_approvals`, `group_service_account`(+`_access_token`), `group_access_token`, `group_deploy_token`, `group_dependency_proxy` |
| **Projects** | `project`, `project_membership`, `project_variable`, `project_hook`, `project_protected_environment`, `project_push_rules`, `project_approval_rule`, `project_level_mr_approvals`, `project_environment`, `project_badge`, `project_label`, `project_milestone`, `project_freeze_period`, `project_share_group`, `project_target_branch_rule`, `project_pull_mirror`, `project_push_mirror`, `project_cicd_catalog`, `project_job_token_scope(s)` |
| **Branch/tag protection** | `branch`, `branch_protection`, `project_protected_environment`, `tag_protection`, `project_tag` |
| **Users & identity** | `user`, `user_identity`, `user_sshkey`, `user_gpgkey`, `user_custom_attribute`, `user_impersonation_token`, `personal_access_token`, `instance_service_account`, `project_service_account` |
| **Custom roles (Ultimate)** | **`member_role`**, **`admin_role`** |
| **Compliance (Ultimate)** | **`compliance_framework`**, **`compliance_requirement`**, **`project_compliance_frameworks`** |
| **Security (Ultimate)** | **`group_security_policy_attachment`**, **`project_security_policy_attachment`**, `project_security_settings`, `project_secret_detection_validity_checks`, `project_external_status_check` |
| **Runners** | **`user_runner`** (creates a runner, returns the `glrt-` authentication token), `project_runner_enablement`, `runner_controller`(+`_instance_scope`, `_runner_scope`, `_token`) |
| **Instance-level** | **`application_settings`** *(experimental)*, `application`, `application_appearance`, `instance_variable`, `system_hook`, `topic`, `pages_domain`, `instance_cluster` |
| **Integrations** | `integration_slack`, plus `project_integration_*` / `group_integration_*` for Jira, Jenkins, GitHub, Datadog, Harbor, Teams, Mattermost, Matrix, Telegram, etc. |
| **Content & CI plumbing** | `repository_file`, `release`, `release_link`, `pipeline_schedule`(+`_variable`), `pipeline_trigger`, `project_secure_file`, `project_feature_flag`(+`_user_list`), `deploy_key`(+`_enable`), `cluster_agent`(+`_token`), `value_stream_analytics` |

### The traps — read these before writing any HCL

1. **`gitlab_application_settings` is experimental.** All instances share the **ID
   `gitlab`**; it **implements no destroy logic (a no-op)** and it is **not possible to
   revert to previous settings**. So: `GET /api/v4/application/settings` into a
   version-controlled JSON snapshot *before* first use, adopt settings in small reviewed
   batches, and never tear this module down expecting a rollback.
2. **Token type matters.** Group and project access tokens — and `CI_JOB_TOKEN` — lack full
   API access and produce confusing permission errors. Use a **dedicated PAT or a service
   account**. Practice: an `instance_service_account` with Admin, its token in Secrets
   Manager, rotated on a schedule, used only by CI.
3. **Provider ↔ GitLab version compatibility cannot be inferred from version numbers.**
   Upstream supports the latest 3 patch releases within a major and only introduces
   breaking changes on majors; new GitLab features may not appear in the provider for
   several releases, and removed ones may linger. **Pin the provider**, bump it as its own
   MR, and re-plan after every GitLab upgrade.
4. **Experimental GitLab features are unsupported by the provider** until they're GA.
   Don't codify a feature-flagged feature.
5. **A `gitlab_project` replacement destroys the repository.** Any plan showing
   `# forces replacement` on a project is a stop-the-line event, not a diff to approve.
   Guard real projects with `lifecycle { prevent_destroy = true }`.

### Genuine gaps — do not plan to codify these

| Not manageable | Do this instead |
|---|---|
| Licence / subscription activation | Human prerequisite (§1) |
| **Security policy *content*** — only the *attachment* is a resource | The policy YAML lives in a security-policy project's repository; manage it as a file in git (optionally via `repository_file`) and attach with `*_security_policy_attachment` |
| Instance licence-tier assertions | Pre-flight API check in CI |
| Anything behind a GitLab feature flag | Wait for GA |

---

## 5. Group and project structure

Structure is not cosmetic — **runners, CI/CD variables, compliance frameworks, security
policies, protected environments and custom roles all inherit down the hierarchy.** The
tree *is* the policy boundary.

- **One top-level group per business unit / tenant.** Top-level is also the boundary for
  compute-minute quotas and for group runners, so it should match how you fund and govern.
- **Subgroups mirror ownership, not technology.** `acme/platform`, not `acme/terraform`.
- **Keep it shallow** (2–3 levels). Deep nesting makes inherited-permission debugging
  miserable and the provider's `group` graph noisy.
- **Nothing real in personal namespaces** — no group inheritance, no compliance framework,
  no succession when the person leaves.
- **Set the default branch and squash/merge-method policy at group level**, so new projects
  inherit rather than needing per-project Terraform.
- In Terraform, drive projects from a **map/`for_each` over a data structure**, not 200
  copy-pasted blocks. The data file becomes the reviewable artefact.

---

## 6. Access control and authentication

- **SSO is the source of truth.** SAML or LDAP; `gitlab_group_saml_link` /
  `gitlab_group_ldap_link` map IdP groups to GitLab groups so membership is not
  hand-maintained. Codify the *links*, not the *people*.
- **Custom roles instead of Owner sprawl** (Ultimate). `gitlab_member_role` and
  `gitlab_admin_role`. The concrete win from the runner work: a runner-operator role that
  can manage group runners without being group Owner.
- **Service accounts for all automation.** `instance_service_account` /
  `group_service_account` / `project_service_account` with scoped tokens, not a human's
  PAT. When that human leaves, nothing breaks.
- **Enforce token expiry** — require all new access tokens to have an expiration date.
- **2FA for all users**, and enable **Admin Mode** so administrative actions require
  re-authentication.
- **Close the door on sign-ups:** clear *Allow new user accounts*; if everyone shares an
  email domain, list it under *Domains allowed for new users*; set email confirmation to
  **Hard**.
- **Rate limits:** configure user and IP rate limits and the protected-paths limits.
- These are mostly `gitlab_application_settings` fields — which is exactly why §4's
  snapshot-first rule matters.

---

## 7. CI/CD practice

- **Variables:** *masked* + *protected* for anything secret; protected variables are only
  exposed on protected refs, which is the mechanism that enforces "only the maintainer can
  publish to prod" (the pattern already documented in
  `../omni-bitbucket-to-gitlab-migration.md`). Prefer external secret management over
  long-lived CI variables where possible.
- **Protected branches + protected environments** with required approvals; pair with
  `access_level = ref_protected` runners.
- **Limit the CI job token's reach** with `gitlab_project_job_token_scope(s)` — an
  unscoped job token is a lateral-movement path between projects.
- **Never `privileged = true`, never mount the Docker socket** on shared runners. Rootless
  builders (Kaniko/Buildkit) instead.
- **Centralise pipeline definitions** in a CI/CD catalog / components project
  (`gitlab_project_cicd_catalog`) and have projects `include:` them, rather than 40 copies
  of the same YAML.
- **Enforce, don't request:** Ultimate **pipeline execution policies** and **scan execution
  policies** inject required jobs centrally. They carry their own `tags:`, which is how you
  keep compliance scanning on platform-funded compute (see `gitlab-shared-runner-eval.md`).
- **Runners:** see `gitlab-byo-runners.md` and `gitlab-shared-runner-eval.md`. Note the
  provider can create runners and hand back the `glrt-` token
  (`gitlab_user_runner`) — useful, and also a reason that state file is sensitive.

---

## 8. Backup, DR, and the one unrecoverable failure

### What the chart's backup actually covers

The Toolbox sub-chart ships `backup-utility`, which coordinates a backup across pods and
**includes the PostgreSQL databases**. It **does not include** artifacts, uploads,
packages, registry data, or LFS objects: the chart *relies* on those being in object
storage and **does not migrate them during restore**. **Secrets are not addressed by the
documented backup process at all.**

So a "GitLab backup" is really three jobs:

| Job | Mechanism | If you skip it |
|---|---|---|
| Database + repositories | Toolbox `backup-utility` → S3 / GCS / Azure | No restore at all |
| Object-storage data | **Bucket-level** protection: versioning, replication, lifecycle, deletion protection | Restore succeeds and every artifact, package and image is gone |
| **Chart secrets** | Your own export of the Kubernetes secrets, stored **outside the cluster** | See below — permanent data loss |

### The unrecoverable one

`gitlab-rails-secret` contains `secret_key_base`, `otp_key_base`, **`db_key_base`**,
`encrypted_settings_key_base`, RSA signing keys and the ActiveRecord encryption keys.
GitLab's docs advise **against rotating it** precisely because it holds the database
encryption keys; losing it is equivalent to losing the secrets file — the encrypted columns
(tokens, integration credentials, CI variables, 2FA secrets) become permanently
unreadable **even with a perfect database backup**.

**Practice:**

- **Create the secrets you care about yourself** rather than letting the chart
  auto-generate them (the chart generates anything you don't supply). At minimum own the
  Rails secret and the GitLab Shell host keys — auto-generated host keys mean every
  developer gets a host-key warning after a rebuild.
- Store them in **AWS Secrets Manager** (outside the cluster, outside the same failure
  domain), and reference them from `helm_release`. `prevent_destroy` on the Terraform
  resource.
- If you must rotate: back up current secrets, create the new ones with a **`-v2`
  suffix**, repoint config, `helm upgrade`, **verify GitLab works**, only then delete the
  old.
- **Test restores.** An untested restore is a hypothesis.

### Backup operational gotchas

Size temp disk for the *extracted* tarball (can exceed the final archive); use persistent
volumes for large backups or the pod gets evicted mid-run; **never rename a backup
archive** (repositories get silently skipped on restore); watch for PostgreSQL client
library version mismatches. Schedule via the chart's backup cron job.

---

## 9. Upgrades and version policy

- **Required stops.** Since 17.5 the pattern is `x.2.z`, `x.5.z`, `x.8.z`, `x.11.z` — e.g.
  for 18: 18.2, 18.5, 18.8, 18.11; for 19: 19.2, 19.5, 19.8, 19.11. You **must** land on
  those versions on the way through. Use GitLab's Upgrade Path tool to compute the path.
- **Always the latest patch** of each stop (e.g. `.7`, not `.0`).
- **Let background migrations finish** between stops — check before proceeding, or the
  next upgrade compounds the problem.
- **Helm deployments** follow the chart↔GitLab version mapping; the chart version is not
  the GitLab version. Pin the chart version in Terraform and treat a bump as its own
  change.
- Some stops are **conditional** on instance characteristics (large user counts, big
  pipeline history), so read the notes rather than pattern-matching.
- **Re-plan the GitLab Terraform layer after every upgrade.** New defaults and new fields
  appear; the provider may lag. Expect drift, and diff it deliberately rather than
  auto-applying.

---

## 10. Observability

- **Runner fleet dashboard** (Ultimate): runner-infrastructure CI errors, concurrent jobs
  on the busiest runners, compute minutes used by instance runners, job queue time. The
  *runner usage* and *wait time to pick up job* panels need the **ClickHouse** integration.
- **Compute minutes** give per-namespace CI consumption for instance runners (and an
  optional hard quota per top-level group) — the only built-in CI cost signal, and it does
  not cover group/project runners.
- **Audit events** (Ultimate) for who changed what, including runner and token operations.
- Prometheus metrics from the chart's exporters; Sidekiq queue depth and Gitaly latency are
  the two that predict user-visible pain.
- **Watch for Terraform drift** as a first-class signal: someone changing settings in the
  UI is both an operational fact and a governance finding.

---

## 11. Anti-patterns, ranked

1. **Codifying against an unlicensed instance** → Ultimate resources fail or silently
   no-op; you conclude the provider is broken. §1.
2. **One Terraform state for deployment + configuration** → a membership change blocked
   behind an RDS diff, and one bad apply that can take the instance down. §3.
3. **Letting the chart auto-generate the Rails secret with no external backup** →
   one cluster rebuild from permanent, unrecoverable data loss. §8.
4. **Assuming the chart's backup is a backup** → artifacts, packages, registry and LFS are
   not in it. §8.
5. **Approving a plan that replaces a `gitlab_project`** → repository deleted. §4.
6. **Tearing down the application-settings module expecting a revert** → destroy is a
   no-op, so you'll think it worked; the settings stay applied and cannot be reverted. §4.
7. **Running PostgreSQL or Redis in the cluster** → unsupported, and you find out during
   an incident. §2.
8. **A human's PAT as the automation credential** → breaks when they leave, and every
   audit event is attributed to them. §6.
9. **Skipping a required upgrade stop** → failed migrations mid-upgrade on a production
   instance. §9.
10. **Deep group nesting** → inherited-permission archaeology every time access is
    questioned. §5.
11. **Unscoped CI job tokens** → cross-project lateral movement. §7.
12. **Bumping the provider and GitLab in the same MR** → two variables, one failure, no
    signal. §4/§9.

---

## 12. Codification readiness checklist

Must be true before the Terraform migration ticket starts:

- [ ] **Ultimate licence activated and verified** in Admin → Subscription; expiry and seat
      count recorded, renewal owner named. §1
- [ ] Current **GitLab version and chart version** recorded, and the upgrade path to the
      intended target computed. §9
- [ ] Deployment inventory complete: is PostgreSQL external? Redis? Object storage? Gitaly
      topology? §2
- [ ] **Chart secrets exported and stored outside the cluster**, Rails secret confirmed
      recoverable. §8
- [ ] A **verified restore** has been performed at least once, or the risk is explicitly
      accepted in writing. §8
- [ ] **Dedicated service account + PAT** created for Terraform, in Secrets Manager, not a
      human's token. §4/§6
- [ ] `GET /api/v4/application/settings` **snapshotted to version control**. §4
- [ ] Provider and chart versions **pinned**; separate MR lanes for version bumps. §4/§9
- [ ] Remote state with locking, encrypted, and **two separate state files** for the two
      layers. §3
- [ ] Group/project structure documented as data (the thing `for_each` will consume). §5

---

## Sources

- [Activate GitLab EE / subscription activation](https://docs.gitlab.com/administration/license/)
- [Activate GitLab EE with a licence file or key](https://docs.gitlab.com/administration/license_file/)
- [License API](https://docs.gitlab.com/api/license/)
- [Reference architectures](https://docs.gitlab.com/administration/reference_architectures/)
- [GitLab Helm chart](https://docs.gitlab.com/charts/)
- [Configure secrets for the GitLab chart](https://docs.gitlab.com/charts/installation/secrets/)
- [Backup and restore for the GitLab Helm chart](https://docs.gitlab.com/charts/backup-restore/)
- [Upgrade paths and required stops](https://docs.gitlab.com/update/upgrade_paths/)
- [GitLab Terraform provider — index (versions, auth, token guidance)](https://registry.terraform.io/providers/gitlabhq/gitlab/latest/docs)
- [`gitlab_application_settings` (experimental, singleton, no-op destroy)](https://registry.terraform.io/providers/gitlabhq/gitlab/latest/docs/resources/application_settings)
- [terraform-provider-gitlab resource docs (authoritative resource inventory)](https://github.com/gitlabhq/terraform-provider-gitlab/tree/main/docs/resources)
- [Application settings API](https://docs.gitlab.com/api/settings/)
- [GitLab hardening recommendations](https://docs.gitlab.com/security/hardening/)
- [Hardening — application recommendations](https://docs.gitlab.com/security/hardening_application_recommendations/)
- [Account and limit settings](https://docs.gitlab.com/administration/settings/account_and_limit_settings/)
- [Rate limits](https://docs.gitlab.com/rate_limits/)
- [Enforce two-factor authentication](https://docs.gitlab.com/security/two_factor_authentication/)
- [Compute minutes](https://docs.gitlab.com/ci/pipelines/compute_minutes/)
- [Runner fleet dashboard (Ultimate)](https://docs.gitlab.com/ci/runners/runner_fleet_dashboard/)
