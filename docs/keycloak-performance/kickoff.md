# Keycloak Performance Testing — Work-Claude Kickoff

> Paste the prompt below to Claude Code in the work environment. It pairs with
> `docs/keycloak-performance/brief.md` in this repo — pull latest `main` first
> so both files are present. Run it from the repo that holds the **Keycloak
> Terraform/Helm code** (or have that path handy).
>
> Work-Claude has **WebFetch but no web search** — the brief's §10 source table
> holds every URL it needs. Point it there rather than expecting it to find
> sources itself.

## Kickoff prompt (paste verbatim)

Read `docs/keycloak-performance/brief.md` in this repo in full before doing anything. **Important: that brief describes UPSTREAM Keycloak behaviour and upstream tooling — the sizing formulas, bottleneck rankings and throughput figures are Red Hat's published numbers from their hardware, NOT findings about our deployment. Your job is to measure ours. Where evidence contradicts the brief, trust the evidence and say so.**

You have WebFetch but no web search. Every URL you need is in the brief's §10 source table — fetch from there if you need more depth. Don't guess at upstream behaviour; look it up or read the source.

**All testing is in dev only. Nothing in this engagement touches prod.**

Do this in order:

1. **Phase 0 — resolve the three unknowns in §0.2 before designing any test.** Report findings before proceeding:
   - **Real scale** — realm user count, and the realistic peak login rate. The ticket says "100 users login at 8am"; per §0.2 that is ~1.7 logins/sec, roughly 0.11 vCPU, which a correctly resourced Keycloak will not notice. Establish whether the real population is larger, or whether the actual risk is one of the alternatives in §0.2 (concurrent corp sync, admin ops, group queries, cold-cache thundering herd). **State which hypothesis you are testing and why.**
   - **SLO** — find a stated one, or propose one using §10 [S6]. This is a hard prerequisite: `kcb.sh` defines run failure via `-Dsla-mean-response-time` (default 300ms) and `-Dsla-error-percentage` (default 0), and the breaking-point search in §3.5 is driven by those assertions. Leaving defaults in place silently asserts an SLO nobody agreed to.
   - **Dev↔prod parity** — a Terraform/Helm diff of replica count, CPU/memory requests+limits, DB instance class, and AZ topology. Per §7.4, an AZ-topology difference alone can make dev look dramatically better than prod.

2. **Deliver the §1 analytical resourcing verdict before running any load.** This answers AC4 from Terraform/Helm plus the §1.1 formulas — extract the §1.2 table of values, apply the formulas, write the §1.3 verdict. Do this even if testing later gets blocked; it stands alone.

3. **STOP and show me Phase 0 findings + the analytical verdict before running any load test.** I want to confirm we're testing the right hypothesis before we spend time generating numbers.

4. **Land the §2 instrumentation prerequisites.** Note that Keycloak metrics are **off by default and `metrics-enabled` is a BUILD-TIME option** — it needs an augmented image and a pod restart, not a config flip. Flag it to me as soon as you know what that costs us in dev. Capture a §2.3 idle baseline before the first run.

5. **Run the §4 phases in order**, observing every rule in §4.1 — in-cluster load generators (never over VPN), generator-not-the-bottleneck checks, pinned replicas, one variable per run, and prod-matched `password-hash-iterations`. Record the exact keycloak-benchmark release tag used.

6. **Build the §5 group-members probe** — `GET /admin/realms/{realm}/groups/{id}/members` is genuinely absent from the keycloak-benchmark DSL and is the one thing we write ourselves. Keep it small; it's a measurement script, not a product.

7. **Report in the §8 structure.** Lead with the plain-English one-paragraph summary — that summary is the actual deliverable, everything else is evidence. Include §8's threats-to-validity item honestly; dev↔prod deltas belong in the report, not hidden.

Respect §9 throughout — in particular: the dataset provider must never be installed in prod (it mutates without authentication), no capacity claim about prod goes unlabelled as extrapolated, and **no tuning changes are applied during the investigation**. Measure first, recommend second; a config change mid-engagement invalidates every run before it.

Treat anything that mutates prod, triggers a sync against the corporate LDAP/AD, or changes Terraform state as requiring my explicit go-ahead.

## Prerequisites — have these ready or work-Claude will block

| Need | For |
|---|---|
| Repo/path holding the Keycloak Terraform + Helm values, with `terraform`/`git` access | §1.2 extraction, Phase 0 parity diff |
| `kubectl` against the **dev** RKE2 cluster, namespace of the Keycloak deployment | Everything from §2 onward |
| Ability to change the dev Keycloak image / run `kc.sh build` and restart pods | §2.1 — metrics is a build-time option |
| Keycloak admin credentials for dev (admin console or `kcadm.sh`) | §3.2 admin scenarios, §5 probe, §6 sync trigger |
| A confidential client with a service account + secret in the dev realm | `JoinGroup`, `CreateUsers`, `UserCrawl` — most admin scenarios need a client secret, not admin creds |
| Keycloak version (`kcadm.sh get serverinfo` or pod image tag) | §3.1 — the dataset JAR tag must match the Keycloak minor version |
| Ability to deploy the dataset provider JAR to dev Keycloak | §3.3 seeding + cache-clear endpoints |
| Ability to run a k8s Job on the dev cluster (JVM/Java 17 image) | §4.1 — in-cluster load generation |
| Egress from the dev cluster (or a mirror) to fetch the keycloak-benchmark release assets | §3.1 |
| Prometheus/Grafana reachable, or ability to scrape Keycloak `/metrics` | §2.2 |
| RDS metrics access for the Keycloak database (CPU, connections) | §7.1 — the usual first bottleneck |
| Prod realm's `password-hash-iterations` value (read-only) | §3.3 — dev must match or login numbers are meaningless |
| Confirmation of what the **dev** LDAP/AD federation actually points at | §6 — before triggering any sync |
| The ticket's stated SLO, if one exists | §0.2, §3.4 |

## Hard constraints (restate — don't let work-Claude skip these)

- **Dev only.** No load, no dataset provider, no sync trigger against prod.
- **Hypothesis before numbers.** Phase 0 first. "100 users at 8am" is ~1.7 logins/sec and almost certainly not the real risk — testing the wrong hypothesis thoroughly is the main failure mode available here. Confirm the hypothesis with me before generating load.
- **The brief is priors, not findings.** Upstream formulas and bottleneck rankings are Red Hat's numbers from Red Hat's hardware. Don't report them as ours.
- **Measure first, tune second.** No configuration or resourcing change applied during the investigation. A mid-engagement change invalidates every prior run.
- **Load generators run in-cluster.** Generating load from a laptop over VPN measures the VPN. It silently invalidates the entire engagement and won't be visible in the results.
- **Open vs closed load model is not interchangeable.** `--users-per-sec` (open) for anything capacity-related; `--concurrent-users` (closed) throttles itself and can never reveal a breaking point.
- **Set the SLA flags deliberately.** `-Dsla-mean-response-time` defaults to 300ms and `-Dsla-error-percentage` to 0. Defaults left in place are an unexamined SLO claim.
- **The dataset provider mutates without authentication.** Dev only; removed or disabled when the engagement ends.
- **Extrapolation must be labelled.** Any statement about prod capacity derived from dev must say so and state the parity deltas — especially AZ topology (§7.4), where a 20ms RTT difference took upstream response times from 130ms to ~1076ms.
- **Corp LDAP/AD is a real corporate system.** Confirm the dev federation target before triggering a full sync; get agreement if it reaches prod AD even read-only.
- **Break it deliberately, in dev, on purpose** (§4.6) — but record the failure *mode*, not just the number. "Fine to N" without "and it fails like this at P" is a weak deliverable.
