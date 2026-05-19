# LiteLLM Cost Tracking Incident — Work-Claude Kickoff

> Paste the prompt below to Claude Code in the work environment. It pairs with
> `docs/cost-tracking-incident-investigation-brief.md` in this repo — pull latest
> `main` first so both files are present.

## Kickoff prompt (paste verbatim)

Read `docs/cost-tracking-incident-investigation-brief.md` in this repo in full before doing anything. It's a resolved incident brief — the version posture, downgrade verdict, and root cause are already settled with evidence; do not re-investigate or re-litigate them. Your job is execution of the remediation, in this order:

1. **Confirm in the data** (don't re-derive): query the stored model record(s) and a `LiteLLM_SpendLogs` sample to confirm `input_cost_per_token`/`output_cost_per_token` are 0/null for the `au.`-prefixed models since 2026-05-12, and size the affected row count (expect ~6131).
2. **Stop forward bleeding**: produce the `proxy_config.model_list` YAML with explicit `input_cost_per_token`/`output_cost_per_token` for every `au.` Bedrock model (rates in the brief — re-verify against current Bedrock AU pricing), plus the digest-pin change (kill the floating `:main-stable` tag) and `LITELLM_LOCAL_MODEL_COST_MAP=True`.
3. **Backfill**: SQL with the safety wrapper from the brief (BEGIN, count-first SELECT, sample verify, then UPDATE) recomputing spend from intact token counts × correct AU rates, then rebuild DailyTeamSpend.
4. **AWS billing** (brief Task 4) and **postmortem draft** (Task 6).

Ask me clarifying questions before the backfill UPDATE and before any change that touches prod. Do not downgrade LiteLLM under any circumstance — the brief explains why it's a trap.

## Prerequisites — have these ready or work-Claude will block

| Need | For |
|---|---|
| Read access to the LiteLLM RDS PostgreSQL (SpendLogs query + the backfill) | Steps 1, 3 |
| AWS creds with Cost Explorer (`ce:GetCostAndUsage`) | Task 4 |
| The deployment repo (Helm values / Terraform) for the `model_list` + digest-pin change | Step 2 |
| Running image digest: `kubectl -n <ns> get pod -l <sel> -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'` | Step 2 pin |
| Current Bedrock ap-southeast-2 pricing (re-verify; rates in brief may have moved) | Steps 2, 3 |

## Hard constraints (also in the brief — restated so they are not missed)

- **No downgrade.** Bug predates the CVE-clean floor; Prisma migrations are forward-only with no down-path. Downgrade trades a fixable cost bug for active CVEs + an unrecoverable DB.
- **No version chase.** PR #27625 is unreleased; no release fixes #27612. The fix is config-level only.
- Backfill corrects history independent of code version — it is orthogonal to any version decision.
- Compliance context: Essential Eight ML2/ML3, ISM — every change and the backfill must be audit-defensible (transaction-wrapped, count-first, sample-verified, logged).
