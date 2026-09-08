# What We Get With GitLab Ultimate

> Scope: what the **Ultimate** licence unlocks on our **self-managed** instance, what it
> does *not* include, and the order worth adopting it in.
> Verified against **GitLab 19.3** (latest release as of writing, Aug 2026).
> Last updated: 2026-09-09.
>
> **Read the tier caveat in §0 before promising any single feature to anyone.**

---

## TL;DR

- Ultimate is bought for **security scanning + compliance + governance**. Everything else
  it adds (portfolio planning, some analytics, custom roles) is real but secondary.
- **Nothing migrates.** Applying the licence lights features up in place — no data move,
  no re-clone, no re-registering runners.
- **The scanners are CI jobs.** Turning on SAST/DAST/dependency/container scanning across
  the estate directly increases runner load and therefore runner cost. This is the direct
  link to the BYO-runners ticket: if tenant-funded runners are the only compute, **the
  tenant pays for our compliance programme** unless we deliberately pin scanning jobs
  elsewhere. See `gitlab-byo-runners.md` §8.
- **GitLab Duo is not one thing.** *Duo Core* is included with Premium and Ultimate;
  *Duo Pro* and *Duo Enterprise* are **separately purchased add-ons**. Assume any AI
  feature beyond Core costs more money until Procurement confirms otherwise.
- **Tier membership moves between releases** — the Value Streams Dashboard moved *down*
  from Ultimate to Premium in 18.2. Verify per feature against the docs for our installed
  version rather than trusting a comparison table (including this one).

---

## 0. Tier caveat — how to check a claim

Every GitLab docs page carries a **Tier** badge (`Tier: Ultimate`, `Tier: Premium,
Ultimate`) and an **Offering** line (`GitLab.com, GitLab Self-Managed, GitLab Dedicated`).
That badge on the docs page for **our installed version** is the only authority. Two
traps:

- Features move tiers between releases (VSD, 18.2, Ultimate → Premium).
- Some features are `GitLab.com` only, or self-managed only from a given version — the
  advanced security dashboards, for example, landed on Self-Managed in 18.7 and went GA in
  18.8, so anything older than that on our instance won't have them.

Third-party "Premium vs Ultimate" blog comparisons are unreliable, including on pricing.
Don't quote them in the ticket.

---

## 1. Security — the main reason to hold this licence

| Capability | What it does | Notes |
|---|---|---|
| **SAST** | Static analysis on merge requests, findings inline in the MR | Available broadly, but the good analyzers are Ultimate-gated |
| **GitLab Advanced SAST** | Cross-function, cross-file taint analysis; far fewer false positives than the stock analyzers | **Ultimate only.** The single biggest quality jump — enable this rather than leaving stock SAST on |
| **DAST** | Runs against a deployed review-app/environment | Ultimate. Needs a deployable environment, so it's the slowest to adopt |
| **Dependency scanning** | Vulnerable dependencies + the dependency list / SBOM | Ultimate |
| **Container scanning** | CVEs in built images | Ultimate. Pairs naturally with our Artifactory image pipeline |
| **Secret detection** | Finds committed secrets in history and MRs | Broadly available |
| **Secret push protection** | **Blocks the push** when a secret is detected, instead of reporting after the fact | Enable per group. The highest value-per-minute-of-effort item on this page |
| **Security dashboards / vulnerability management** | Aggregated vulnerability posture across project → group → instance, with triage workflow, dismissal, and issue creation | Ultimate. Advanced version: Self-Managed from 18.7, GA 18.8 |
| **Security policies** | Merge-request approval policies, scan execution policies, **pipeline execution policies** | Ultimate. See §5 — this is the enforcement layer, and the one that touches runners |

**Adoption warning:** switching every scanner on across every project at once produces a
vulnerability backlog nobody triages and MR noise that trains developers to ignore
security findings. Pilot on one or two projects, tune, then roll out — and set a
dismissal/triage owner before, not after.

---

## 2. Compliance & governance

Per the compliance docs page (`Tier: Ultimate`, all three offerings):

- **Compliance Center** — organisation-wide compliance posture and violations in one place.
- **Compliance frameworks** — declare the requirements a project must satisfy, applied at
  group level and attached to projects.
- **Compliance standards adherence reporting** — which projects meet which controls, which
  is what an auditor actually asks for.
- **Audit events** — instance-wide record of who changed what, including runner
  create/delete and token operations. Directly useful for the BYO-runner story: it's the
  evidence trail for "who onboarded this tenant runner".
- **External status checks** — gate merges on a third-party system (project level).
- **Separation of duties** via protected branches + protected environments, which is what
  makes the "only the maintainer can publish to prod" pattern in our Omni migration doc
  enforceable rather than a convention.

---

## 3. Access control — custom roles

**Ultimate, all offerings.** Build a role with exactly the permissions needed instead of
promoting people to Maintainer or Owner to unblock one task. Requires Administrator to
define on self-managed.

Concretely useful for this ticket: define a **runner operator** role that can create and
manage group runners without being a group Owner. Today that job needs Owner, which is a
much bigger grant than "can register a CI runner".

---

## 4. Planning & portfolio

- **Epics** with **nested/multi-level hierarchy** in Ultimate — break initiatives into
  child epics that hold their own issues and tasks.
- **Roadmaps** — timeline view over epics.
- **OKRs / objectives and key results**, insights, and productivity analytics.

Useful, but this is the part that quietly turns into a Jira-replacement project. Don't put
it in Phase 1.

---

## 5. CI/CD and runner-relevant features (relevant to the BYO ticket)

| Feature | Value |
|---|---|
| **Runner fleet dashboard** (Admin → CI/CD → Runners → Fleet dashboard) | **Ultimate.** CI errors caused by runner infrastructure, concurrent jobs on the busiest runners, compute minutes used by instance runners, and **job queue times** — the only place queue time is measured for us. Group-level equivalent also exists |
| **Runner performance statistics** | Ultimate. Median job queued time, sampled from recent jobs |
| **ClickHouse integration** | Prerequisite for the *runner usage* and *wait time to pick up job* panels. Not optional if you want the numbers that justify `idle_count` |
| **Pipeline execution policies** | Ultimate. Inject required jobs into pipelines centrally — how you *guarantee* every project runs the security scanners, and how you'd pin those scanner jobs to a **platform-funded runner** instead of a tenant's |
| **Scan execution policies** | Ultimate. Same idea, scoped to security scans, enforced at group level |

The last two are the mechanism that resolves §8's "who pays for scanning" question: a
pipeline execution policy can carry its own `tags:`, so compliance scanning lands on our
compute while the tenant's runners keep building the tenant's code.

---

## 6. What Ultimate does *not* include

| Thing | Reality |
|---|---|
| **GitLab Duo Pro / Duo Enterprise** | **Separately purchased add-ons.** Not bundled with Ultimate |
| **GitLab Duo Core** | *Is* included with Premium and Ultimate — Code Suggestions, and from 19.0 Agentic Chat plus Duo Agent Platform features (foundational, custom, and external agents) |
| **GitLab Secret Manager** | Paid add-on via GitLab Credits after its 19.0 public beta; announced for GitLab.com — **confirm self-managed availability and cost separately before designing around it** |
| **Compute minutes / storage** | A GitLab.com concern. On self-managed with BYO runners, we pay AWS, not GitLab (see `gitlab-byo-runners.md` §8) |
| **The support tier** | Ultimate is commonly sold with priority support / TAM, but **what we actually bought is contractual** — check the order form rather than assuming |
| **Anything ClickHouse needs** | The fleet-dashboard metrics require us to stand up and operate ClickHouse. Ultimate unlocks the feature, not the infrastructure |

---

## 7. Suggested adoption order

| Phase | Do | Why first |
|---|---|---|
| **1 — days 0–30** | Apply the licence and confirm the tier in Admin. Turn on **secret push protection** at group level. Enable **Advanced SAST** + **dependency scanning** on 2–3 pilot projects. Enable **audit events** review | Highest value, lowest blast radius. Push protection prevents a class of incident outright |
| **2 — days 30–60** | **Custom roles**: define runner-operator and security-reader roles and pull back over-granted Owner/Maintainer. Stand up the **runner fleet dashboard**; scope the ClickHouse work | Directly unblocks the BYO-runner ticket and reduces standing privilege |
| **3 — days 60–90** | **Compliance frameworks** + adherence reporting on the projects that are actually in audit scope. **Pipeline execution policy** to enforce scanning — with `tags:` pinning scanner jobs to platform-funded runners | Compliance value only lands once frameworks map to real controls |
| **4 — later** | Container scanning across the image pipeline; **DAST** where review apps exist; portfolio planning (epics/roadmaps/OKRs) if there's genuine appetite | Each needs environments or process change, not just a toggle |

---

## 8. Traps

1. **Enabling every scanner everywhere on day one** → unreviewed vulnerability backlog and
   MR noise that trains people to ignore findings.
2. **Forgetting scanners are CI jobs** → runner cost jumps, and on BYO runners it lands on
   the tenant's bill. Decide funding before the rollout, and use pipeline execution policy
   `tags:` to enforce it.
3. **Quoting a tier from a blog or an old comparison table** → features move (VSD, 18.2).
   Cite the docs page for our installed version.
4. **Assuming "Ultimate" means "AI included"** → only Duo **Core**. Pro/Enterprise cost
   more.
5. **Assuming the fleet dashboard just works** → the metrics that matter need ClickHouse.
6. **Licence seat surprises** → confirm how our seat count is measured and reconciled
   (billable members, and how bots/service accounts are counted) before onboarding a wave
   of tenant users.
7. **Compliance frameworks with no owner** → produces a dashboard nobody acts on, which is
   worse than no dashboard in an audit.

---

## Sources

- [GitLab plans / choosing a subscription](https://docs.gitlab.com/subscriptions/choosing_subscription/)
- [Compliance features (Tier: Ultimate)](https://docs.gitlab.com/user/compliance/)
- [Security dashboards](https://docs.gitlab.com/user/application_security/security_dashboard/)
- [GitLab Advanced SAST (Ultimate)](https://docs.gitlab.com/user/application_security/sast/gitlab_advanced_sast/)
- [SAST](https://docs.gitlab.com/user/application_security/sast/)
- [Secret push protection](https://docs.gitlab.com/user/application_security/secret_detection/secret_push_protection/)
- [Custom roles](https://docs.gitlab.com/user/custom_roles/)
- [Roles and permissions](https://docs.gitlab.com/user/permissions/)
- [Epics](https://docs.gitlab.com/user/group/epics/)
- [Value Streams Dashboard (moved to Premium in 18.2)](https://docs.gitlab.com/user/analytics/value_streams_dashboard/)
- [Runner fleet dashboard for administrators (Ultimate)](https://docs.gitlab.com/ci/runners/runner_fleet_dashboard/)
- [Runner fleet dashboard for groups](https://docs.gitlab.com/ci/runners/runner_fleet_dashboard_groups/)
- [GitLab Duo add-ons](https://docs.gitlab.com/subscriptions/subscription-add-ons/)
- [GitLab Duo Agent Platform](https://docs.gitlab.com/user/duo_agent_platform/)
- [GitLab 19.0 release notes](https://docs.gitlab.com/releases/19/gitlab-19-0-released/)
- [GitLab release notes index](https://docs.gitlab.com/releases/)
