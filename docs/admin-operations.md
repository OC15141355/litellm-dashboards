# LiteLLM Admin Operations Guide

Reference for managing users, teams, keys, and auditing via the CLI tool and raw API calls.

---

## Setup

### CLI Tool

```bash
export LITELLM_API_BASE="https://litellm.dev.irad-launchpad.com"
export LITELLM_MASTER_KEY="sk-your-master-key"
export LITELLM_INSECURE=1  # only if using self-signed certs
```

### Raw API Calls

All curl commands use the master key for authentication:

```bash
LITELLM_URL="https://litellm.dev.irad-launchpad.com"
MASTER_KEY="sk-your-master-key"
```

---

## User Lifecycle

### Onboard a New User (Recommended)

Single command that handles everything cleanly — no orphaned keys.

**CLI:**
```bash
./litellm-admin.sh user onboard <user_id> <email> <role> <team> [key_alias]

# Example
./litellm-admin.sh user onboard jsmith john@company.com internal_user launchpad
./litellm-admin.sh user onboard admin1 admin@company.com proxy_admin launchpad admin1-key
```

**What it does:**
1. Creates the user account
2. Deletes the auto-generated orphan key
3. Adds user to the specified team
4. Generates a proper team-attributed key
5. Outputs the API key to share with the user

**Curl equivalent (manual steps):**
```bash
# Step 1: Create user
curl -X POST "$LITELLM_URL/user/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "user_email": "john@company.com",
    "user_role": "internal_user"
  }'
# Save the auto-generated key from the response

# Step 2: Delete the orphan auto-key
curl -X POST "$LITELLM_URL/key/delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-auto-generated-key-from-step-1"]}'

# Step 3: Add to team
curl -X POST "$LITELLM_URL/team/member_add" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "member": {"user_id": "jsmith", "role": "user"}
  }'

# Step 4: Generate proper key
curl -X POST "$LITELLM_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "team_id": "<team-uuid>",
    "key_alias": "jsmith-key"
  }'
```

### Offboard a User (Recommended)

Clean removal — keys, teams, user account. No orphans left behind.

**CLI:**
```bash
./litellm-admin.sh user offboard <user_id>

# Example
./litellm-admin.sh user offboard jsmith
```

**What it does:**
1. Finds and deletes all keys belonging to the user
2. Removes user from all teams
3. Deletes the user account

**Curl equivalent (manual steps):**
```bash
# Step 1: Find user's keys
curl -s "$LITELLM_URL/key/list?user_id=jsmith" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[].token'

# Step 2: Delete each key
curl -X POST "$LITELLM_URL/key/delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-delete"]}'

# Step 3: Check team memberships
curl -s "$LITELLM_URL/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.teams'

# Step 4: Remove from each team
curl -X POST "$LITELLM_URL/team/member_delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team-uuid>", "user_id": "jsmith"}'

# Step 5: Delete user
curl -X POST "$LITELLM_URL/user/delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_ids": ["jsmith"]}'
```

> **Important:** Always use `user onboard` / `user offboard` instead of manual create/delete. The `/user/new` endpoint auto-generates an orphan key that isn't attributed to any team. If you don't clean it up, it accumulates in the database.

---

## User Roles

| Role | Access | SSO Limit |
|------|--------|-----------|
| `proxy_admin` | Full admin — UI and API | Counts toward 5-user SSO cap |
| `proxy_admin_viewer` | Read-only admin | Counts toward 5-user SSO cap |
| `internal_user` | API-only access | Bypasses SSO limit |
| `internal_user_viewer` | Read-only API access | Bypasses SSO limit |

**SSO note:** Free tier LiteLLM has a 5-user limit for SSO logins. `internal_user` bypasses this — use it for developers who only need API key access (e.g. Claude Code users). Reserve `proxy_admin` for people who need the UI.

---

## User Management

### List Users

**CLI:**
```bash
./litellm-admin.sh user list
```

**Curl:**
```bash
curl -s "$LITELLM_URL/user/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.users[] | {user_id, user_email, user_role, teams}'
```

### Get User Info

**CLI:**
```bash
./litellm-admin.sh user info <user_id>
```

**Curl:**
```bash
curl -s "$LITELLM_URL/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

### Create User (Low-Level)

Use `user onboard` instead unless you have a specific reason.

**CLI:**
```bash
./litellm-admin.sh user create <user_id> <email> <role>
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/user/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "user_email": "john@company.com",
    "user_role": "internal_user"
  }'
```

### Add User to Team

**CLI:**
```bash
./litellm-admin.sh user add-to-team <user_id> <team> [role]
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/team/member_add" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "member": {"user_id": "jsmith", "role": "user"}
  }'
```

### Remove User from Team

**CLI:**
```bash
./litellm-admin.sh user remove-from-team <user_id> <team>
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/team/member_delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team-uuid>", "user_id": "jsmith"}'
```

---

## Team Management

### List Teams

**CLI:**
```bash
./litellm-admin.sh team list
```

**Curl:**
```bash
curl -s "$LITELLM_URL/team/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[] | {team_id, team_alias, max_budget, models}'
```

### Get Team Info

**CLI:**
```bash
./litellm-admin.sh team info <team>
```

**Curl:**
```bash
curl -s "$LITELLM_URL/team/info?team_id=<team-uuid>" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

### Create Team

**CLI:**
```bash
./litellm-admin.sh team create <alias> [budget] [models]

# Example
./litellm-admin.sh team create "engineering" 500 "claude-sonnet,claude-opus"
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/team/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "engineering",
    "max_budget": 500,
    "models": ["claude-sonnet", "claude-opus"]
  }'
```

### Update Team

**CLI:**
```bash
./litellm-admin.sh team update <team> <field> <value>

# Examples
./litellm-admin.sh team update engineering max_budget 1000
./litellm-admin.sh team update engineering models "claude-sonnet,claude-opus"
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/team/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team-uuid>", "max_budget": 1000}'
```

### Delete Team

**CLI:**
```bash
./litellm-admin.sh team delete <team>
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/team/delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_ids": ["<team-uuid>"]}'
```

### List Team Members

**CLI:**
```bash
./litellm-admin.sh team members <team>
```

**Curl:**
```bash
curl -s "$LITELLM_URL/team/info?team_id=<team-uuid>" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.members_with_roles'
```

---

## Key Management

### List Keys

**CLI:**
```bash
./litellm-admin.sh key list              # all keys
./litellm-admin.sh key list <team>       # keys for a specific team
```

**Curl:**
```bash
# All keys across teams
curl -s "$LITELLM_URL/team/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[] | .team_alias as $t | .keys[]? | {key: .token[0:20], alias: .key_alias, team: $t, spend: .spend}'
```

### Get Key Info

**CLI:**
```bash
./litellm-admin.sh key info <key>
```

**Curl:**
```bash
curl -s "$LITELLM_URL/key/info?key=sk-your-key" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

### Create Key

**CLI:**
```bash
./litellm-admin.sh key create <team> [alias] [budget] [models]

# Example
./litellm-admin.sh key create engineering "ci-cd-key" 100
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "key_alias": "ci-cd-key",
    "max_budget": 100
  }'
```

> **Important:** Save the key from the response immediately. It cannot be retrieved later.

### Delete Key

**CLI:**
```bash
./litellm-admin.sh key delete <key>
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/key/delete" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-delete"]}'
```

### Move Key to Different Team

**CLI:**
```bash
./litellm-admin.sh key move <key> <new_team>
```

**Curl:**
```bash
curl -X POST "$LITELLM_URL/key/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-the-key", "team_id": "<new-team-uuid>"}'
```

---

## Auditing

### Spend Report (Date Range)

**CLI:**
```bash
./litellm-admin.sh audit spend                          # last 30 days
./litellm-admin.sh audit spend 2026-01-01 2026-01-31    # specific range
```

**Curl:**
```bash
curl -s "$LITELLM_URL/spend/logs?start_date=2026-01-01&end_date=2026-01-31" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

### Team Spend

**CLI:**
```bash
./litellm-admin.sh audit team-spend <team>
```

**Curl:**
```bash
curl -s "$LITELLM_URL/team/info?team_id=<team-uuid>" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '{team: .team_info.team_alias, spend: .team_info.spend, budget: .team_info.max_budget}'
```

### All Teams Summary

**CLI:**
```bash
./litellm-admin.sh audit all-teams
```

### Full Audit (Teams + Members + Keys + Spend)

**CLI:**
```bash
./litellm-admin.sh audit full
```

### Available Models

**CLI:**
```bash
./litellm-admin.sh models
```

**Curl:**
```bash
curl -s "$LITELLM_URL/models" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.data[].id'
```

### Model Info (Pricing + Config)

**CLI:**
```bash
./litellm-admin.sh audit models
```

**Curl:**
```bash
curl -s "$LITELLM_URL/model/info" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.data[] | {model_name, input_cost: .model_info.input_cost_per_token, output_cost: .model_info.output_cost_per_token}'
```

---

## Health Check

**CLI:**
```bash
./litellm-admin.sh health
```

**Curl:**
```bash
curl -s "$LITELLM_URL/health" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

---

## Troubleshooting

### Find Orphaned Keys

Keys with no valid user — usually from deleted users:

```bash
curl -s "$LITELLM_URL/team/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[].keys[]? | select(.user_id == null or .user_id == "") | {token: .token[0:20], alias: .key_alias, team_id: .team_id}'
```

### Find Team UUID from Alias

```bash
curl -s "$LITELLM_URL/team/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[] | select(.team_alias == "launchpad") | .team_id'
```

### Check What Models a Key Can Access

```bash
curl -s "$LITELLM_URL/key/info?key=sk-the-key" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.info.models'
```

### SSO User Won't Delete

SSO-created users sometimes can't be deleted via the API. Use the database directly:

```bash
# Spin up a temporary psql pod
kubectl run psql-temp -n work-devops-tools --restart=Never \
  --image=postgres:15-alpine -- sleep 3600

kubectl exec -it psql-temp -n work-devops-tools -- \
  psql -h <rds-endpoint> -U postgres -d <dbname>

# Then in psql:
DELETE FROM "LiteLLM_VerificationToken" WHERE user_id = 'the-user-id';
DELETE FROM "LiteLLM_UserTable" WHERE user_id = 'the-user-id';

# Clean up
kubectl delete pod psql-temp -n work-devops-tools
```

### Database Cleanup — All Orphaned Keys

```sql
-- Find orphaned keys
SELECT token, key_alias, user_id
FROM "LiteLLM_VerificationToken"
WHERE user_id NOT IN (SELECT user_id FROM "LiteLLM_UserTable");

-- Delete them
DELETE FROM "LiteLLM_VerificationToken"
WHERE user_id NOT IN (SELECT user_id FROM "LiteLLM_UserTable");
```
