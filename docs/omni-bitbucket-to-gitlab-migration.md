# Omni: Bitbucket Server → GitLab Migration — Findings & Runbook

> Scope: migrate the **Omni** (in-house RAG app) repository from **self-hosted Bitbucket
> Server / Data Center** to a **self-hosted GitLab CE** instance, keeping **JFrog
> Artifactory** as the registry for the 3 Docker images + Helm chart.
> Status: research/planning. First-time migration — written to be de-risked.
> Last updated: 2026-06-11.

---

## TL;DR

- A "repo migration" here is really **three** separate jobs: (1) git history + metadata,
  (2) the build/publish pipeline, (3) team access + branch protections. Only #1 is
  automated; #2 is the real work; #3 is manual.
- Because the target is **self-hosted CE**, the scary GitLab.com SaaS Free limits
  (5-user cap, 400 CI min/mo, 10 GiB storage) **do not apply**. Unlimited users/CI,
  storage = whatever the box has. CI is BYO runner.
- Moving the **code** is trivial and zero-risk (`git push --mirror`). The only thing
  worth deliberating is whether to also pull **PR/comment history** across via GitLab's
  built-in Bitbucket Server importer (flakier).

---

## 1. The three layers of the migration

| Layer | Automated? | Effort | Risk |
|-------|-----------|--------|------|
| Git history, branches, tags, (optionally) PRs/comments | Yes (importer) or trivial (mirror) | Low | Low |
| Build + publish the 3 Docker images + Helm chart to Artifactory | **No — greenfield `.gitlab-ci.yml`** | **High** | **High** |
| Devs, branch protections, MR approval rules | No — reconfigured by hand | Medium | Medium |

The ticket *says* "migrate the repo" but the weight is in layers 2 and 3.

---

## 2. Moving the code — two options

### Option A — `git push --mirror` (recommended for code)
Guaranteed, ~5 minutes, no API, no token drama. Moves **100% of commits, branches, tags**.
What you *lose*: PR / comment / approval history (stays readable in the now read-only
Bitbucket as an archive).

```bash
git clone --mirror https://bitbucket-server/scm/<proj>/omni.git
cd omni.git
git remote set-url --push origin git@gitlab.example.com:<group>/omni.git
git push --mirror
```

### Option B — GitLab's built-in Bitbucket **Server** importer
GitLab UI → *New project* → *Import project* → *Bitbucket Server*. Talks to the Bitbucket
Server REST API and replays metadata into GitLab. Also scriptable via the [Import API].

**Migrates:** git data + history, public/private setting, **PRs → MRs with comments,
reviewers, merge events**, **PR approvals + approval rules (GitLab 16.7+)**, LFS objects,
inline code comments.

**Does NOT migrate:** branch protection rules, task lists, emoji reactions, Markdown
attachments. (Bitbucket Server has no native issues — you're on Jira — so nothing lost there.)

**Prerequisites / gotchas:**
- **Admin-access** Bitbucket Server token. *Without admin, some data silently doesn't import.*
- GitLab instance must have **network line-of-sight** to the Bitbucket Server URL
  (sort proxy/firewall first or the import just hangs).
- **User mapping is by email** — a dev whose Bitbucket email ≠ GitLab email has their
  authorship collapsed onto whoever ran the import. Line emails up *before* importing.
- Importer flakiness lives in the **metadata** layer (deeply nested comment threads,
  special chars in LFS creds), never the git data. Big-repo timing (~8h) was for
  500 GiB / 13k PRs — Omni is nowhere near that.

### Decision
If old PR discussion threads inside GitLab matter → Option B, budget time to babysit it.
If the code + history is what counts (most teams) → **Option A**, archive Bitbucket read-only.

---

## 3. The pipeline — greenfield, Artifactory stays

There's no Bitbucket Pipelines to translate (builds are manual today). This is new
`.gitlab-ci.yml` authoring and is where most effort + risk sits.

- **Need a self-hosted GitLab Runner.** "Unlimited CI minutes" on CE only holds if a
  runner exists — it's BYO compute. Omni deploys via Helm/k8s, so a **Kubernetes-executor
  runner** is the natural fit.
- **Build images with Kaniko, not docker-in-docker.** DinD needs `privileged: true`
  (security smell on a shared k8s runner); Kaniko is rootless. Use the
  `gcr.io/kaniko-project/executor:debug` image.
- **Artifactory auth** = a CI user token stored as **masked + protected** CI/CD variables,
  written into `/kaniko/.docker/config.json`.
- **Helm**: `helm package` then push to the Artifactory Helm repo (OCI `helm push`, or
  `jf`/curl upload).
- **Map the branch model onto branch rules + protected variables:**
  - `develop` = default branch; devs merge via MR; builds tag `:develop` / `:<sha>`.
  - `main` = protected, only the maintainer merges. Mark the **prod-push** Artifactory
    creds as *protected* variables so they are **only exposed on `main`** — this
    mechanically enforces "maintainer reconciles `develop`→`main` and pushes prod";
    devs literally cannot trigger a prod publish.

> Branch model assumed: `develop` = integration (≈4 devs MR in), `main` = deployed prod,
> maintainer does the `develop`→`main` reconciliation. **Confirm before relying on this.**

---

## 4. Cutover sequence (de-risked)

1. **Pre-flight** — confirm GitLab→Bitbucket network path; mint admin token; reconcile
   dev emails; stand up the runner.
2. **Dry-run import** into a throwaway GitLab project — see exactly what lands.
3. **Freeze window** — coordinate with devs: no new PRs into `develop` during cutover,
   or you lose the delta.
4. **Move the code** — Option A or B above. (Option A is the always-works fallback if B
   misbehaves.)
5. **Rebuild governance** — branch protections, default branch, add devs, MR approval rules.
6. **Author + validate the pipeline** — prove CI-built images/chart match the
   hand-built artifacts *before* trusting it.
7. **Keep Bitbucket read-only** ~2 weeks as a rollback net.
8. **Chase dangling references** — repo URLs in the Helm chart/scripts, ArgoCD/deploy
   sources, and **webhooks** (Bitbucket→Artifactory / →deploy hooks don't migrate;
   recreate them in GitLab).

---

## 5. Top gotchas, ranked by how much they'll bite

1. **Branch protections not rebuilt** → a dev pushes straight to prod. (Not auto-migrated.)
2. **Dangling Bitbucket URLs** in deploy config/webhooks → silent breakage post-cutover.
3. **Email mismatch** → authorship history mangled, and it's **unrecoverable after import**.

---

## Sources

- [Migrate from Bitbucket Server — GitLab Docs](https://docs.gitlab.com/user/import/bitbucket_server/)
- [Migrate from Bitbucket Cloud — GitLab Docs](https://docs.gitlab.com/user/import/bitbucket_cloud/) (contrast)
- [Import API — GitLab Docs](https://docs.gitlab.com/api/import/)
- [Free tier user/group limits — GitLab Docs](https://docs.gitlab.com/user/free_user_limit/) (why self-hosted CE avoids the caps)
- [Use Kaniko to build Docker images — GitLab Docs](https://docs.gitlab.com/ci/docker/using_kaniko/)
- [GitLab CI + Artifactory — JFrog](https://jfrog.com/blog/gitlab-and-artifactory-on-your-mark-get-set-build/)
- [JFrog gitlab-templates](https://github.com/jfrog/gitlab-templates)

[Import API]: https://docs.gitlab.com/api/import/
