# LiteLLM upgrade runbook — `1.83.14-stable.patch.3` → `1.93.0`

**Audience:** the dev running `terraform apply` on the work deployment (Helm release via Terraform, AWS Bedrock + Azure AI Foundry, RDS PostgreSQL, `ap-southeast-2`).
**Researched / verified:** 2026-07-28. **Re-verify before running** — see [§0](#0-re-verify-first-litellm-ships-weekly).

---

## Why we're doing this (the short version)

1. **We're forced.** `1.83.14-stable.patch.3` is the **last `-stable` release LiteLLM ever cut**. The stable track is dead — there is no newer `-stable`, and no backports are coming to this line.
2. **We have a live critical CVE.** [CVE-2026-49468](https://github.com/advisories/GHSA-4xpc-pv4p-pm3w) — unauthenticated **authentication bypass via Host header injection**. Fixed in **1.84.0**. We are below that. There is no patch for our line.
3. **Only the current stable line gets fixes.** Per LiteLLM's [release cycle policy](https://docs.litellm.ai/docs/proxy/release_cycle), patches land on the *current* stable release only. So the target must be the newest stable, not the smallest hop — anything else strands us again.

### Why `1.93.0` specifically

| Option | Verdict |
|---|---|
| Stay on `1.83.14` | Not viable — live unauthenticated auth bypass, no patch path |
| `1.84.10` (minimum that clears the CVE) | Rejected — pays the same breaking-change toll (see below) but lands on a **dead line**, so we'd repeat this exercise at the next CVE |
| **`1.93.0`** | **Chosen** — newest stable, ~10 days soaked, on the supported line |
| `1.94.0` | Rejected for *this* window — carries its own breaking change ([PR #32005](https://github.com/BerriAI/litellm/pull/32005), see [§6](#6-known-traps-we-are-deliberately-avoiding)) |

### The jump is smaller than the version numbers suggest

Version numbers accelerated after 1.84.0 (weekly MINOR bumps). Measured in actual commits:

| Leg | Commits |
|---|---|
| `1.81.9-stable → 1.83.14-stable.patch.3` — **the upgrade we already shipped** | **6,166** |
| `1.83.14.patch.3 → 1.84.0` — the one breaking boundary | 312 |
| `1.84.0 → 1.93.0` — feature churn, **zero breaking markers** | 2,494 |
| **This upgrade, total** | **~2,806** |

So this is **45% the size of the upgrade we already survived.** All 60 stable releases between 1.84.0 and 1.93.0 were scanned for breaking-change markers: exactly two exist — 1.84.0's, and 1.93.0's MCP `oauth2_flow` change (inert for us, we run no MCP servers).

---

## 0. Re-verify first — LiteLLM ships weekly

This doc was accurate on 2026-07-28. **No WebSearch needed** — fetch these URLs directly:

| Question | Fetch this |
|---|---|
| What is the newest stable? | `https://pypi.org/pypi/litellm/json` → `.info.version` |
| Anything released since? | `https://github.com/BerriAI/litellm/releases.atom` |
| Any advisory against our target? | `https://api.deps.dev/v3alpha/systems/pypi/packages/litellm/versions/1.93.0` → `advisoryKeys` must be `[]` |
| Full advisory list | `https://github.com/advisories?query=litellm` |
| Chart versions published | `https://github.com/orgs/berriai/packages/container/litellm-helm/versions` |
| Release notes index | `https://docs.litellm.ai/release_notes/` |

**If `1.94.0` has promoted to stable by the time you read this:** it is a valid target **only** if you also set `skip_user_budget_on_team_key: true` — see [§6](#6-known-traps-we-are-deliberately-avoiding). Otherwise stay on 1.93.0.

---

## 1. The version change

In `variables.tfvars`:

```hcl
litellm_chart_version = "1.93.0"    # NO "v" prefix — the chart rejects it
image_tag             = "v1.93.0"   # "v" optional here; verified identical digest
```

**The asymmetry is deliberate and it is a real trap.** Both the chart and the image switched away from the `-stable.patch.N` naming, but they take different forms:

- Helm chart: **bare only**. `helm show chart oci://ghcr.io/berriai/litellm-helm --version v1.93.0` → `not found`.
- Image: **either works**, same digest. Verified against GHCR:
  ```
  ghcr.io/berriai/litellm-database:1.93.0   →  sha256:72360d8bd5602faa49be5098a8ac3dd069d9fb74503d6bd014242d96dc753e43
  ghcr.io/berriai/litellm-database:v1.93.0  →  sha256:72360d8bd5602faa49be5098a8ac3dd069d9fb74503d6bd014242d96dc753e43
  ```
  Pin that digest.

Keep `repository: ghcr.io/berriai/litellm-database` (the `-database` variant, which bundles Prisma migrations).

**Optional, recommended for a gov gateway** — images are cosign-signed:
```bash
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  ghcr.io/berriai/litellm-database:v1.93.0
```
(The key is pinned to a commit hash, which is immutable — stronger than pinning to a tag.)

---

## 2. Two config changes that are easy to miss

### 2a. `migrationJob.enabled` MUST be `true` for this deploy

Ours is currently `false`. That is correct for a **same-version redeploy** — but this is a **version bump with schema changes**. Left `false`, the new image boots against the old schema. It does not fail cleanly; you get missing-column errors at runtime.

```yaml
migrationJob:
  enabled: true      # set back to false after this deploy completes
```

**Do NOT add `--use_v2_migration_resolver`.** Older notes of ours say to. It is obsolete at 1.93.0 — verified in `migrations/run.py:47` at the `v1.93.0` tag, the migration entrypoint already defaults to the v2 resolver:

```python
use_v2 = str_to_bool(os.getenv("USE_V2_MIGRATION_RESOLVER", "true"))
```

The v2 resolver is what avoids the v1 "diff-and-force" schema thrashing during rolling deploys, and you get it for free. To opt *back* into v1 you would set env `USE_V2_MIGRATION_RESOLVER=false` — don't.

> ⚠️ **Trap:** do not try to add proxy flags via the chart's top-level `args:` value. It **replaces** the container args rather than appending, and the default is `["--config", "/etc/litellm/config.yaml"]`. Setting `args` without repeating those two entries silently strips the proxy's config path.

**Schema delta** (validated in a Docker rehearsal on a copy of the real DB — non-destructive, purely additive):
- 1.84.0 adds `LiteLLM_WorkflowRun`, `LiteLLM_WorkflowEvent`, `LiteLLM_WorkflowMessage`, plus `search_tools` on `LiteLLM_ObjectPermissionTable`
- 1.93.0 adds `oauth2_flow` and `dcr_bridge` columns on the MCP server rows, with a startup backfill stamping legacy nulls
- Net: 62 → 66 tables

### 2b. `LITELLM_SALT_KEY` is not set — fix it in this window

Per the [security & encryption FAQ](https://docs.litellm.ai/docs/proxy/security_encryption_faq), `LITELLM_SALT_KEY` encrypts credentials stored in the DB (model `litellm_params`, credentials, DB-stored env vars) and **falls back to the master key when unset**. Right now our master key *is* our encryption key, which means a master-key rotation would render any DB-stored credential undecryptable.

**Why now:** we run `store_model_in_db: true` but have **no DB-stored models** — everything is code config. Nothing is encrypted yet, so setting a salt key costs nothing. The [docs](https://docs.litellm.ai/docs/proxy/master_key_rotations) are explicit that changing it *after* credentials exist makes them unreadable. The first time anyone adds a model through the UI, this becomes permanent.

Set a long random value, store it alongside the master key, **never change it**.

> Open question for the team: if models are code-config-only by policy, does `store_model_in_db` need to be `true` at all? Setting it `false` removes this entire class of encrypted-credential risk, at the cost of UI model management.

---

## 3. The 1.84.0 breaking-change checklist — already run, all clear

1.84.0 is the only boundary that touches us. Every item below was checked against our config. **Recorded here so it can be re-run, not because anything needs changing.**

| 1.84.0 breaking change | Our status |
|---|---|
| `pass_through_endpoints` default flipped to `auth: true` — public ones need explicit `auth: false` | ✅ We define none |
| Clientside `api_base`/`base_url` gated; blocklist expanded to AWS + Azure endpoints | ✅ Our `aws_bedrock_runtime_endpoint` (`os.environ/BEDROCK_ENDPOINT`) and Foundry `api_base` (`os.environ/FOUNDARY_AI_SERVICES_ENDPOINT`) are **server-side in config** — which is exactly what the change now requires. It blocks *client* overrides. |
| `os.environ/*` no longer resolved from **key/team callback metadata** | ✅ All our `os.environ/` uses are in `general_settings` and `model_list[*].litellm_params` — both still fully supported |
| Master-key requests return the alias `litellm_proxy_master_key` instead of a SHA-256 hash — breaks spend-log filters **and Prometheus queries** | ✅ Inert. PG dashboard panels filter via a `LiteLLM_VerificationToken` subquery (master-key rows were never in that table), and Prometheus panels key on `api_key_alias`, not the hash. |
| `mock_response` / `mock_tool_calls` stripped from client requests unless `allow_client_mock_response: true` | ✅ Not used |
| Team self-join limited to `role="user"`; `/team/permissions_update` now admin-only | ✅ Our admin scripts run as master key |
| Invite flow: `GET /onboarding/get_token` no longer mints an `sk-` key; clients must `POST /onboarding/claim_token` | ⚠️ Our scripts use `/user/new` + `/key/generate` + `/team/member_add`, so **unaffected** — but the **UI invite flow changed**. Relevant if admins are onboarded that way. |
| `/ui/chat` route removed (404s) | ⚠️ Cosmetic — warn any admin who bookmarked it |
| 1.83.10 caller-tag strip **reverted** — caller tags flow into `metadata.tags` again and union with admin tags | ⚠️ No dashboard depends on `request_tags` today. Note it before building User-Agent based tool attribution. |
| Vector store credential redaction + per-store authz | ✅ Not used |

**Also new in 1.84.0 and worth knowing:** `/health/readiness` now reports DB status **without authentication**. Add an ingress/WAF rule restricting it.

### Security fixes we gain in 1.93.0 (not backported to older lines)

- **Bearer-prefixed API keys are now hashed in spend logs** — previously they could be stored raw in the table our dashboards read
- Guardrail response credentials masked before persistence
- Hardened secret-name validation for external secret managers
- Passthrough routes: request params no longer clobber merged target query params

---

## 4. Pre-cutover data capture (do this on the work DB)

We hand-tuned team and user budgets directly in the database. Those rows live in **Prisma-managed** `LiteLLM_*` tables, so capture them as data before migrating — the schema fingerprint alone will not catch row-level change.

```sql
\copy (SELECT budget_id, max_budget, soft_budget, budget_duration, budget_reset_at::text FROM "LiteLLM_BudgetTable" ORDER BY budget_id) TO 'before-budgets.csv' CSV HEADER
\copy (SELECT user_id, max_budget, budget_duration, budget_reset_at::text FROM "LiteLLM_UserTable" WHERE max_budget IS NOT NULL ORDER BY user_id) TO 'before-users.csv' CSV HEADER
\copy (SELECT team_id, max_budget, soft_budget, budget_duration FROM "LiteLLM_TeamTable" ORDER BY team_id) TO 'before-teams.csv' CSV HEADER
\copy (SELECT user_id, team_id, budget_id FROM "LiteLLM_TeamMembership" ORDER BY team_id, user_id) TO 'before-membership.csv' CSV HEADER
\copy (SELECT token, budget_id, max_budget, budget_duration FROM "LiteLLM_VerificationToken" WHERE budget_id IS NOT NULL OR max_budget IS NOT NULL ORDER BY token) TO 'before-tokens.csv' CSV HEADER
```

Re-run as `after-*.csv` post-migration and `diff`. **Watch specifically for orphaned `budget_id` values** — a `budget_id` on a membership or token with no matching `LiteLLM_BudgetTable` row:

```sql
SELECT count(*) FROM "LiteLLM_TeamMembership" m
LEFT JOIN "LiteLLM_BudgetTable" b USING (budget_id)
WHERE m.budget_id IS NOT NULL AND b.budget_id IS NULL;   -- expect 0, before and after
```

**Structural fingerprint:** run `schema/verify-parity.sql` before and after and diff the two outputs. It captures migration head + count, columns, primary keys, foreign keys *with on-delete behavior*, indexes, and view definitions — deterministic and stripped of volatile data, so any diff line is a real change. That diff **is** the schema-delta record for the change ticket.

**One-off check worth running regardless of the upgrade** — raw (unhashed) API keys sitting in the spend table today:

```sql
SELECT api_key FROM "LiteLLM_DailyUserSpend" WHERE api_key !~ '^[0-9a-f]{64}$' LIMIT 20;
```

Any rows are plaintext keys in the database. They will start hashing under 1.93.0, which also means those rows begin matching the dashboards' `VerificationToken` subquery — **team spend totals may shift upward**. Expected, not a bug, but know the number before the change so you can explain it.

---

## 5. Cutover

1. **Snapshot RDS manually and confirm it is restorable.** Prisma migrations are forward-only. The migration is additive, but 1.93.0's `oauth2_flow` backfill *mutates* existing rows. **This snapshot is the rollback plan.**
2. Capture `before-*.csv` and the `verify-parity.sql` baseline ([§4](#4-pre-cutover-data-capture-do-this-on-the-work-db)).
3. Apply the tfvars change ([§1](#1-the-version-change)) plus `migrationJob.enabled: true` ([§2a](#2a-migrationjobenabled-must-be-true-for-this-deploy)). Add `LITELLM_SALT_KEY` ([§2b](#2b-litellm_salt_key-is-not-set--fix-it-in-this-window)). Reference config: [`examples/`](examples/).
4. `terraform plan` — review for: no DB recreate, chart version matches image version, `db.useExisting: false` retained, no plaintext secrets rendered into the ConfigMap.
5. `terraform apply`. Watch the migration job to completion **before** the proxy pods go ready.
6. Verify ([§7](#7-verification--positive-and-negative-probes)).
7. Set `migrationJob.enabled: false` again.

**Rollback:** restore the RDS snapshot and revert the tfvars pin. Do not attempt to roll the image back against a migrated schema without restoring the DB.

---

## 6. Known traps we are deliberately avoiding

**`1.94.0` — do not take it accidentally.** It carries its own breaking change ([PR #32005](https://github.com/BerriAI/litellm/pull/32005), quoted from the PR):

> **BREAKING CHANGE: team keys now enforce the key owner's personal `max_budget` by default.** Before this PR, a user's personal budget was silently ignored whenever they called the proxy with a team-scoped key; only the team and team-member budgets applied. After upgrading, once a user's personal spend crosses their `max_budget`, requests on their team keys return `429 ExceededBudget` even if the team budget still has headroom.

This hits us squarely: our onboard flow is `/user/new` → `/team/member_add` → `/key/generate`, so users hold **team-scoped keys**, and per-user `max_budget` values are populated (our dashboards read them). Those budgets have been silently inert. Under 1.94.0 they go live.

If you ever move to 1.94.0+, either set the opt-out to preserve current behaviour:

```yaml
general_settings:
  skip_user_budget_on_team_key: true
```

…or first find out exactly who would be blocked:

```sql
SELECT user_id, user_email, max_budget, spend FROM "LiteLLM_UserTable"
WHERE max_budget > 0 AND spend >= max_budget;
```

Enforcing personal budgets may well be what we want — but it should be its own change, with its own comms to teams, not a side effect of a CVE remediation.

**`1.95.0+` — hold off.** The 1.95.0 dev builds are landing a **Rust gateway rewrite** (native Anthropic `/messages` routed through Rust). 1.93/1.94 is the last pre-rewrite ground. Cross into the rewrite deliberately, not under CVE pressure.

**MCP** — five of the last six LiteLLM advisories are MCP-surface, including a Critical RCE and a High auth bypass. We configure **no MCP servers**, which is why none of them are our exposure. Keep it that way unless there's a reason not to; if MCP is ever enabled, re-read the advisory list first.

---

## 7. Verification — positive *and* negative probes

A clean `terraform apply` and healthy pods prove nothing about consumer-facing behaviour. Check both directions:

**Positive:**
- [ ] A Bedrock request succeeds through the proxy (`bedrock/au.anthropic.claude-*`, `ap-southeast-2`)
- [ ] An Azure AI Foundry request succeeds
- [ ] A spend row lands in `LiteLLM_SpendLogs` with the **correct AU cost** (explicit `model_info` pricing must still apply — regional inference profile pricing resolution changed in 1.93.0)
- [ ] Grafana cost dashboards render numbers, not blanks
- [ ] Admin UI loads and login works

**Negative:**
- [ ] A **revoked/deleted key returns 401**, not 200
- [ ] A key scoped to team A **cannot** call a model reserved for team B
- [ ] `/health/readiness` is not reachable unauthenticated from outside (after the ingress rule)
- [ ] `orphaned_membership_budget_ids` query still returns 0
- [ ] `after-*.csv` budget diff is empty

**Why both:** operations here routinely exit 0 with healthy-looking internal state and broken external behaviour. A key that authenticates is only half the check — one that *should* fail must actually fail.

---

## 8. After this upgrade — the pinning policy has to change

The old strategy (pin a vetted `-stable`, sit on it for months) is structurally dead. Replacement:

- **Track the latest stable and bump on a roughly monthly cadence.** Only the current line receives fixes, so a long pin is by definition an unsupported pin.
- **Release cadence is predictable:** nightly builds Tuesday and Thursday; each Saturday a new rc is cut and the previous week's rc promotes to stable after its 7-day soak. A monthly cadence always lands on something with 1–4 weeks in the wild.
- **New version formats** ([details](https://docs.litellm.ai/blog/cleaner-release-versions)): stable `1.93.0`, hotfix `1.93.0.post1` (**not** `-stable.patch.N`), rc `1.93.0rc1`, dev `1.93.0.dev42`.
- **Pin content tags, never `:latest`.** A floating tag is how the 1.81.0 drift and the `$0`-spend cost-map incident happened.
- **Watch for new advisories:** `https://api.deps.dev/v3alpha/systems/pypi/packages/litellm/versions/<version>` — `advisoryKeys` should be `[]`.

---

## Sources — all directly fetchable (no search required)

**Policy and release process**
- Release cycle and support policy — `https://docs.litellm.ai/docs/proxy/release_cycle`
- Version naming change — `https://docs.litellm.ai/blog/cleaner-release-versions`
- Release notes index — `https://docs.litellm.ai/release_notes/`
- Production best practices — `https://docs.litellm.ai/docs/proxy/prod`

**This upgrade**
- 1.84.0 breaking changes and migration guide — `https://docs.litellm.ai/release_notes/v1.84.0/v1-84-0`
- 1.93.0 release — `https://github.com/BerriAI/litellm/releases/tag/v1.93.0`
- 1.94.0 budget breaking change — `https://github.com/BerriAI/litellm/pull/32005`

**Security**
- CVE-2026-49468, auth bypass via Host header (**our forcing issue**, fixed 1.84.0) — `https://github.com/advisories/GHSA-4xpc-pv4p-pm3w`
- CVE-2026-59822, MCP auth bypass, High 8.8 (fixed 1.84.0) — `https://github.com/advisories/GHSA-7488-6r32-c95q`
- CVE-2026-59820, path traversal, Moderate (fixed 1.83.7) — `https://github.com/advisories/GHSA-5jmr-gcrj-2c9q`
- CVE-2026-59819, local file read, Low (fixed 1.83.10) — `https://github.com/advisories/GHSA-4g5m-c9r5-49xf`
- CVE-2026-59821, guardrails bypass, Low (fixed 1.82.0) — `https://github.com/advisories/GHSA-72m8-9m7m-h278`
- CVE-2026-30623, MCP stdio command injection, Critical (fixed 1.83.7) — `https://docs.litellm.ai/blog/mcp-stdio-command-injection-april-2026`
- Full advisory list — `https://github.com/advisories?query=litellm`
- Encryption and salt key — `https://docs.litellm.ai/docs/proxy/security_encryption_faq`
- Master key rotation — `https://docs.litellm.ai/docs/proxy/master_key_rotations`

**Version and artefact checks**
- Latest stable on PyPI — `https://pypi.org/pypi/litellm/json`
- Release feed — `https://github.com/BerriAI/litellm/releases.atom`
- Advisories against a specific version — `https://api.deps.dev/v3alpha/systems/pypi/packages/litellm/versions/1.93.0`
- Helm chart versions — `https://github.com/orgs/berriai/packages/container/litellm-helm/versions`

**Internal**
- `schema/SCHEMA-MAP.md`, `schema/verify-parity.sql` — schema reference and before/after fingerprint
- `docs/litellm-ops-guide.md` — Helm/Terraform/ConfigMap operations
- `config/hardened-bedrock-models.yaml` — explicit AU pricing + 1M-context model config
