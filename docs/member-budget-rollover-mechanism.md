# Team-Member Budget Rollover — Mechanism + Single-User Test

> How team-member budget reset ("rollover") works in `v1.83.14-stable.patch.3`, and a reversible way to confirm it
> live on your own user. AWS RDS Postgres. Source-of-truth order: **live behaviour / source > docs.**

## Mechanism

- A member's **spend** is on `LiteLLM_TeamMembership.spend` (per member, per team). The **cap, duration, and reset
  date** are on the `LiteLLM_BudgetTable` row referenced by `LiteLLM_TeamMembership.budget_id` — not on the
  membership itself.
- The reset job (`ResetBudgetJob`) runs on a per-pod APScheduler interval, **~10 min** (`constants.py:1438-1455`,
  no override in our config). Each tick it selects budget rows where
  `(budget_reset_at IS NULL AND budget_duration IS NOT NULL) OR budget_reset_at < now` (`utils.py:2997-3011`).
- For each selected budget row it: zeroes `LiteLLM_TeamMembership.spend` for **every** membership pointing at that
  `budget_id` (`reset_budget_job.py:100-105`), clears the in-memory + Redis spend counters (`:79-94`), and re-arms
  `budget_reset_at` (`:159, 797-814`). `total_spend` (lifetime) is left untouched.
- Selection is **per budget row**: if N members share one `budget_id`, that row resets all N together; if each has
  its own row, they reset independently.
- The re-arm for member budgets uses the **legacy sliding window** (`now + duration`), not calendar alignment like
  teams/users/keys ([#25432](https://github.com/BerriAI/litellm/issues/25432)). The test below confirms this live.

## Single-user test

Confirms the mechanism on your own user without affecting any other member, using a throwaway high-cap budget so it
can't block you. Fully reversible.

```
TEAM_ALIAS  = 'ai_sandbox_team'
MY_USER_ID  = '<your own user_id>'
```

> ⚠️ When the reset fires it **zeroes your `LiteLLM_TeamMembership.spend`** (that's the observable). `total_spend`
> and `SpendLogs`/Grafana are untouched. Step 5 restores your spend.

**1. Record your current state (read-only):**
```sql
SELECT tm.spend, tm.total_spend, tm.budget_id,
       b.max_budget, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_TeamMembership" tm
LEFT JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND tm.user_id = :MY_USER_ID;
```
Note your `spend` and `budget_id` — you restore both at the end.

**2. Snapshot the RDS instance**, then create a throwaway test budget (high cap, `1mo` duration — the value that
discriminates calendar vs sliding — already due so the next tick fires it):
```sql
INSERT INTO "LiteLLM_BudgetTable"
  (budget_id, max_budget, budget_duration, budget_reset_at, created_by, updated_by, created_at, updated_at)
VALUES
  ('rollover-test-' || :MY_USER_ID, 1000000, '1mo',
   (now() at time zone 'utc') - interval '1 minute',
   'rollover-test', 'rollover-test', now(), now());
```

**3. Point your membership at the test budget:**
```sql
UPDATE "LiteLLM_TeamMembership"
SET budget_id = 'rollover-test-' || :MY_USER_ID
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id = :MY_USER_ID;
```

**4. Wait one tick (~10 min), then read the result:**
```sql
SELECT tm.spend, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_TeamMembership" tm
JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.user_id = :MY_USER_ID
  AND tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS);
```
Verdict:
- `spend = 0` → the job ran; members do reset in this build.
- `budget_reset_at` ≈ **now + ~30 days** → **sliding window** (legacy `duration_in_seconds`; #25432 present) — member
  budgets do not stay calendar-aligned.
- `budget_reset_at` = **1st of next month, 00:00 UTC** → calendar-aligned.

**5. Restore (mandatory):**
```sql
UPDATE "LiteLLM_TeamMembership"
SET budget_id = :ORIGINAL_BUDGET_ID,   -- from step 1; use NULL if it was null
    spend     = :ORIGINAL_SPEND        -- from step 1
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id = :MY_USER_ID;

DELETE FROM "LiteLLM_BudgetTable" WHERE budget_id = 'rollover-test-' || :MY_USER_ID;
```
> After restoring `spend` by raw UPDATE the enforcement gate keeps reading the cached counter for up to ~60s
> (in-memory TTL) — harmless here since you weren't near the cap; a pod restart clears it instantly.
