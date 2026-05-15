# Handoff note for work Claude — rename-user-id

Paste the block below into the work Claude Code session before it runs the rename. It corrects a load-bearing ordering bug in the original `rename-user-id.md` that breaks specifically on the work instance.

---

Heads up before you run this: the `rename-user-id.md` I have on file updates `LiteLLM_UserTable` first, then children. On the homelab that works because no user has org membership. On the work instance, `LiteLLM_OrganizationMembership` declares a real foreign key on `user_id` with no `ON UPDATE CASCADE`, so the parent-first UPDATE will abort the transaction with an FK violation. The whole `BEGIN…COMMIT` rolls back cleanly — no corruption — but the rename won't have happened either. Use this ordering instead, child tables first, parent last:

```sql
BEGIN;
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
UPDATE "LiteLLM_UserTable" SET user_id = 'correct-id' WHERE user_id = 'wrong-id';
COMMIT;
```

Also before you start:

- **(a)** RDS snapshot first.
- **(b)** Confirm `SELECT 1 FROM "LiteLLM_UserTable" WHERE user_id='correct-id'` returns zero rows.
- **(c)** `LiteLLM_SpendLogs` uses column **`"user"`** (quoted), not `user_id` — easy to miss.
- **(d)** `kubectl rollout restart deployment/litellm -n <ns>` after COMMIT to flush the in-memory user cache. Tokens remain valid throughout — no key re-issuance needed.

---

## Why this matters (background context, do not need to paste)

- The `BEGIN…COMMIT` wrapper makes the *old* doc safe to fail: if work-Claude runs parent-first, Postgres aborts on the FK and rolls back. No half-state, no corruption. Worst case is "the rename didn't happen, retry with the corrected order."
- There is no third "corrupted" outcome inside the transaction. The actual hazards live *outside* the transaction: missing the RDS snapshot, missing the pod restart (stale cache until TTL), missing that `SpendLogs."user"` is quoted.
- Canonical fixed doc lives at [`docs/rename-user-id.md`](rename-user-id.md) and has the correct ordering committed.
