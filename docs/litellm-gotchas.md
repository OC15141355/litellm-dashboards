# LiteLLM Gotchas & Playbook — `v1.83.14-stable.patch.3` (AWS Bedrock, ap-southeast-2)

> Hard-won, **verified** failure modes for our pinned LiteLLM + Bedrock `au.` setup. Each entry is rooted
> in source/live test, not just docs (docs were frequently silent on these). Companion to `../schema/SCHEMA-MAP.md`.
> Source of truth order: **live behaviour / source code > docs.**

## TL;DR table

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | New model (e.g. opus-4-8) logs **$0 spend** | `LITELLM_LOCAL_MODEL_COST_MAP=True` → boots on frozen bundled cost map that lacks models released after the image was cut | unset it (fresh GitHub fetch) **or** `LITELLM_MODEL_COST_MAP_URL=<vendored copy>` |
| 2 | `au.` model prices ~10% low (or $0) | `au.` regional prefix is **stripped** before cost-map lookup (#27612) → matches base (or nothing) | explicit `model_list` `model_info` AU prices (bypasses the strip) |
| 3 | Manual UI cost-map reload "fixes" it, then breaks again after restart | reload is **in-memory only**; restart reverts to the startup map | make the fix durable (#1) — don't rely on reload |
| 4 | "AWS vs LiteLLM token counts differ significantly" | someone compared `token_counter` (the **estimator**), which uses **tiktoken** for Claude (~8% off) | it's a pre-call estimate, **not the bill** — logged tokens = Bedrock's returned usage (note: `prompt_tokens` bundles cache → ≠ CloudWatch `InputTokenCount`; see #9) |
| 5 | User over budget despite raising their personal budget | team key **ignores user budget**; the binding cap is the **team-member budget** | set `max_budget_in_team` on that member |
| 6 | "Budget exceeded even after monthly reset" | team-member budget has **`budget_duration=null`** → never resets (lifetime cap) | set `budget_duration` (e.g. `30d`) on the member budget |
| 7 | Spend backfill from `SpendLogs` undercounts cached calls | `SpendLogs` has **no cache-token columns** (only prompt/completion/total) | recompute from `response`/`metadata` JSON, or use the persisted `spend` |
| 8 | Pod OOMKills on a version bump | 1.83.14 needs **>1Gi** at startup (cost-map/model load); 1.81.0 fit | raise mem limit to **2Gi** (actual steady ≈1Gi) |
| 9 | LiteLLM token counts ≠ CloudWatch `InputTokenCount` | LiteLLM **inflates** `prompt_tokens` = `inputTokens + cacheRead + cacheWrite`; CloudWatch `InputTokenCount` is **non-cache only** | like-for-like: `prompt_tokens ≈ Input + CacheRead + CacheWrite` (CloudWatch also counts non-LiteLLM callers) |
| 10 | **All** bedrock models log **$0** right after a version upgrade | model registered in **both** config `model_list` **and** the DB (`STORE_MODEL_IN_DB`); traffic routed to the **DB copy**, whose `model_info` cost fields were **null** (wiped by the migration *or* never set) and did **not** fall back to the healthy cost map | remove DB-persisted models (use config), set explicit `model_info` AU prices in config |

---

## Detail

### 1. Frozen cost map → silent $0 for new models  *(verified live)*
Default LiteLLM fetches the cost map (`model_prices_and_context_window.json`) from GitHub `main` at startup,
falling back to the bundled local copy (with integrity validation since the May-2026 incident).
`LITELLM_LOCAL_MODEL_COST_MAP=True` forces **bundled-only** — which is frozen at image-build time, so any model
released later is **absent → priced $0 silently** ("a missing entry never blocks a call").
- Proven: bundled map → opus-4-8 **MISSING → $0**; fresh fetch → opus-4-8 **$0.033/1k-1k** (AU). Homelab (no env)
  fetches fresh and prices it; work (`=True`) does not.
- **Fix:** `LITELLM_MODEL_COST_MAP_URL=<your hosted, refreshed-on-cadence copy>` (clean + deterministic), or just
  unset `LITELLM_LOCAL_MODEL_COST_MAP`. Env: `litellm/__init__.py` line ~371; loader `litellm_core_utils/get_model_cost_map.py`.

### 2. `au.` regional-prefix strip mis-prices  *(#27612, verified in source + cost map)*
`get_bedrock_base_model()`→`_strip_model_name()` strips `au.` before the cost-map lookup. The map has *both*
`au.anthropic.claude-…` (AU rate) and `anthropic.claude-…` (base rate ~10% lower); the strip makes it resolve to
**base** (or, if neither is present, **$0**). Unfixed in every release. **Only explicit `model_list` `model_info`
prices bypass it** (routes through the custom-pricing path). AU opus rates: `input 5.5e-6 / output 2.75e-5 /
cache_creation 6.875e-6 / cache_read 5.5e-7`.

### 3. The UI cost-map reload is ephemeral
Reloading the cost map in the UI pulls the fresh GitHub map **into memory** — fixes pricing until the pod
restarts (or `:main-stable` rolls), then it's gone. It's a hotfix, not the fix. See #1 for durable.

### 4. Token counting: estimator (tiktoken) ≠ logged spend  *(verified: source + live Bedrock call)*
Two different numbers. **Logged/billed** tokens come from Bedrock's returned `usage` (`converse_transformation.py`
→ `cost_calculator.py`) — the same tokens Bedrock bills (but bucketed differently than CloudWatch; see #9). **`litellm.token_counter`** (the `/count_tokens`
util) is a **pre-call estimate**; for Claude it falls back to **tiktoken (OpenAI's tokenizer)** — the wrong ruler,
~8% drift (measured: Bedrock 97 vs estimator 89 on a fixed prompt). The estimator **never touches spend**.
If AWS-side totals exceed LiteLLM's, suspect **callers outside LiteLLM** (e.g. Sourcegraph), not a count bug.

### 5–6. Budget precedence + non-resetting member budgets  *(verified live)*
For a key with a `team_id`, LiteLLM applies **team-level** budgets, **not** the user's personal `max_budget` —
raising the user budget does nothing. Per-person control inside a team = **`max_budget_in_team`** (stored per
member via `LiteLLM_TeamMembership.budget_id`); a per-member override beats the team-wide `team_member_budget`
default (tested: default $40, override $180 → 180 stuck). **Member budgets created via `team_member_budget` come
with `budget_duration=null` → they never reset** (lifetime cap) — set `budget_duration` explicitly. Design: for
many onboarding members, uncap the team total and govern with per-member budgets + overrides.

### 7. `SpendLogs` has no cache-token columns
Columns are `prompt_tokens`/`completion_tokens`/`total_tokens` only. The stored `spend` *is* cache-correct
(cost_calculator reads `cache_read`/`cache_creation` from usage), but a backfill recomputing from the flat
columns will **miss cache costs**. Use `spend` where valid, or parse cache tokens from `SpendLogs.response` JSON.

### 8. Version-bump memory regression
1.83.14 OOMKills at a 1Gi container limit (1.81.0 fit). Actual steady-state ≈1Gi → set limit **2Gi**, request 1Gi.

### 9. LiteLLM `prompt_tokens` inflates with cache — won't match CloudWatch `InputTokenCount`  *(verified in source + AWS docs)*
`converse_transformation.py` sets `prompt_tokens = inputTokens + cacheReadInputTokens + cacheWriteInputTokens`
(it captures `raw_input_tokens` *"before inflation"*). CloudWatch `InputTokenCount` is **non-cache only** — cache
read/write are **separate, additive** metrics (AWS TPM formula: `Input + CacheWrite×1.25 + CacheRead×0.1 + Output`).
So `prompt_tokens` vs `InputTokenCount` alone shows LiteLLM **higher by the cache amount** — a bucketing difference,
not a count error. Correct comparison: `prompt_tokens ≈ Input + CacheRead + CacheWrite`. CloudWatch also aggregates
the whole account (incl. non-LiteLLM callers), so it can be higher in aggregate too. Full reconciliation method:
`cloudwatch-litellm-token-reconciliation-prompt.md`.

### 10. Dual config+DB model registration → upgrade migration blanks pricing → $0  *(verified live, cost real money)*
**Symptom:** immediately after upgrading the proxy (drifted version → `v1.83.14-stable.patch.3`), **every** bedrock model logged **$0 spend** — from the upgrade boot (incident anchor: `02:41 UTC 2026-05-11`) until a manual UI cost-map reload. A model *added after* the upgrade (opus-4-8) priced **fine** — that's the tell.
**Root cause:** models were registered **twice** — config `model_list` *and* persisted in the DB (`STORE_MODEL_IN_DB=True`, `LiteLLM_ProxyModelTable`). Traffic routed through the **DB copies**, whose `model_info` cost fields resolved **null** (wiped by the upgrade migration **or** never set — moot, the DB-model path is the cause) → priced $0 instead of falling back to the otherwise-healthy cost map. The config models priced correctly but **weren't in the request path.**
**Why every "map" suspect was innocent (each ruled out with evidence — don't re-chase these):**
- *Missing model:* opus-4-8 (the only model absent from the bundle) was **never** it — added later, priced fine.
- *Stale `_backup.json`:* the bundled backup prices existing bedrock fine (sonnet `3.3`, haiku `1.1`) — a fallback would **not** zero them.
- *Broken remote:* git history — at the incident instant, live `main` HEAD was a 3-day-stable, bedrock-clean commit (`f2e9738`, May 8; next change ~13h *later*).
- *`au.` strip:* `au.` keys resolve to the correct AU rate when present (`3.3`, not base `3.0`).
  → all three map sources priced bedrock correctly, so **the $0 was never the cost map** — it was downstream DB pricing.
**Why the "reload" seemed to fix it:** the UI cost-map reload re-syncs `model_info` into the in-memory DB-model objects. Ephemeral relief; the **durable fix is removing the DB models**, not the reload.
**Why opus was fine:** added *after* the upgrade → captured correct pricing at add-time → never had blanked `model_info`.
**Fix:** drop the DB-persisted models (rely on config `model_list`), and set **explicit `model_info` AU prices** in config (opus `5.5e-6/2.75e-5`, sonnet `3.3e-6/1.65e-5`, haiku `1.1e-6/5.5e-6`) → pricing is then immune to **both** cost-map blips and DB-migration wipes.
**Detect / backfill:** `$0` on `status='success'` bedrock rows; check `LiteLLM_ProxyModelTable.model_info->>'input_cost_per_token'` for null/0. The $0 `SpendLogs` rows bound the window (`02:41 UTC 2026-05-11` → reload timestamp).
**First cut for ANY "$0 spend" symptom — do this before reading a single GitHub issue:** `$0` is overloaded — missing model, stale bundle, broken remote, the `au.` strip (#1/#2), *and* this DB-model path all produce an identical `spend=0` row, and the public issues mostly describe the *other* causes (they will walk you the wrong way — they did here for a week). **Bisect first:** is pricing coming from **DB `model_info`** or the **cost map**? One look at `LiteLLM_ProxyModelTable.model_info` eliminates half the search space and tells you which half of this doc to read.

## Posture notes
- **Pinning trade-off:** pinning the image for CVE/stability **also freezes the bundled cost map** → #1. Decouple them
  via `LITELLM_MODEL_COST_MAP_URL` (controlled fresh map) so the pin protects the binary, not the prices.
- **CVE watch:** `GHSA-4xpc` (critical, Host-header auth bypass, fixed ≥1.84.0) — our 1.83.14 is in-range but
  mitigated by host-validating edge (ALB/WAF). No `-stable` build ≥1.84.0 exists yet; re-check on each review.
