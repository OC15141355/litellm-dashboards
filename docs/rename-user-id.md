# Renaming a LiteLLM user_id in PostgreSQL

LiteLLM does not support changing `user_id` through the UI or API. This procedure renames a `user_id` directly in PostgreSQL while preserving keys, email, team membership, and spend history.

Tested on LiteLLM v1.81.14 (homelab) — no downtime, no key disruption.

## Prerequisites

- Direct PostgreSQL access to the LiteLLM database
- kubectl access to restart the LiteLLM pod (optional, clears cache)

## Step 1 — Audit References

Check all tables that reference the user_id before making changes:

```sql
SELECT 'UserTable' AS tbl, count(*) FROM "LiteLLM_UserTable" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'VerificationToken', count(*) FROM "LiteLLM_VerificationToken" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'DailyUserSpend', count(*) FROM "LiteLLM_DailyUserSpend" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'InvitationLink', count(*) FROM "LiteLLM_InvitationLink" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'DeletedVerificationToken', count(*) FROM "LiteLLM_DeletedVerificationToken" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'TeamMembership', count(*) FROM "LiteLLM_TeamMembership" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'OrganizationMembership', count(*) FROM "LiteLLM_OrganizationMembership" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'UserNotifications', count(*) FROM "LiteLLM_UserNotifications" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'EndUserTable', count(*) FROM "LiteLLM_EndUserTable" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'ManagedVectorStores', count(*) FROM "LiteLLM_ManagedVectorStoresTable" WHERE user_id = 'wrong-id'
UNION ALL
SELECT 'SpendLogs', count(*) FROM "LiteLLM_SpendLogs" WHERE "user" = 'wrong-id';
```

## Step 2 — Run the Rename

Execute as a single transaction:

```sql
BEGIN;

UPDATE "LiteLLM_UserTable" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_VerificationToken" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_DailyUserSpend" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_InvitationLink" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_DeletedVerificationToken" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_TeamMembership" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_OrganizationMembership" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_UserNotifications" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_EndUserTable" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_ManagedVectorStoresTable" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
UPDATE "LiteLLM_SpendLogs" SET "user" = 'correct-id' WHERE "user" = 'wrong-id';

COMMIT;
```

## Step 3 — Verify

```sql
-- Confirm new user_id exists with correct email
SELECT user_id, user_email FROM "LiteLLM_UserTable" WHERE user_id = 'correct-id';

-- Confirm keys are still attached
SELECT count(*) FROM "LiteLLM_VerificationToken" WHERE user_id = 'correct-id';

-- Confirm old user_id is gone
SELECT count(*) FROM "LiteLLM_UserTable" WHERE user_id = 'wrong-id';
```

## Step 4 — Restart Pod (When Convenient)

```bash
kubectl rollout restart deployment/litellm -n <namespace>
```

This clears LiteLLM's in-memory key/user cache. API keys continue to work immediately after the SQL change — the restart just ensures the cache is consistent.

## Notes

- `LiteLLM_SpendLogs` uses column `"user"`, not `user_id`
- `LiteLLM_VerificationTokenView` is a view — it updates automatically from the underlying table
- API keys, email, team membership, and spend history are all preserved
- Users will not notice the change unless they check the LiteLLM UI
- To discover all tables with a `user_id` column on your version, run:

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE column_name = 'user_id'
  AND table_schema = 'public'
ORDER BY table_name;
```
