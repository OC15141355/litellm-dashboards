# LiteLLM Cost Tracking Incident — Investigation Brief

## Context

Cost tracking for `au.`-prefixed Bedrock models (Australian regional inference profiles) showed `spend = 0` in `LiteLLM_SpendLogs` starting May 12, 2026. ~6131 affected requests over a week before detection (via Grafana cost panel flatlining). Service unaffected throughout. Token counts intact and recoverable.

Root cause is at least two interacting bugs:

1. **LiteLLM #27612** — UI-added Bedrock regional inference profile models have their region prefix stripped at DB storage time, causing wrong-region (or in our case, zero) pricing.
2. **Possible second `au.` prefix bug** — discovered during today's investigation, distinct from #27612. Needs scoping.

Cost map state shifted on May 12 when our LiteLLM image rolled via floating `:main-stable` tag, which is what made the latent UI bug visible.

## Version posture (READ FIRST)

**Running version is KNOWN: `v1.83.14-stable.patch.3`** (confirmed 2026-05-19; identical to the homelab deployment). The 2026-05-12 incident trigger was the floating `:main-stable` tag rolling the image to this build. Verify on-site if needed:

```bash
curl -s https://<litellm-host>/health/readiness | jq .litellm_version
kubectl -n <ns> get pod -l <selector> -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'
```

**Neither a downgrade NOR an upgrade fixes #27612 — evidenced, do not chase a version.**

- The strip mechanism is `get_bedrock_base_model()` → `_strip_model_name()` (`litellm/utils.py`); `au` was added to the strip-eligible region list by **PR #15402 (commit `a0e81a7f1c`), merged 2025-10-10, first shipped ~v1.78.5**.
- The buggy store-and-lookup path is **identical in v1.83.10-stable and v1.83.14-stable** (diffed). It is **not a recent regression** — it has never worked correctly for UI/DB-stored AU regional inference profiles since `au` support landed.
- The bug therefore **predates the CVE-clean floor (v1.83.10)**. LiteLLM does not backport below 1.83. So **every CVE-safe version has this bug, and every bug-free version is below the security floor.**
- Fix **PR #27625 is OPEN, unmerged, base `litellm_internal_staging`, in NO release** (`gh pr view 27625`). Greptile-flagged on design. Treat as irrelevant to remediation.

### Downgrade verdict — DO NOT (it is a trap)

1. No downgrade target is both CVE-clean and bug-free (bug predates v1.83.10).
2. LiteLLM Prisma migrations are **strictly forward-only — zero `down.sql` files exist** in `litellm-proxy-extras/migrations/`. Downgrading the 1.83.14 schema has no clean reverse path: manual DB surgery or restore-from-snapshot only.
3. Downgrading trades a *fully fixable* cost-accuracy bug for **active CVEs (35030/35029/42203/42271/40217 + GHSA-69x8) + an unrecoverable DB state** — unacceptable under Essential Eight ML2/ML3 / ISM.

Treat the version axis and the cost-bug axis as orthogonal. Version decision = CVE posture + stop the floating-tag roll. Cost-bug fix = config-level only.

**CVE axis (independent of the cost bug):**

- Minimum-safe floor is **v1.83.10**; recommended pin **`v1.83.14-stable.patch.3`**.
- Closes CVE-2026-35030 (9.4 OIDC auth bypass), 35029, 42203, 42271, 40217, GHSA-69x8.
- LiteLLM does **not** backport security fixes to 1.81.x / 1.82.x — verified against GitHub Security Advisory `vulnerable_version_ranges` (single upper bound at the 1.83.x fix, no exclusions for older patch lines). The latest 1.82 stable patch post-dates the CVEs but contains zero security commits.
- **Pin by digest, not tag.** The floating `:main-stable` tag is the root of this incident chain; a digest pin both closes the CVEs and *freezes the cost-map state* so it cannot silently roll again. Verified-available digest:
  `ghcr.io/berriai/litellm-database:v1.83.14-stable.patch.3` → index `sha256:ec721a5e4b0decb3658c74b696e315dc3e1c664adbfbadded0564ee2d6cc03bc`.

**Cost-bug axis (#27612) — fixed only at config level, not by any version (verified sound on 1.83.14):**

- Declare regional Bedrock models in `proxy_config.model_list` with explicit `input_cost_per_token` / `output_cost_per_token`. This routes through `_cost_per_token_custom_pricing_helper` (`custom_pricing=True`) and **bypasses the strip-and-autoprice path entirely** — the #27612 repro hinges on *not* entering manual prices.
- **#11975 does NOT apply to us:** the "custom pricing → $0" bug was a v1.72.0 issue requiring `router_model_id` plumbing; that fix is present in 1.83.x (regression test `test_custom_pricing_with_router_model_id`). Explicit per-token pricing IS respected on our version.
- AU regional values to use: `input_cost_per_token: 3.3e-6`, `output_cost_per_token: 1.65e-5`, `cache_creation_input_token_cost: 4.125e-6` (Sonnet 4.5 ap-southeast-2; confirm current Bedrock AU rates at apply-time).
- Also set `LITELLM_LOCAL_MODEL_COST_MAP=True` — pins the cost map, removes the GitHub-fetch nondeterminism that the floating tag exploited. Defence-in-depth, not a fix on its own (only explicit prices fix the strip).

## Open question for the investigation — RESOLVED (verify against live DB)

Our behaviour (stripped key → silent **zero** pricing) vs the #27612 reporter's (stripped key → **us-east-1** pricing) is **the same root bug, different stored fallback** — NOT a distinct second bug and NOT a version difference (the buggy path is byte-identical across 1.83.10/1.83.14):

- DB-stored models persist pricing into `model_info` at **add-time**, not via per-request live lookup.
- At the reporter's add-time the stripped key matched the bundled `anthropic.claude-...` entry → wrong-region price stored. At our add-time (post the 2026-05-12 `:main-stable` roll, which shifted cost-map contents/ordering) the stripped key matched **no** entry → `input_cost_per_token` stored as 0/null. Silent-$0 on unmapped keys is documented known behaviour (see model-cost-map incident report).

**Still to do on-site (confirm, don't re-derive):** query the stored model record(s) and a SpendLogs sample to confirm `input_cost_per_token`/`output_cost_per_token` are literally 0/null for the affected `au.` models (vs us-east-1 values) — this distinguishes our variant in the data and sizes the backfill. PR #27625 is irrelevant to remediation (unreleased).

## Issues to fetch and synthesise

**Primary:**
- [#27612 — UI strips regional inference profile prefix](https://github.com/BerriAI/litellm/issues/27612)
- [PR #27625 — fix: use regional inference profile id for model_cost lookup](https://github.com/BerriAI/litellm/pull/27625)

**Related cost map / cost calc bugs:**
- [#11975 — Custom pricing in model_info not applied for cost tracking](https://github.com/BerriAI/litellm/issues/11975) (open since June 2025)
- [#27191 — Cache token cost tracking bugs](https://github.com/BerriAI/litellm/issues/27191)
- [#22972 — Missing jp. region prefix for claude-sonnet-4-6](https://github.com/BerriAI/litellm/issues/22972)
- [#15764 — Bedrock pricing inflated 10%](https://github.com/BerriAI/litellm/issues/15764)
- [#8115 — Bedrock cross-region inference model not mapped](https://github.com/BerriAI/litellm/issues/8115) (open)
- [#6905 — Bedrock cross-region inference not working for APAC (ap-southeast-2)](https://github.com/BerriAI/litellm/issues/6905) (filed Nov 2024, our region)
- [#8911 — Application Inference profiles don't work](https://github.com/BerriAI/litellm/issues/8911)

**Architectural background:**
- [LiteLLM Model Cost Map Incident Report](https://docs.litellm.ai/blog/model-cost-map-incident) — their own writeup of the silent-fallback failure mode
- [LiteLLM Custom Pricing docs](https://docs.litellm.ai/docs/proxy/custom_pricing)
- [LiteLLM Cost Discrepancy Debugging Guide](https://docs.litellm.ai/docs/troubleshoot/cost_discrepancy)

**Supply chain context (justifies digest pinning):**
- [#24518 — PyPI compromise March 2026](https://github.com/BerriAI/litellm/issues/24518)

## Tasks

### 1. Investigate the variant

- Fetch #27612 and #27625 in full
- Compare bug reporter's symptoms (wrong-region pricing) vs ours (zero pricing)
- Identify cause of divergence: version, cost map state, or distinct bug
- Recommend a SQL query against our SpendLogs to distinguish hypotheses
- Determine whether PR #27625 fully addresses our variant

### 2. Investigate the suspected second `au.` prefix bug

Discovered during today's meeting that there appears to be a second bug related to `au.` prefix handling distinct from #27612. Need to:

- Identify what specifically was observed (request work-Claude to ask clarifying questions if needed)
- Search the LiteLLM repo for related open and closed issues
- Determine whether it's already filed or needs to be

### 3. Draft community contributions

- Comment for #27612 documenting our variant (zero pricing instead of wrong-region pricing), with anonymised data
- New issue (if applicable) for the second `au.` prefix bug
- Both should include: LiteLLM version, region (ap-southeast-2), affected model identifiers, scope of impact, SpendLogs sample anonymised

### 4. AWS billing investigation

Our AWS billing UI shows empty since May 1. Hypotheses:

- AWS credits masking gross spend in the UI (Cost Explorer should still show `UnblendedCost`)
- Marketplace billing routes Bedrock spend under "AWS Marketplace" rather than "Amazon Bedrock" (Anthropic is paid via marketplace, no direct AWS discount)
- Some configuration or permission issue with the billing console

Tasks:
- Query Cost Explorer API for 2026-05-01 to today
- Pull both "Amazon Bedrock" AND "AWS Marketplace" services separately
- Group by `USAGE_TYPE` for per-model breakdown
- Compare `UnblendedCost` vs `NetUnblendedCost` vs `AmortizedCost` to identify credit application
- Report which dimensions produce the per-model attribution needed for any future cost reconciliation work

### 5. Cached credentials pattern

We have observed multiple instances of LiteLLM caching configuration state in memory and not refreshing on config update:

- Cost map (today's incident — loaded at startup from bundled JSON)
- Bedrock API credentials (previous instance — rotating the key didn't take effect until pod restart)
- Secret-mounted env vars (general Kubernetes pattern, not LiteLLM-specific, but compounds)

Tasks:
- Identify how LiteLLM resolves Bedrock credentials (env vars, IAM role, boto3 session)
- Document conditions under which credential changes propagate vs require restart
- Recommend verification step for confirming credential propagation after rotation

### 6. Draft postmortem

Structure:
- Incident summary
- Timeline
- Scope (~6131 requests, `au.`-prefixed models, May 12 onwards)
- Root cause chain (floating tag → image roll → cost map state change → UI prefix stripping interacting with cost map → silent fallback to zero → no telemetry)
- Why hard to detect (silent fallback by design, no freshness alerting)
- Immediate fix (YAML override with correct AU pricing for affected models)
- Backfill (SQL UPDATE on SpendLogs from token counts × correct rates, rebuild DailyTeamSpend)
- Followups (digest pinning, admission policy on floating tags, freshness alerting, `LITELLM_LOCAL_MODEL_COST_MAP` for cost map under our version control)
- Open questions

### 7. Output format

- Postmortem draft (Markdown)
- Comment / issue body for upstream (#27612 and any new issue)
- SQL backfill query with safety wrapper (transaction, count-first SELECT, sample verification)
- YAML configmap snippet for model_list pricing overrides
- Validation steps for AWS Cost Explorer data shape (per-model breakdown, marketplace handling, credit application)

## Constraints

- LiteLLM version: **`v1.83.14-stable.patch.3`** (confirmed 2026-05-19; same build as homelab). Bug predates this and the entire CVE-clean line — see "Version posture (READ FIRST)". Capture the running image digest and pin it (kill the floating `:main-stable` tag — that nondeterministic roll is itself an ML2/ISM configuration-integrity finding).
- AWS region: ap-southeast-2 (Sydney)
- Compliance context: Essential Eight ML2/ML3, ISM — cost data needs to be audit-defensible
- Multi-provider: also routing some traffic through Azure OpenAI AU East (separate but related)
- Existing direct Bedrock callers outside LiteLLM: Sourcegraph (need to inventory others)
