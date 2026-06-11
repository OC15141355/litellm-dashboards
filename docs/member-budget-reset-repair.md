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
- [**#25432**](https://github.com/BerriAI/litellm/issues/25432) — even once duration is set, team-member/end-user budgets use a **legacy sliding-window** reset (anniversary date), **not** calendar-month alignment like users/teams/keys. Relevant if you want resets on the 1st.
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

## How the reset job consumes the fix

LiteLLM's `reset_budget` job (driven by `proxy_budget_rescheduler_min/max_time`) only selects budget rows where
`budget_duration` is **non-null** AND `budget_reset_at < now`, sets `spend → 0`, then re-arms
`budget_reset_at = now + budget_duration`. With duration set but `budget_reset_at` null (today's broken state) the
row is never selected — fixing **both** columns re-enrolls the member into automatic resets. Single-writer via the
`LiteLLM_CronJob` lease, so no double-reset across replicas.
