# LiteLLM Cost Tracking Incident — Investigation Brief

## Context

Cost tracking for `au.`-prefixed Bedrock models (Australian regional inference profiles) showed `spend = 0` in `LiteLLM_SpendLogs` starting May 12, 2026. ~6131 affected requests over a week before detection (via Grafana cost panel flatlining). Service unaffected throughout. Token counts intact and recoverable.

Root cause is at least two interacting bugs:

1. **LiteLLM #27612** — UI-added Bedrock regional inference profile models have their region prefix stripped at DB storage time, causing wrong-region (or in our case, zero) pricing.
2. **Possible second `au.` prefix bug** — discovered during today's investigation, distinct from #27612. Needs scoping.

Cost map state shifted on May 12 when our LiteLLM image rolled via floating `:main-stable` tag, which is what made the latent UI bug visible.

## Version posture (READ FIRST — task-zero)

**We do not currently know our running version.** It is whatever `ghcr.io/berriai/litellm*:main-stable` resolved to when the image rolled on 2026-05-12. Determining it is the first action, because Tasks 1, 3 and 6 all depend on it:

```bash
# running version
curl -s https://<litellm-host>/health/readiness | jq .litellm_version
# running image digest (the authoritative identity behind the floating tag)
kubectl -n <ns> get pod -l <selector> -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'
```

**There is no release that is both CVE-clean and free of #27612.** This is load-bearing — do not chase a version that "fixes" the cost bug; none exists:

- Issue **#27612 was filed against v1.83.14**. The fix **PR #27625 is OPEN, unmerged, base `litellm_internal_staging`, review-required — present in NO released version** (verified via `gh pr view 27625`).
- Therefore a version bump does **not** resolve the cost-tracking incident. Treat the version axis and the cost-bug axis as orthogonal.

**CVE axis (independent of the cost bug):**

- Minimum-safe floor is **v1.83.10**; recommended pin **`v1.83.14-stable.patch.3`**.
- Closes CVE-2026-35030 (9.4 OIDC auth bypass), 35029, 42203, 42271, 40217, GHSA-69x8.
- LiteLLM does **not** backport security fixes to 1.81.x / 1.82.x — verified against GitHub Security Advisory `vulnerable_version_ranges` (single upper bound at the 1.83.x fix, no exclusions for older patch lines). The latest 1.82 stable patch post-dates the CVEs but contains zero security commits.
- **Pin by digest, not tag.** The floating `:main-stable` tag is the root of this incident chain; a digest pin both closes the CVEs and *freezes the cost-map state* so it cannot silently roll again. Verified-available digest:
  `ghcr.io/berriai/litellm-database:v1.83.14-stable.patch.3` → index `sha256:ec721a5e4b0decb3658c74b696e315dc3e1c664adbfbadded0564ee2d6cc03bc`.

**Cost-bug axis (#27612) — fixed only at config level, not by any version:**

- Declare regional Bedrock models in `proxy_config.model_list` with explicit `input_cost_per_token` / `output_cost_per_token` (bypasses the UI strip-and-autoprice path entirely — the #27612 repro hinges on *not* entering manual prices).
- And/or set `LITELLM_LOCAL_MODEL_COST_MAP` so the cost map is version-controlled and not loaded from a bundled JSON that shifts with the image.

## Open question for the investigation

Our LiteLLM version's behaviour for the stripped key (`anthropic.claude-sonnet-4-6` without `au.` prefix) is to silently fall back to zero pricing. The #27612 reporter's version falls back to US-region pricing instead. We need to identify whether this is:

- A version difference in how `completion_cost()` handles the stripped key
- An interaction with the May 12 cost map state change
- A distinct second bug

This matters because PR #27625 may or may not fully address our variant.

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

- LiteLLM version: **UNKNOWN — determine first** (see "Version posture (READ FIRST)" above). Running image rolled via floating `:main-stable` on 2026-05-12; capture both `.litellm_version` and the running image digest before any other task.
- AWS region: ap-southeast-2 (Sydney)
- Compliance context: Essential Eight ML2/ML3, ISM — cost data needs to be audit-defensible
- Multi-provider: also routing some traffic through Azure OpenAI AU East (separate but related)
- Existing direct Bedrock callers outside LiteLLM: Sourcegraph (need to inventory others)
