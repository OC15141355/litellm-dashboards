# Cost optimisation — Claude on Bedrock via LiteLLM

Runbook for reducing spend without dropping quality. Levers are ordered by
risk-adjusted return: do the free/zero-risk ones first, instrument everything,
and treat every lever as unproven until the cost dashboards show the
before/after. Researched and verified against AWS/LiteLLM/Anthropic primary
sources 2026-07-31; re-verify pricing rows before building cost models — the
AWS pricing page is JS-rendered and stales easily.

**Standing rule: no lever ships without a verification gate.** Before/after in
the Grafana cost dashboards for spend; an eval-suite pass (task-level pass
rates, n≥10 per class) for quality. "Feels the same" is not a measurement.

---

## 0. Dates that will bite

- **Sonnet 5 intro pricing ends 2026-08-31**: $2/$10 per MTok → $3/$15. Spend
  will jump ~50% on Sept 1 with zero change in usage. Annotate the dashboards
  ahead of time so nobody investigates a phantom regression.

## 1. Free / zero-risk (do first)

### 1.1 Endpoint prefix — regional carries a flat 10% premium

Regional/CRIS endpoints (`us.anthropic.…`) cost **10% more** than global
(`global.anthropic.…`). If the LiteLLM `model` strings use a `us.` prefix and
there is no data-residency requirement pinning traffic to a region, switching
the prefix is ~10% off everything, zero quality impact.

Check: `grep -r 'us\.anthropic' config/` — if it hits, raise the residency
question with the platform owner before flipping.

### 1.2 Verify prompt caching is actually landing

Bedrock supports Anthropic prompt caching (`cachePoint` in Converse). LiteLLM
(≥ our v1.92.1 target) **auto-translates OpenAI-format `cache_control` markers
to Bedrock `cachePoint`** — clients using the Anthropic/OpenAI format need no
changes — and its cost tracking accounts for cache tiers.

Verify with a live probe, not config reading (silent-failure rule):
- Send two identical-prefix requests through the proxy; second response must
  show `cache_read_input_tokens > 0`. If it's 0, a silent invalidator is at
  work: timestamp/UUID interpolated into the system prompt, unsorted JSON
  serialisation, per-user tool sets, or a prefix below the model's minimum
  cacheable size.
- Cache minimums: Sonnet 4.6 = 1,024 tokens; Haiku 4.5 = 4,096; **Sonnet 5 is
  absent from AWS's caching table** — Anthropic documents 512–1,024; smoke-test
  before sizing anything on it.
- Economics: reads ~0.1×, 5-min writes 1.25× (break-even after 1 reuse),
  1-hour writes 2× (break-even after 2). Default to 5-min unless traffic is
  bursty with long gaps.

### 1.3 Fix the dashboard token math (under-reporting risk)

Bedrock's `inputTokens` **excludes** cached tokens. True prompt volume =
`inputTokens + cacheReadInputTokens + cacheWriteInputTokens`. If any Grafana
panel sums `inputTokens` alone, it under-reports and — worse — makes caching
look like traffic dropped. Audit the panels; v1.92.0 adds per-token-type
cache/reasoning cost breakdown in spend logs, which is exactly the data the
cost dashboard should surface post-upgrade.

## 2. Low-risk, high-leverage

### 2.1 Effort tuning on Sonnet 5 (quality-preserving by design)

Sonnet 5 supports the full effort ladder (`low`→`max`, default `high`), and
the cross-model mapping is favourable: **Sonnet 5 at `medium` ≈ Sonnet 4.6 at
`high`**. Routine workloads (summaries, classification-adjacent tasks, doc
generation) at `medium` or `low` cut thinking-token spend materially with
documented-equivalent quality. Sweep per route with the eval suite; don't
carry effort defaults across models untested.

### 2.2 Flex service tier for non-interactive traffic

Bedrock service tiers: Standard / **Flex (−50%)** / Priority (+75%). Flex
trades latency for half price — a fit for anything that isn't a human waiting
(report generation, nightly summarisation, eval runs). Evaluate per workload;
keep interactive chat on Standard.

## 3. Structural (instrument first, then commit)

### 3.1 Model tiering — Haiku 4.5 for the cheap tier

Haiku 4.5 ($1/$5) behind a LiteLLM model group for classification, extraction,
routing decisions, and short mechanical transforms; Sonnet 5 stays primary.
Two cautions from the evidence base:

- **LiteLLM `cost-based-routing` is NOT quality-aware tiering** — it picks the
  cheapest deployment for the same request. A real cascade (try cheap,
  escalate on failure) needs application-level logic or fallback chains keyed
  on failure conditions. Don't conflate them.
- **A cascade only saves money if the escalation rate stays low.** Two passes
  (Haiku then Sonnet) cost more than one Sonnet pass once escalation exceeds
  roughly a third of traffic. Instrument the candidate route's failure rate
  FIRST, then decide.

LiteLLM mechanics that support this: model groups + `tags` routing
(`enable_tag_filtering`, `x-litellm-tags` header, negation + regex supported),
fallback chains with cooldowns, per-key/team/user budgets (`max_budget` +
`budget_duration`, `tpm_limit`/`rpm_limit`). Note: $0-cost models bypass
budget checks by design.

### 3.2 Batch inference — Haiku-tier only, and it doesn't stack with caching

Bedrock batch (S3 JSONL → `CreateModelInvocationJob` → S3 out) is **50% off**,
but three hard constraints as of 2026-07:

- **Sonnet 5 is not in the batch-supported models table.** Batch is currently
  a Haiku 4.5 / Sonnet 4.6-and-older lever only.
- **No tool calling, no structured output** in batch.
- **Prompt caching is not supported with batch** — the two discounts never
  stack; model each workload with one or the other.

(The Anthropic first-party Batches API does not exist on Bedrock at all —
don't cargo-cult first-party docs here.)

### 3.3 LiteLLM response cache — narrow use only

LiteLLM's own response cache (Redis/s3/semantic) returns *stored responses*
for repeated requests. Safe for idempotent, deterministic reads; **unsafe**
for tool-calling or personalised traffic. Correctness trap: by default only
standard OpenAI params form the cache key — set
`enable_caching_on_provider_specific_optional_params: true` or requests
differing only in provider-specific params (e.g. effort) will collide.

## 4. Client-side workflow skills (developer opt-in, not proxy-enforceable)

Two community skills came up ("ponytail", "caveman"). Verdict from the only
independent paired benchmark (JetBrains SkillsBench, 80 paired tasks, Jul
2026):

- **Ponytail** (laziness-ladder before code generation: does this need to
  exist → stdlib → existing dep → minimum code): **−10.3% cost (p=0.004),
  −15.4% code, −11% time** — modest but real, the first skill whose cost
  delta survived a paired significance test. Worth installing in Claude Code
  for dev workflows. Note: the repo's own headline figures are much larger;
  use the independent numbers.
- **Caveman** (telegraphic output compression): advertised −65%, measured
  **−8.5%**, fragile after outlier exclusion, and it *adds* 1–1.5k input
  tokens per turn — can go net-negative on terse workloads. Skip.

These are per-developer client-side installs; the proxy can measure their
effect in spend logs but cannot enforce them.

## 5. What we deliberately don't do

- **Downgrade the primary model to save money.** Tiering routes *appropriate*
  work to Haiku; Sonnet 5 stays the default for anything requiring judgment.
- **Trust vendor cascade benchmarks.** The Haiku→Sonnet→Opus cascade blog
  numbers are unverified; the academic grounding (FrugalGPT, AutoMix, 2026
  cascade papers) supports the *pattern*, not any specific claimed saving.
- **Provisioned Throughput** until volume justifies a pricing conversation
  with the AWS account team (no published rate; incompatible with batch).

## Verification checklist (run after each lever)

- [ ] Grafana cost dashboard: before/after weekly spend for the affected
      model group, annotated with the change date
- [ ] `cache_read_input_tokens` present and non-zero where caching is claimed
- [ ] Token panels sum all three token types (input + cache read + cache write)
- [ ] Eval suite pass rates unchanged (or the delta consciously accepted)
- [ ] Escalation rate logged for any cascade route
