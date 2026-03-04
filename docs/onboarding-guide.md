# LiteLLM Onboarding Guide

Step-by-step: create a team, add users, set budgets.

---

## 1. Create the Team

```bash
curl -sk -X POST "$LITELLM_API_BASE/team/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "D102",
    "max_budget": 500,
    "budget_duration": "30d",
    "models": ["claude-sonnet-4-20250514", "claude-haiku"]
  }'
```

| Field | Purpose |
|-------|---------|
| `team_alias` | Friendly name (used in scripts, reporting, charge codes) |
| `max_budget` | Team-wide spend cap in USD |
| `budget_duration` | Reset period (`30d` = monthly) |
| `models` | Which models the team can access (empty = all) |

Save the `team_id` from the response — or just use the alias in scripts (they resolve it automatically).

---

## 2. Prepare the CSV

Create a file (e.g. `d102-users.csv`):

```csv
user_id,email,role,team,key_alias
jsmith,john.smith@company.com,internal_user,D102,jsmith-key
alee,alice.lee@company.com,internal_user,D102,alee-key
bwong,bob.wong@company.com,internal_user,D102,bwong-key
```

**Fields:**

| Column | Required | Notes |
|--------|----------|-------|
| `user_id` | Yes | Unique identifier (e.g. username, employee ID) |
| `email` | Yes | For attribution and reporting |
| `role` | Yes | `internal_user` for API-only, `proxy_admin` for UI access |
| `team` | Yes | Team alias or UUID |
| `key_alias` | No | Defaults to `<user_id>-key` if empty |

**Roles:**

| Role | Access |
|------|--------|
| `internal_user` | API key access only — standard for developers |
| `internal_user_viewer` | Read-only API access |
| `proxy_admin` | Full admin UI + API |
| `proxy_admin_viewer` | Read-only admin UI |

---

## 3. Run Bulk Onboard

```bash
export LITELLM_API_BASE="https://litellm.your-domain.com"
export LITELLM_MASTER_KEY="sk-your-master-key"

./bulk-onboard.sh d102-users.csv
```

Output:

```
Users to onboard:
---
  jsmith (john.smith@company.com) as internal_user → D102
  alee (alice.lee@company.com) as internal_user → D102
  bwong (bob.wong@company.com) as internal_user → D102
---
Total: 3

Proceed? (y/n): y

OK:   jsmith (john.smith@company.com) → sk-xxxxxxxxxxxx
OK:   alee (alice.lee@company.com) → sk-xxxxxxxxxxxx
OK:   bwong (bob.wong@company.com) → sk-xxxxxxxxxxxx

Done. 3 succeeded, 0 failed.
```

**Send each user their API key securely.** Keys cannot be retrieved after generation.

---

## 4. Set Per-Key Budgets

After onboarding, set individual spend limits:

```bash
./set-team-key-budgets.sh D102 100 30d
```

This sets `$100/month` on every key in the team. The team budget ($500) is the overall cap; individual key budgets prevent any one person from burning through the whole thing.

---

## 5. Assign Models to the Team

If you need to update which models the team can access:

```bash
./update-team-models.sh D102
```

Interactive — shows available models, lets you pick.

---

## 6. Verify

```bash
# Check team setup
curl -sk "$LITELLM_API_BASE/team/info?team_id=<uuid>" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{
    team: .team_info.team_alias,
    budget: .team_info.max_budget,
    spend: .team_info.spend,
    models: .team_info.models,
    members: [.members_with_roles[].user_id]
  }'
```

---

## What Users Need

Send each onboarded user:

1. Their API key (`sk-...`)
2. The LiteLLM base URL
3. Setup instructions:

```bash
# Add to shell profile or Claude Code config
export ANTHROPIC_BASE_URL="https://litellm.your-domain.com"
export ANTHROPIC_API_KEY="sk-their-key-here"
```

---

## Day-to-Day Operations

| Task | Script |
|------|--------|
| Add a single user | `./onboard-user.sh <user_id> <email> <role> <team>` |
| Remove a user | `./offboard-user.sh <user_id>` |
| Rotate a key | `./rotate-key.sh <user_id>` |
| Update key budgets | `./set-team-key-budgets.sh <team> <budget> [duration]` |
| Monthly spend report | `./spend-report.sh --start 2026-02-01 --end 2026-02-28 --csv` |
| Bulk offboard | `./bulk-offboard.sh <file>` or `./bulk-offboard.sh --team <team>` |
