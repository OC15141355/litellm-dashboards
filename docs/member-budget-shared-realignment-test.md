# Team-Member Budget — Shared-Row Realignment + Single-User Rollover Test

> Companion to [`member-budget-reset-repair.md`](member-budget-reset-repair.md). Use this when members were repaired
> with **individual** budget rows but you'd rather they **inherit the team's shared member budget** (same cap + same
> rollover as everyone else) — and you want to **empirically confirm the rollover behaviour** on your own user first.
> Deployment: `v1.83.14-stable.patch.3`, AWS RDS Postgres. Source-of-truth order: **live behaviour / source > docs.**

## Why this doc exists

The repair in the companion doc sets `budget_duration` + `budget_reset_at` on each broken member's **own**
`LiteLLM_BudgetTable` row (a sliding 30d window per member). If the rest of the team instead shares **one**
team-member budget row (pointed at by every healthy member's `LiteLLM_TeamMembership.budget_id`), the cleaner
end-state is to **repoint the broken members at that shared row** — then they inherit the shared cap and the shared
reset by construction, with nothing per-member to drift out of sync.

Two facts make this safe to reason about (both source-verified, see companion doc):
- A member's **spend** lives on `LiteLLM_TeamMembership.spend` (per member); the **cap + duration + reset date** live
  on the `LiteLLM_BudgetTable` row referenced by `budget_id`. Repointing `budget_id` changes the cap/reset a member
  is subject to **without touching their spend**.
- The reset job zeroes **every** membership whose `budget_id` is in the due set (`reset_budget_job.py:100-105`). So a
  shared budget row resets the **whole cohort** at once — which is the point here, but also the hazard the test avoids.

## How to run this with a Claude instance

Feed this whole file as context. Fill the two parameters below. **Do every read-only step first and paste the output
back before any write.** Writes are gated: snapshot the DB (RDS snapshot), run each write in a `BEGIN; … COMMIT;`
transaction, and **scope every statement to a single `user_id` / `team_id`** — never run an unscoped `UPDATE`/`DELETE`
on `LiteLLM_BudgetTable` or `LiteLLM_TeamMembership`.

```
TEAM_ALIAS  = 'ai_sandbox_team'
MY_USER_ID  = '<your own user_id>'        -- the test subject: has spend, not maxed
```

---

## Step 1 — Map the team's budget topology (READ-ONLY)

Determines whether the team uses a **shared** member budget row or **per-member** rows.

```sql
SELECT tm.budget_id,
       count(*)              AS members,
       b.max_budget,
       b.budget_duration,
       b.budget_reset_at,
       b.updated_by
FROM "LiteLLM_TeamMembership" tm
LEFT JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
GROUP BY tm.budget_id, b.max_budget, b.budget_duration, b.budget_reset_at, b.updated_by
ORDER BY members DESC;
```

Read it as:
- A row with **`members` > 1** and a real `budget_reset_at` = the **shared** team-member budget. Note its `budget_id`
  as `SHARED_BUDGET_ID`, and its `max_budget` (expected cap, e.g. 40).
- Rows with `members = 1` (often `updated_by = 'manual-budget-repair'`) = individual/repaired members.
- `budget_id = NULL` = members with no per-member budget (team cap only).

If there is **no** shared row (every member has their own `budget_id`), this realignment doesn't apply — stay with the
per-member repair in the companion doc.

## Step 2 — Inspect your own membership (READ-ONLY)

```sql
SELECT tm.user_id, tm.spend, tm.total_spend, tm.budget_id,
       b.max_budget, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_TeamMembership" tm
LEFT JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND tm.user_id = :MY_USER_ID;
```

Record your current `spend`, `total_spend`, and `budget_id` — you'll restore `budget_id` after the test.

---

## Step 3 — Rollover probe on your own user (REVERSIBLE)

This answers the open question: **when a member budget resets, does it re-arm to the 1st (calendar) or to
`run-time + duration` (sliding)?** It uses a **throwaway budget row** with a high cap, so it never touches the shared
row or blocks you, and is fully reversible.

> ⚠️ This **zeroes your `LiteLLM_TeamMembership.spend`** when the reset fires (that's the observable). `total_spend`
> and `SpendLogs`/Grafana are untouched. Step 3e restores your spend if you want it back.

**3a. Snapshot the RDS instance.** Then:

**3b. Create an isolated test budget** — high cap so it can't block you, `1mo` duration (the duration that
*discriminates* calendar vs sliding per #25432), reset date already due so the job fires it next tick:
```sql
INSERT INTO "LiteLLM_BudgetTable"
  (budget_id, max_budget, budget_duration, budget_reset_at, created_by, updated_by, created_at, updated_at)
VALUES
  ('rollover-test-' || :MY_USER_ID, 1000000, '1mo',
   (now() at time zone 'utc') - interval '1 minute',
   'rollover-test', 'rollover-test', now(), now());
```

**3c. Point your membership at the test budget** (save your real `budget_id` from Step 2 first):
```sql
UPDATE "LiteLLM_TeamMembership"
SET budget_id = 'rollover-test-' || :MY_USER_ID
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id = :MY_USER_ID;
```

**3d. Wait one scheduler tick (~10 min), then read the result:**
```sql
SELECT tm.spend, b.budget_duration, b.budget_reset_at
FROM "LiteLLM_TeamMembership" tm
JOIN "LiteLLM_BudgetTable" b ON b.budget_id = tm.budget_id
WHERE tm.user_id = :MY_USER_ID
  AND tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS);
```
**Verdict:**
- `spend = 0` → the job ran (confirms members DO reset in this build).
- `budget_reset_at` ≈ **`now + ~30 days`** → **sliding window** (legacy `duration_in_seconds`, #25432 present). Member
  budgets will **not** stay calendar-aligned; repointing to the shared row gives *parity* with the team (they drift
  together), not a fixed 1st.
- `budget_reset_at` = **1st of next month, 00:00 UTC** → calendar-aligned; re-pinning to the 1st would be permanent.

**3e. Restore (mandatory cleanup):**
```sql
-- put your membership back on its real budget (use the budget_id recorded in Step 2; use NULL if it was null)
UPDATE "LiteLLM_TeamMembership"
SET budget_id = :ORIGINAL_BUDGET_ID
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id = :MY_USER_ID;

-- (optional) restore your spend counter to its pre-test value recorded in Step 2
UPDATE "LiteLLM_TeamMembership"
SET spend = :ORIGINAL_SPEND
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id = :MY_USER_ID;

-- drop the throwaway budget
DELETE FROM "LiteLLM_BudgetTable" WHERE budget_id = 'rollover-test-' || :MY_USER_ID;
```
> If you restored `spend` by raw UPDATE, the enforcement gate still reads the cached counter for up to ~60s
> (in-memory TTL) — harmless here since you weren't near the cap. A pod restart clears it instantly if needed.

---

## Step 4 — The realignment fix (repoint broken members → shared row)

Once Step 3 confirms the model, repoint the repaired members at `SHARED_BUDGET_ID` so they inherit the shared cap +
reset. Confirm first that those members are *meant* to have the standard cap (not an intentional custom override).

```sql
BEGIN;
-- preview the members about to be repointed
SELECT tm.user_id, tm.spend, tm.budget_id
FROM "LiteLLM_TeamMembership" tm
WHERE tm.team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND tm.budget_id IN ( /* the repaired individual budget_ids from Step 1 */ );

UPDATE "LiteLLM_TeamMembership"
SET budget_id = :SHARED_BUDGET_ID
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND budget_id IN ( /* the repaired individual budget_ids */ );
-- verify, then:
COMMIT;
```

## Step 5 — Clear their stale spend (scoped, only if needed this month)

Repointing does **not** clear the carried spend. Their stale spend will clear automatically on the shared row's next
reset. If they need their allowance **now**, zero only those members' counters — **you cannot use the reset-job
trigger here**, because making the shared row due would reset the entire cohort (including healthy members' real
current spend).

```sql
UPDATE "LiteLLM_TeamMembership"
SET spend = 0   -- spend ONLY; never touch total_spend (lifetime)
WHERE team_id = (SELECT team_id FROM "LiteLLM_TeamTable" WHERE team_alias = :TEAM_ALIAS)
  AND user_id IN ( /* the broken members */ );
```
Gate picks up the `0` within ~60s (in-memory TTL) or instantly on a pod restart; the write is durable (write-back is
`spend = spend + delta`, never absolute, so it won't be clobbered); `SpendLogs`/Grafana untouched.

## Step 6 — Cleanup (optional)

The repaired individual budget rows are now orphaned:
```sql
DELETE FROM "LiteLLM_BudgetTable"
WHERE updated_by = 'manual-budget-repair'
  AND budget_id NOT IN (SELECT budget_id FROM "LiteLLM_TeamMembership" WHERE budget_id IS NOT NULL);
```

## Rollback

- Step 3 is self-restoring (3e) and uses a throwaway row — no lasting change.
- Step 4: re-`UPDATE` the affected memberships' `budget_id` back to their original per-member ids (preview output of
  Step 4 records them) — do this before Step 6, or you'll have deleted the rows to roll back to.
- RDS snapshot taken in 3a is the backstop for everything.

## Key facts (source-verified, v1.83.14)

- Member spend → `LiteLLM_TeamMembership.spend`; cap/duration/reset → `LiteLLM_BudgetTable` via `budget_id`.
- Reset job zeroes `spend` for **all** memberships on a due `budget_id` (`reset_budget_job.py:100-105`), clears the
  in-memory + Redis spend counters (`:79-94`), re-arms `budget_reset_at` (`:159, 797-814`); leaves `total_spend`.
- Scheduler is a per-pod APScheduler interval, **~10 min** (`constants.py:1438-1455`); selection is per budget row
  (`utils.py:2997-3011`). No `LiteLLM_CronJob` lease on this path.
- Members use the legacy sliding re-arm (`now + duration`), not calendar alignment — Step 3 confirms this live.
