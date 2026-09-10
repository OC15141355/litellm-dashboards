# Shared Instance Runner — Options Evaluation & Recommendation

> Scope: a **platform-owned, instance-scoped shared runner fleet** on our self-managed
> GitLab Ultimate — the compute every project gets by default, funded by us. This is the
> counterpart to `gitlab-byo-runners.md` (tenant-funded, group-scoped runners); read that
> one for the connection model, IAM policy, and autoscaling mechanics, which are not
> repeated here.
> Evaluates: official GitLab Runner (self-provisioned), **cattle-ops
> `terraform-aws-gitlab-runner`**, Kubernetes executor on EKS, **AWS CodeBuild managed
> runners**, the AWS Fargate driver, and `docker+machine`.
> Status: research/planning — recommendation + PoC gates at §10.
> Verified against **GitLab / GitLab Runner 19.3**. Last updated: 2026-09-10.

---

## TL;DR

- **The category error to avoid:** `cattle-ops` is **not** an alternative to GitLab
  Runner — it is Terraform that *provisions* GitLab Runner. There are two independent
  decisions here: **who provisions the fleet** (us / cattle-ops / AWS CodeBuild) and
  **what executes the job** (autoscaled EC2 / Kubernetes pod / CodeBuild ephemeral host).
  Evaluating them as one list produces a nonsense comparison. §2 splits them.
- **Recommendation: cattle-ops `terraform-aws-gitlab-runner` driving the
  `docker-autoscaler` executor with Spot job instances** — the officially supported
  runtime path, without hand-rolling the ~1,500 lines of Terraform that the module has
  already debugged (ASG scale-in protection, cache bucket, CloudWatch, Spot fallback).
  **If we already run EKS with spare capacity, the `kubernetes` executor via the official
  Helm chart wins instead** on marginal cost and on having no AMI to maintain.
- **CodeBuild managed runners are the most interesting option and the most likely to be
  blocked.** They delete the runner manager entirely and bill per-minute with no idle
  cost — but they **invert the network model**: instead of a runner polling outbound to
  GitLab, AWS must reach our GitLab instance (OAuth app / CodeConnections) *and* GitLab
  must deliver webhooks to AWS. On a private self-managed instance that's a networking
  project, not a config flag. Two further sharp edges: jobs run under the **shell
  executor**, and **secrets are not masked in logs by default**.
- **Out:** the **AWS Fargate driver** (community-supported, docs state it is *"not meant
  for production use"*, and it ignores `image:` in favour of ECS task definitions) and
  **`docker+machine`** (removed in **GitLab 20.0, May 2027**). GitLab-hosted runners
  don't exist for self-managed.
- **One thing that flips versus the BYO doc:** instance runners **do** consume compute
  minutes, where group and project runners do not. The shared fleet is therefore the one
  fleet GitLab will meter for us — usable for showback without touching the CUR.

---

## 1. What a shared fleet is for — and when to use BYO instead

| Situation | Fleet |
|---|---|
| General build/test for internal projects | **Shared** instance runners |
| Security scanning enforced by pipeline execution policy (Ultimate) | **Shared** — so compliance compute is platform-funded, not tenant-funded |
| A tenant needs their own data-residency, VPC access, or bespoke AMI | **BYO** (`gitlab-byo-runners.md`) |
| A tenant wants to fund their own capacity / has an SLA on queue time | **BYO** |
| Deploy jobs holding production credentials | **Neither by default** — a separate small `ref_protected` fleet (§7) |
| Jobs from forks / external contributors | **Shared, single-use instances only** (§7) |

The shared fleet is the default; BYO is the exception that needs a reason.

---

## 2. Two decisions, not one

| | **Provisioning layer** — who builds and owns the infra | **Execution layer** — what the job actually runs on |
|---|---|---|
| Options | Hand-written Terraform (ours) · **cattle-ops module** · official Helm chart · AWS CodeBuild project · GitLab Runner Operator | `docker-autoscaler` (EC2 per job) · `instance` (VM per job) · `kubernetes` (pod per job) · CodeBuild ephemeral host · ECS Fargate task |
| Who supports it | Us / community / AWS | **GitLab** (except CodeBuild + Fargate) |
| Cost of a wrong choice | Rework of Terraform | Rework of every pipeline |

Get the **execution layer** right first — it's the one pipeline authors feel and the one
GitLab supports. The provisioning layer is replaceable.

---

## 3. The options

### 3.1 Official GitLab Runner, self-provisioned (`docker-autoscaler` + `fleeting-plugin-aws`)

The baseline. Runner manager EC2 → taskscaler → fleeting → ASG (`SetDesiredCapacity`),
one ephemeral instance per job. Mechanics, IAM policy and `config.toml` are in
`gitlab-byo-runners.md` §5–6.

**For:** fully GitLab-supported; the exact architecture GitLab documents and tests; no
third-party dependency; we control every detail; ties into the Ultimate runner fleet
dashboard.
**Against:** we write and maintain the Terraform — ASG with scaling policy `none`, scale-in
protection, `AZRebalance` suspension, launch template, cache bucket, instance profile,
manager AMI patching, Spot fallback. All of that is undifferentiated work that the
cattle-ops module has already done and had beaten on in public.
**Verdict:** correct execution layer, wrong provisioning layer. Adopt the runtime, don't
hand-roll the infra.

### 3.2 cattle-ops `terraform-aws-gitlab-runner` **← recommended provisioning layer**

Community Terraform module (MIT, ~628 stars, ~357 forks, actively maintained; currently on
the **v8** line — check the Terraform Registry for the exact current release rather than
pinning from this doc). Requires **Terraform >= 1.3** and **AWS provider >= 6.0**.

Provisions the runner manager, ASG/launch template, IAM, security groups, **S3 build
cache**, CloudWatch logging, and Spot configuration — with **Spot as the default**, plus
mixed on-demand/Spot instance policies.

Supports three shapes: `docker+machine` (legacy), `docker` (no autoscaling), and
**`docker-autoscaler` with the AWS fleeting plugin** — the last is the one to use, and the
module exposes fleeting plugin version and instance/update-interval settings. It has also
moved runner token handling to **SSM Parameter Store** rather than Terraform-variable
registration tokens, which is the right direction given tokens die in 20.0.

**For:** removes the highest-effort, lowest-value part of the work; the fiddly AWS details
that cause the failure modes in `gitlab-byo-runners.md` §12 are already handled; public
issue tracker means we inherit other people's debugging; upgrade paths documented (v7, v8
migration notes).
**Against:** third-party module in the critical path — a supply-chain and maintenance
dependency. Pin a version and read the diff before bumping. Module upgrades have been
breaking enough to warrant their own migration guides. There is also an unpopular fork at
`TerraformFoundation/terraform-aws-gitlab-runner` (0 stars) — **`cattle-ops` is the
mainline**; don't accidentally depend on the fork.
**Verdict:** **recommended.** Use it to provision the officially-supported
`docker-autoscaler` runtime. Best effort-to-outcome ratio available.

### 3.3 Kubernetes executor on EKS (official Helm chart / GitLab Runner Operator)

One **pod per job** (build + helper + service containers), created and deleted by the
runner against the cluster API. Concurrency via `concurrent`; CPU/memory/ephemeral-storage
requests and limits per container class; jobs may override within
`*_overwrite_max_allowed` bounds. **`namespace_per_job`** gives per-job namespace
isolation (needs the RBAC to create/delete namespaces, and costs extra API calls).

**For:** **no AMI to maintain** — the biggest hidden cost of the EC2 options; marginal cost
is just node capacity if the cluster already exists (Karpenter/cluster-autoscaler handles
elasticity); matches what our Omni pipeline already assumes; fastest job start of the
autoscaled options when warm capacity exists.
**Against:** only cheap if the cluster genuinely already exists and is well-run — otherwise
you've adopted EKS to run CI; container-in-container builds need a rootless builder
(Kaniko/Buildkit) since `privileged` is off the table on a shared cluster; services sharing
a port conflict inside a pod; helper containers can't inherit per-job user config, which
limits some isolation patterns; node failures still kill jobs regardless of pod disruption
budgets.
**Verdict:** **the better answer if and only if EKS is already a first-class platform for
us.** Same GitLab-side runner contract either way, so this can be chosen per capability
class rather than instead of §3.2.

### 3.4 AWS CodeBuild managed runners for GitLab Self-Managed

GA since Feb 2025 for the `GITLAB_SELF_MANAGED` source type. A CodeBuild project with a
webhook filtered on **`WORKFLOW_JOB_QUEUED`** receives GitLab job events and runs each job
on a **CodeBuild ephemeral host**. Group webhooks are supported, so one project can serve a
whole GitLab group. Compute spans EC2 and **Lambda**, on Amazon Linux 2/2023, Ubuntu, and
Windows Server Core 2019, with ARM available. Image and instance type can be **overridden
per job via the job's label/tags**, so one project covers many environments. `buildspec`
can be layered in with a `buildspec-override:true` tag.

**For:** **no runner manager, no ASG, no AMI, no `config.toml`** — the entire operational
surface of §3.1–3.3 disappears; per-minute billing with **no idle cost**, which is the
single biggest structural cost advantage; native IAM / Secrets Manager / CloudTrail / VPC
integration, so job credentials are AWS-native rather than CI variables; **Lambda compute**
makes short jobs very cheap and fast to start; available in all CodeBuild regions;
CloudFormation-supportable.

**Against — and these are decisive, so test them first:**

1. **It inverts the network model.** Every other option here is a runner polling
   *outbound* to GitLab, requiring nothing inbound. CodeBuild instead needs an OAuth
   app / CodeConnections link where **AWS reaches our GitLab instance**, plus **GitLab
   delivering webhooks to AWS**. Integrations of this shape generally expect the GitLab
   URL to be reachable, which is a problem for a private instance or a strict DMZ.
   CodeConnections can create a PrivateLink VPC endpoint for webhooks, but this is a
   networking workstream — **prove it before designing around it**.
2. **Jobs run under the `shell` executor** — the build runs locally alongside the runner
   inside the CodeBuild container. Isolation comes from CodeBuild's ephemeral host, not
   from a per-job container, so `image:`-style per-job container semantics work
   differently (override the project image or the job label instead).
3. **Secrets are not masked in build logs by default** — masking has to be turned on per
   variable in GitLab CI/CD settings. On a shared fleet serving every project, that is a
   leak waiting to happen and must be a rollout gate.
4. AWS-side quotas and concurrency now govern CI capacity, and the fleet lives outside the
   GitLab runner-fleet dashboard's view of managers.

**Verdict:** **strongest long-term candidate, gated on the network question.** Run the
network reachability test (§10) before anything else; if it passes, take it seriously as
the primary — especially for short jobs on Lambda compute. If it fails, it's out and §3.2
stands.

### 3.5 AWS Fargate driver

Persistent runner manager EC2 + custom-executor driver → one **ECS Fargate task** per job.

**Against:** **community supported** — GitLab Support will attempt help but guarantees
nothing; the docs state plainly it is **"not meant for production use; additional security
is required in AWS"**; **`image:` in `.gitlab-ci.yml` is ignored** (the ECS task definition
decides the image), which breaks the normal GitLab CI contract for every pipeline author;
task images must bundle GitLab Runner *and an SSH server* accepting public-key auth; still
needs the persistent manager, so it doesn't even buy the operational saving CodeBuild does;
unsuitable for high disk or network IO.
**Verdict:** **out.** All of CodeBuild's serverless appeal with none of its support model.

### 3.6 `docker+machine` (legacy baseline)

**Deprecated in 17.5, removed in GitLab 20.0 (May 2027).** Docker Machine itself is
unmaintained upstream. Relevant only as the thing to migrate *off* — including inside the
cattle-ops module, which still offers it.
**Verdict:** **out as a target.** If the informal runners from the audit are on it, that's
a dated migration, not a config tweak.

### 3.7 GitLab-hosted runners

SaaS-only. Not available to self-managed instances. Listed to close it off.

---

## 4. Evaluation criteria

Explicit, so the recommendation is auditable:

| # | Criterion | Weight | Why |
|---|---|---|---|
| C1 | GitLab-supported execution path | High | We don't want to be the only ones running it |
| C2 | Operational surface we own (AMI, manager, patching) | High | Dominates real cost over 3 years |
| C3 | Network model fits a private self-managed instance | **Gate** | Fails → option is out |
| C4 | Job isolation on a shared multi-tenant fleet | High | See §7 |
| C5 | Idle cost / cost elasticity | High | Shared fleet is 24/7 |
| C6 | Job start latency | Medium | Developer experience |
| C7 | Capability coverage (arm64, Windows, GPU, DinD) | Medium | Avoids a second fleet later |
| C8 | Observability + fits the Ultimate fleet dashboard | Medium | §8 |
| C9 | Supply-chain / maintenance dependency | Medium | Third-party modules and drivers |
| C10 | Migration cost off the current state | Low | One-off |

## 5. Comparison matrix

| | Self-provisioned Runner (3.1) | **cattle-ops (3.2)** | K8s on EKS (3.3) | CodeBuild (3.4) | Fargate (3.5) | docker+machine (3.6) |
|---|---|---|---|---|---|---|
| C1 GitLab-supported runtime | ✅ | ✅ (same runtime) | ✅ | ❌ AWS-side, `shell` | ⚠️ community | ⛔ removed 20.0 |
| C2 Ops surface we own | ❌ High | ⚠️ Medium | ⚠️ Medium (cluster) | ✅ **Lowest** | ❌ High | ❌ High |
| C3 Network model (**gate**) | ✅ outbound-only | ✅ outbound-only | ✅ outbound-only | ⚠️ **needs AWS↔GitLab reachability** | ✅ outbound-only | ✅ |
| C4 Isolation | ✅ 1 job/instance | ✅ 1 job/instance | ✅ pod, `namespace_per_job` | ✅ ephemeral host | ✅ task | ✅ |
| C5 Idle cost | ⚠️ manager 24/7 + idle | ⚠️ same, Spot by default | ✅ shared nodes | ✅ **none** | ⚠️ manager 24/7 | ⚠️ |
| C6 Start latency | ⚠️ EC2 boot | ⚠️ EC2 boot | ✅ fast if warm | ✅ fast (Lambda) | ⚠️ | ⚠️ |
| C7 Capability coverage | ✅ any AMI | ✅ any AMI | ⚠️ no privileged | ✅ EC2+Lambda, ARM, Win | ❌ `image:` ignored | ✅ |
| C8 Fleet dashboard fit | ✅ | ✅ | ✅ | ❌ outside it | ⚠️ | ✅ |
| C9 Supply chain | ✅ none | ⚠️ module pin | ✅ official chart | ⚠️ AWS lock-in | ❌ | ❌ |
| C10 Effort to stand up | ❌ Highest | ✅ **Low** | ⚠️ Medium (if EKS exists) | ⚠️ Low *if* C3 passes | ❌ | — |

---

## 6. Cost model

| Option | Pays for | Main lever | Structural weakness |
|---|---|---|---|
| cattle-ops / self-provisioned | Manager 24/7 + job instances (**Spot by default**) + NAT + S3 cache | `idle_count`, Spot mix, instance right-sizing | Idle capacity and the always-on manager bill regardless of job volume |
| K8s on EKS | Marginal node capacity (+ cluster overhead if new) | Karpenter consolidation, requests/limits accuracy | Over-requested pods waste whole nodes |
| CodeBuild | Per build-minute only | Lambda compute for short jobs; right-size per job label | On-demand rates, no Spot equivalent; heavy long builds can cost more than Spot EC2 |
| Fargate | Manager 24/7 + task-seconds | — | Worst of both |

Rules of thumb worth testing rather than trusting: **spiky, short, numerous jobs favour
CodeBuild** (no idle, fast Lambda starts); **sustained, long, heavy builds favour Spot EC2
or existing EKS nodes**. The crossover is real and workload-specific — measure it in the
PoC (§10) with cost per job-minute, the same unit used in `gitlab-byo-runners.md` §8.

Do not forget the costs that aren't compute: NAT gateway data processing (large on
container-pull-heavy CI), S3 cache storage and requests, and the engineer-days in C2.

---

## 7. Multi-tenancy on a shared fleet

A shared fleet serves **every project on the instance**, so isolation defaults matter more
here than anywhere else.

- **`capacity_per_instance = 1` and `max_use_count = 1`** — non-negotiable. GitLab's own
  docs warn that jobs sharing an instance have little isolation and can affect each other;
  on a fleet serving all projects that means cross-project contamination.
- On Kubernetes, prefer **`namespace_per_job`** and set resource **limits**, not just
  requests, so one job can't starve the node.
- **No `privileged = true`** and **no `/var/run/docker.sock` mount** on a shared fleet.
  Container builds go through a rootless builder (Kaniko/Buildkit) — consistent with the
  Omni pipeline decision already documented in
  `docs/omni-bitbucket-to-gitlab-migration.md`.
- **`run_untagged`**: for the shared default fleet this should be **`true`** — the opposite
  of the tenant-runner rule — so that ordinary jobs land somewhere without every author
  learning tag names. Publish tags for the *special* capabilities (`arm64`, `windows`,
  `gpu`, `large`).
- **Keep deploy credentials off the shared fleet.** Run a separate, small fleet with
  `access_level = ref_protected` for protected-branch/environment jobs, or keep deploys on
  a project runner. A shared runner that can pick up protected jobs for any project is a
  credential-blast-radius problem.
- Instance runners use **fair-usage queueing** (unlike group/project runners' FIFO), which
  is a genuine advantage — one project can't monopolise the fleet with a thousand queued
  jobs.
- Cap `maximum_timeout` on the runner record, and `max_instances` on the autoscaler, as
  cost circuit-breakers.

---

## 8. Metering and chargeback — this fleet *is* measurable

The BYO doc's central cost problem was that group and project runners consume **no**
compute minutes, so GitLab offers no usage signal. **Instance runners do consume compute
minutes**, and a compute quota can be applied to admin-managed instance runners. The quota
is **disabled by default** but can be enabled for top-level groups and user namespaces.

So for the shared fleet we get, without any AWS work:

- Per-namespace consumption for showback.
- An optional **hard quota** per top-level group — the cleanest available answer to
  "someone's CI is eating the shared fleet".
- The **Ultimate runner fleet dashboard**: runner-infrastructure-caused CI errors,
  concurrent jobs on the busiest runners, compute minutes used by instance runners, and
  **job queue time** — with *runner usage* and *wait time to pick up job* requiring the
  **ClickHouse** integration.

Still tag the AWS resources per `gitlab-byo-runners.md` §8 so GitLab-side minutes can be
reconciled against actual AWS spend; that ratio is what tells you `idle_count` is wrong.
**Note that a CodeBuild-based fleet sits outside this** — its usage is measured in
CodeBuild/CloudWatch, not by the GitLab fleet dashboard, which is a real (if survivable)
observability regression.

---

## 9. Requirements

| # | Requirement | Priority |
|---|---|---|
| S1 | Execution layer must be a GitLab-supported executor (`docker-autoscaler`, `instance`, or `kubernetes`) unless CodeBuild passes its gate | MUST |
| S2 | `capacity_per_instance = 1`, `max_use_count = 1` (or `namespace_per_job` on K8s) | MUST |
| S3 | No `privileged`, no Docker socket mount; container builds use a rootless builder | MUST |
| S4 | Deploy/protected jobs run on a separate `ref_protected` fleet, not the general shared fleet | MUST |
| S5 | `max_instances` and `maximum_timeout` set as cost circuit-breakers | MUST |
| S6 | Minimum **two runner managers** for HA on any autoscaled EC2 option (GitLab's stated minimum) | MUST |
| S7 | No registration tokens; `glrt-` authentication tokens, stored in SSM/Secrets Manager | MUST |
| S8 | Nothing built on `docker+machine` or the Fargate driver | MUST |
| S9 | Third-party Terraform module pinned to an exact version; upgrades reviewed against the migration notes | MUST |
| S10 | AWS resources tagged per `gitlab-byo-runners.md` §8; cost-allocation tags activated first | MUST |
| S11 | Compute-minute reporting enabled; quota available per top-level group | SHOULD |
| S12 | ClickHouse integration for fleet-dashboard queue-time metrics | SHOULD |
| S13 | Spot for build/test with job-level `retry:`; on-demand for anything non-retryable | SHOULD |
| S14 | If CodeBuild is adopted, secret masking enabled on every CI/CD variable before rollout | MUST *(if CodeBuild)* |
| S15 | Shared-fleet `run_untagged = true`; capability tags published for special hardware | SHOULD |

---

## 10. Recommendation and PoC gates

**Primary recommendation:** provision with **cattle-ops `terraform-aws-gitlab-runner`
(pinned, v8 line)** running the **`docker-autoscaler`** executor with **Spot** job
instances, single-use, two runner managers, S3 cache — plus a small separate
`ref_protected` fleet for deploy jobs.

**Switch to the `kubernetes` executor via the official Helm chart** if EKS is already a
supported platform for us with spare capacity — the AMI maintenance saving is the deciding
factor, not raw cost.

**Evaluate CodeBuild in parallel, gated.** Do the network test first; it's a day of work
and it decides whether the option exists at all.

### PoC — run these in order, with pass/fail gates

| # | Test | Pass criteria |
|---|---|---|
| 0 | **CodeBuild network gate:** can AWS establish a CodeConnections/OAuth link to our GitLab, and can GitLab deliver a `WORKFLOW_JOB_QUEUED` webhook to a CodeBuild project — without exposing GitLab publicly? | Connection established over PrivateLink/approved path, webhook received. **Fail → CodeBuild is out; skip test 3** |
| 1 | Stand up cattle-ops + `docker-autoscaler`, 2 managers, Spot, single-use instances | A canary job runs; a second concurrent job triggers scale-out; instances terminate after the job |
| 2 | Same on the `kubernetes` executor (only if EKS is in scope) | Equivalent canary passes with `namespace_per_job` |
| 3 | CodeBuild project with group webhook, image + instance overrides via job labels; **secret masking on** | Job runs, correct image, **no secret visible in the build log** |
| 4 | **Load + cost run:** replay a representative day of pipelines on each surviving option | Record p50/p95 **queue time**, p50 job duration, **cost per job-minute**, and failure rate. Include a Spot-interruption case |
| 5 | Isolation check | Job A cannot observe job B's workspace, env, or credentials on any surviving option |
| 6 | Failure-mode check | Manager restart mid-job, Spot interruption, ASG capacity exhaustion — all fail *visibly* (job retries or errors), never silently hang |

Decide on test 4's numbers, not on this document's opinion.

### Phasing

| Phase | Work |
|---|---|
| 0 | Network gate (test 0) + confirm whether EKS is in scope. These two answers collapse the option space |
| 1 | cattle-ops + `docker-autoscaler` fleet in non-prod; canary + isolation tests |
| 2 | Load/cost run against the surviving options; pick the primary |
| 3 | Roll out as instance runners with fair-usage queueing; separate `ref_protected` fleet; compute-minute reporting on |
| 4 | ClickHouse + fleet dashboard; quarterly idle-cost and version-drift review |

---

## 11. Gotchas, ranked

1. **Treating cattle-ops as an alternative to GitLab Runner** → you compare a Terraform
   module against a runtime and pick incoherently. It provisions the runtime (§2).
2. **Designing on CodeBuild before proving the network path** → weeks of work invalidated
   by the fact that AWS can't reach a private GitLab.
3. **CodeBuild with unmasked secrets** → credentials in build logs on a fleet serving every
   project. Masking is per-variable and **off by default**.
4. **Instance reuse on a shared fleet** (`max_use_count = 0`) → cross-project
   contamination, the worst failure mode available here.
5. **Shared runner able to pick up protected-branch jobs** → deploy credentials exposed to
   every project's pipeline. Separate fleet (S4).
6. **One runner manager** → single point of failure; GitLab's stated minimum is two.
7. **Bumping the cattle-ops module without reading the migration notes** → v7/v8 both
   needed their own guides for a reason. Pin and review.
8. **Assuming the Ultimate fleet dashboard covers everything** → a CodeBuild fleet is
   invisible to it, and the metrics that matter need ClickHouse.
9. **Adopting EKS *in order to* run CI** → the k8s executor is cheap only when the cluster
   already exists and is well-operated.
10. **Ignoring NAT and cache costs** → container-pull-heavy CI can spend more on NAT data
    processing than on compute.
11. **Building anything new on `docker+machine` or the Fargate driver** → removed in
    **20.0 (May 2027)**, and explicitly not-for-production, respectively.

---

## 12. Open questions

1. **Is our self-managed GitLab reachable from AWS** (CodeConnections/OAuth), and can it
   deliver webhooks to CodeBuild without being publicly exposed? *(Gate — test 0.)*
2. **Is EKS a first-class platform for us** with spare capacity, or would CI be the reason
   we adopt it? *(Decides §3.3 vs §3.2.)*
3. What's the real job mix — many short jobs or fewer long heavy builds? Determines the
   CodeBuild-vs-Spot-EC2 crossover (§6).
4. Do we need Windows, arm64, or GPU capability in year one? Affects whether one fleet
   suffices.
5. Will compute-minute **quotas** be enforced per group, or is reporting-only enough
   politically?
6. Who owns the shared fleet's on-call, and what queue-time SLO are we committing to?

---

## Sources

- [GitLab Runner Autoscaling — overview](https://docs.gitlab.com/runner/runner_autoscale/)
- [GitLab Runner instance group autoscaler](https://docs.gitlab.com/runner/runner_autoscale/gitlab-runner-autoscaler/)
- [Docker Autoscaler executor](https://docs.gitlab.com/runner/executors/docker_autoscaler/)
- [Instance executor](https://docs.gitlab.com/runner/executors/instance/)
- [Kubernetes executor](https://docs.gitlab.com/runner/executors/kubernetes/)
- [Plan and operate a fleet of instance or group runners (two-manager minimum, GitLab.com reference)](https://docs.gitlab.com/runner/fleet_scaling/)
- [Manage runners — scopes and fair-usage queueing](https://docs.gitlab.com/ci/runners/runners_scope/)
- [Compute minutes (instance runners consume; project/group runners do not)](https://docs.gitlab.com/ci/pipelines/compute_minutes/)
- [Runner fleet dashboard for administrators (Ultimate)](https://docs.gitlab.com/ci/runners/runner_fleet_dashboard/)
- [cattle-ops/terraform-aws-gitlab-runner (GitHub)](https://github.com/cattle-ops/terraform-aws-gitlab-runner)
- [cattle-ops/gitlab-runner/aws — Terraform Registry](https://registry.terraform.io/modules/cattle-ops/gitlab-runner/aws/latest)
- [cattle-ops — runner-fleeting-plugin example](https://registry.terraform.io/modules/cattle-ops/gitlab-runner/aws/latest/examples/runner-fleeting-plugin)
- [cattle-ops issue #624 — implementing the new autoscaling architecture](https://github.com/cattle-ops/terraform-aws-gitlab-runner/issues/624)
- [Self-managed GitLab runners in AWS CodeBuild](https://docs.aws.amazon.com/codebuild/latest/userguide/gitlab-runner.html)
- [About the CodeBuild-hosted GitLab runner (shell executor, secret masking, regions, compute)](https://docs.aws.amazon.com/codebuild/latest/userguide/gitlab-runner-questions.html)
- [AWS: CodeBuild adds managed runners for GitLab Self-Managed](https://aws.amazon.com/about-aws/whats-new/2025/02/aws-codebuild-managed-runners-gitlab-self-managed)
- [Autoscaling GitLab CI on AWS Fargate (community supported, not for production)](https://docs.gitlab.com/runner/configuration/runner_autoscale_aws_fargate/)
- [Docker Machine executor (deprecated 17.5, removed 20.0)](https://docs.gitlab.com/runner/executors/docker_machine/)
