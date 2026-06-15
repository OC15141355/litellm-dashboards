# Team-Member Budget Reset Repair — `budget_duration=null` never resets

> Runbook for the recurring case where team-member budgets (e.g. `ai_sandbox_team` $40 caps) have **no reset
> date** and never roll over. Expands [gotcha #6](litellm-gotchas.md) for `v1.83.14-stable.patch.3`.
> Source-of-truth order: **live behaviour / source > docs.** Companion: [`../schema/SCHEMA-MAP.md`](../schema/SCHEMA-MAP.md).

## TL;DR

| | |
|---|---|
| **Symptom** | Some members in a team have **no Budget Reset date** (`budget_reset_at` null); their spend never resets. |
| **Root cause** | Their per-member budget row has **`budget_duration = null`** → LiteLLM never computes a `budget_reset_at` → the `reset_budget` job (filters `budget_reset_at < now`) never picks the row up. Lifetime cap, not a recurring one. |
| **Why UI/API fixes fail** | `/team/member_update` (what the UI calls) **does not accept `budget_duration`** — upstream [#25509](https://github.com/BerriAI/litellm/issues/25509), fix PR #25560 **still unmerged**. Team-level budget changes **don't cascade** to existing members. |
| **Why remove+re-add "works"** | `member_delete` drops the `LiteLLM_TeamMembership` row (**wipes `spend` → free $$**); `member_add` reseeds a fresh budget from the team default. Don't use it as the fix. |
| **Correct fix** | **Targeted SQL** on `LiteLLM_BudgetTable` (sets `budget_duration` + `budget_reset_at`). Touches only the budget row, **not** `TeamMembership.spend` → spend preserved. |

## Data model (why the SQL is safe)

A team-member budget is **not** stored on the membership — it's a row in `LiteLLM_BudgetTable`, pointed to by
`LiteLLM_TeamMembership.budget_id` (FK `ON DELETE SET NULL`).

| Field | Lives on | Touched by fix? |
|---|---|---|
| `max_budget`, `budget_duration`, `budget_reset_at` | `LiteLLM_BudgetTable` | **yes** (duration + reset only) |
| `spend`, `total_spend` | `LiteLLM_TeamMembership` | **no** → spend preserved |

Members with `tm.budget_id IS NULL` have **no** per-member budget row at all (only the team cap applies) — the
SQL below won't touch them; they'd need a budget row *created* (also SQL, since the API can't set duration).

## Upstream bugs (verified, current as of 2026-06)

- [**#25509**](https://github.com/BerriAI/litellm/issues/25509) — `/team/member_update` can't set `budget_duration`; budgets it creates are always `null`. Fix PR #25560 **open/unmerged** → our 1.83.14 is affected. *This is why editing the member budget in the UI can never populate a reset date.*
- [**#25432**](https://github.com/BerriAI/litellm/issues/25432) — team-member resets **do fire** in 1.83.14 (verified in source — see "How the reset job works" below; the "members never reset" claim does *not* apply to us), but they use a **legacy sliding-window** reset (anniversary date), **not** calendar-month alignment like users/teams/keys. So a `30d`/`1mo` member budget rolls 30 days from its last reset, not on the 1st. Relevant only if you want resets on a calendar boundary.
- [**#11636**](https://github.com/BerriAI/litellm/issues/11636) — UI budget reset misbehaves when team default budgets are present.

## Procedure

> Prod RDS. **Snapshot first, run inside a transaction, preview before commit.**

### 1. Identify affected members (read-only)

```sql
-- Smoking gun: per-member budgets with null duration/reset but real spend
SELECT tm.user_id, tm.spend AS member_spend,
       b.budget_id, b.max_budget, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_TeamMembership" tm
LEFT JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = 'ai_sandbox_team')
ORDER BY b.budget_reset_at NULLS FIRST;
```

Affected = `budget_duration IS NULL AND budget_reset_at IS NULL` (typically `max_budget = 40`, `member_spend > 0`).

### 2. Repair (preserves spend)

```sql
BEGIN;

-- Preview exactly what will change — eyeball before committing
SELECT b.budget_id, tm.user_id, tm.spend, b.max_budget, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_BudgetTable" b
JOIN "LiteLLM_TeamMembership" tm ON tm.budget_id = b.budget_id
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias='ai_sandbox_team')
  AND b.budget_duration IS NULL;

UPDATE "LiteLLM_BudgetTable" b
SET budget_duration = '30d',
    budget_reset_at = (now() at time zone 'utc') + interval '30 days',
    updated_at = now(),
    updated_by = 'manual-budget-repair'
WHERE b.budget_id IN (
    SELECT tm.budget_id FROM "LiteLLM_TeamMembership" tm
    JOIN "LiteLLM_TeamTable" t ON t.team_id = tm.team_id
    WHERE t.team_alias = 'ai_sandbox_team' AND tm.budget_id IS NOT NULL
)
AND b.budget_duration IS NULL;   -- guard: only the broken rows

-- Re-run the preview SELECT to confirm; spend unchanged. Then:
COMMIT;   -- or ROLLBACK; if anything looks off
```

Notes:
- `budget_reset_at` is stored as **UTC** `timestamp` → `now() at time zone 'utc'`.
- `'30d'` = sliding 30-day window (matches `admin-scripts/set-team-key-budgets.sh`). For reset on the **1st of the month**, set `budget_reset_at` to the next 1st manually — `'1mo'` won't calendar-align for members ([#25432](https://github.com/BerriAI/litellm/issues/25432)).
- Data-only (no schema change) → safe to run independently of any pending Terraform apply. Snapshot anyway.

### 3. Stop the recurrence

Set the team's **default** member-budget duration so *new* members inherit a reset date automatically:

```bash
curl -sk -X POST "$LITELLM_API_BASE/team/update" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"team_id":"<AI_SANDBOX_TEAM_ID>","team_member_budget_duration":"30d"}'
```

(The default seeds budgets at `member_add` time — that path *does* populate duration, unlike `member_update`.)

## How the reset job works (source-verified, v1.83.14)

`ResetBudgetJob` selects budget rows where `(budget_reset_at IS NULL AND budget_duration IS NOT NULL) OR
budget_reset_at < now` (`utils.py:2997-3011`), then for each match:
- **zeroes `LiteLLM_TeamMembership.spend`** for every membership pointing at that budget — `update_many(where={"budget_id": {"in": ...}}, data={"spend": 0})` (`reset_budget_job.py:100-105`). `total_spend` is **not** touched (lifetime preserved).
- **clears the enforcement counters** — in-memory *and* Redis — for `spend:team_member:{user_id}:{team_id}` (`reset_budget_job.py:79-94`). This is the part raw SQL can't do; it's why the gate sees the reset immediately.
- **re-arms** `budget_reset_at = now + budget_duration` on the budget row (`reset_budget_job.py:159, 797-814`).

With duration set but `budget_reset_at` null (the broken state), nothing zeroes the row's spend on its own until
the next tick — fixing **both** columns re-enrolls the member into automatic resets.

**Scheduling — NOT a CronJob lease.** It's a per-pod APScheduler interval job (`proxy_server.py:6429`), cadence
`proxy_budget_rescheduler_min_time + rand(0, min(30, max-min))` — defaults **~597–605s, i.e. every ~10 min**
(`constants.py:1438-1455`); no override in our config/values. Selection is strictly **per budget row**, so making
one member's `budget_reset_at` due resets only that member. With `replicas: 1` there's no contention; if we ever
scale >1, each pod would run it independently (the resets are idempotent `set spend=0`, so harmless, but not
lease-gated — there is no `LiteLLM_CronJob` lease on this path).

## Clearing leftover spend after a repair (A vs B)

When the repair sets `budget_reset_at = now + 30d`, the member keeps **last period's spend** that never rolled
over — eating into this month's allowance. To give them a clean slate now, two options:

| | (A) raw `UPDATE TeamMembership SET spend = 0` | (B) trigger the reset job — **preferred** |
|---|---|---|
| DB durability | ✅ durable — write-back is `spend = spend + delta` (`db_spend_update_writer.py:1301-1306`), so a manual `0` is **not** clobbered, only incremented from | ✅ |
| Enforcement gate | gate reads cached `spend:team_member:…` (`auth_checks.py:3319`); your `0` reaches it only on cold-miss — **≤60s** in-memory TTL (`proxy_server.py:1599`), or a pod restart | instant — job clears the counter |
| Re-arm reset date | left as-is (next reset still fires) | re-armed to `now + 30d` automatically |
| `total_spend` / Grafana (`SpendLogs`) | untouched ✅ (must zero `spend` **only**, not `total_spend`) | untouched ✅ |
| Redis-safe | ❌ raw DB write is invisible to a Redis-backed counter (no short TTL) → would need restart / Redis flush | ✅ job explicitly clears Redis (`reset_budget_job.py:83-94`) |

> If the team uses **one shared** member-budget row (every healthy member's `budget_id` points at it) rather than
> per-member rows, the cleaner end-state is to **repoint** the broken members at that shared row so they inherit the
> team's cap + rollover — and there (A) is the right tool, since a job-trigger would reset the whole shared cohort.
> See [`member-budget-shared-realignment-test.md`](member-budget-shared-realignment-test.md), which also includes a
> reversible single-user rollover probe to confirm sliding-vs-calendar behaviour live.

**Use (B)** *for the per-member-row case*. It is correct regardless of Redis, has no enforcement-lag window, and re-arms in one step. To trigger,
make only the already-repaired rows due and let the next ~10-min tick fire:

```sql
BEGIN;
-- Preview: should be exactly the members repaired above (eyeball user_ids + that spend is stale last-period)
SELECT b.budget_id, tm.user_id, tm.spend, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_BudgetTable" b
JOIN "LiteLLM_TeamMembership" tm ON tm.budget_id = b.budget_id
WHERE b.updated_by = 'manual-budget-repair'
  AND tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias='ai_sandbox_team');

UPDATE "LiteLLM_BudgetTable"
SET budget_reset_at = (now() at time zone 'utc') - interval '1 minute'
WHERE updated_by = 'manual-budget-repair'
  AND budget_id IN (
    SELECT tm.budget_id FROM "LiteLLM_TeamMembership" tm
    JOIN "LiteLLM_TeamTable" t ON t.team_id = tm.team_id
    WHERE t.team_alias='ai_sandbox_team' AND tm.budget_id IS NOT NULL
  );
COMMIT;
```

Within ~10 min the job zeroes `spend`, clears the counter, and re-arms `budget_reset_at` to `now + 30d`. Verify
with the section-1 SELECT (`spend = 0`, `total_spend` unchanged, reset date ~30d out). No need to wait for midnight
UTC — the job is interval-based, not a daily cron. Scope by `updated_by = 'manual-budget-repair'` so you **don't**
reset members who were never broken and have legitimate current-period spend.
