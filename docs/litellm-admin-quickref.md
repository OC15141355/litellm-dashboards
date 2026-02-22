# LiteLLM Admin Quick Reference

Standalone scripts and curl equivalents for day-to-day admin operations.

---

## Setup

```bash
export LITELLM_API_BASE="https://litellm.dev.your-domain.com"
export LITELLM_MASTER_KEY="sk-your-master-key"
```

All scripts will prompt for these if not set. All curl commands below assume these variables.

Scripts location: `admin-scripts/` in the repo.

---

## 1. Onboard a User

Creates user, cleans orphan key, adds to team, generates proper key.

**Script:**
```bash
./onboard-user.sh <user_id> <email> <role> <team> [key_alias]

# Examples
./onboard-user.sh jsmith john@company.com internal_user D102
./onboard-user.sh admin1 admin@company.com proxy_admin D102 admin1-key
```

**Output:**
```
[1/4] Creating user: jsmith (john@company.com) as internal_user
[2/4] Removing orphan key
[3/4] Adding to team: D102
[4/4] Generating key: jsmith-key

Done! User: jsmith | Team: D102 | Key: sk-xxxxxxxxxxxxxxxx
Send the API key securely. It cannot be retrieved later.
```

**Curl equivalent:**
```bash
# Step 1: Create user (save the auto-key from response)
curl -sk -X POST "$LITELLM_API_BASE/user/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "user_email": "john@company.com",
    "user_role": "internal_user"
  }'

# Step 2: Delete the orphan auto-key
curl -sk -X POST "$LITELLM_API_BASE/key/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-auto-key-from-step-1"]}'

# Step 3: Add to team
curl -sk -X POST "$LITELLM_API_BASE/team/member_add" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "member": {"user_id": "jsmith", "role": "user"}
  }'

# Step 4: Generate team key
curl -sk -X POST "$LITELLM_API_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "team_id": "<team-uuid>",
    "key_alias": "jsmith-key"
  }'
```

> **Why not just `/user/new`?** It auto-generates an orphan key not attributed to any team. These accumulate in the database. The script handles cleanup automatically.

---

## 2. Offboard a User

Shows summary, asks for confirmation, then deletes keys, removes from teams, deletes account.

**Script:**
```bash
./offboard-user.sh <user_id>

# Example
./offboard-user.sh jsmith
```

**Output:**
```
User:  jsmith (john@company.com)
Role:  internal_user
Keys:  1
  - jsmith-key
Teams: 1

Type 'jsmith' to confirm deletion: jsmith

[1/3] Deleting keys...
  Deleted: jsmith-key
[2/3] Removing from teams...
  Removed from: abc123-uuid
[3/3] Deleting user...

Done. jsmith (john@company.com) fully removed.
```

**Curl equivalent:**
```bash
# Step 1: Get user info (keys + teams)
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .

# Step 2: Delete each key
curl -sk -X POST "$LITELLM_API_BASE/key/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-delete"]}'

# Step 3: Remove from each team
curl -sk -X POST "$LITELLM_API_BASE/team/member_delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team-uuid>", "user_id": "jsmith"}'

# Step 4: Delete user
curl -sk -X POST "$LITELLM_API_BASE/user/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_ids": ["jsmith"]}'
```

---

## 3. Update Team Models

Interactive — lists available models, lets you pick which to assign.

**Script:**
```bash
./update-team-models.sh <team>

# List teams first
./update-team-models.sh
```

**Output:**
```
Team: D102 (abc-123-uuid)
Current models: ["claude-opus","claude-sonnet"]

Available models:
  1) claude-opus *
  2) claude-sonnet *
  3) claude-sonnet-4.6

  a) All models (no restriction)
  * = currently assigned

Select (comma-separated or 'a'): 1,2,3
Setting: ["claude-opus","claude-sonnet","claude-sonnet-4.6"]
Confirm? (y/n): y
Done.
```

**Curl equivalent:**
```bash
# List teams (find UUID)
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {team_alias, team_id, models}'

# List available models
curl -sk "$LITELLM_API_BASE/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'

# Update team models
curl -sk -X POST "$LITELLM_API_BASE/team/update" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "models": ["claude-opus", "claude-sonnet", "claude-sonnet-4.6"]
  }'
```

---

## 4. Rotate Key

Deletes all existing keys for a user, generates a fresh one on the same team.

**Script:**
```bash
./rotate-key.sh <user_id>

# Example
./rotate-key.sh jsmith
```

**Output:**
```
User:  jsmith (john@company.com)
Keys:  1
Team:  abc-123-uuid

Rotate keys for jsmith? (y/n): y

[1/2] Deleting old keys...
  Deleted: jsmith-key
[2/2] Generating new key: jsmith-key

Done! User: jsmith | Key: sk-xxxxxxxxxxxxxxxx
Send the new API key securely. Old keys are now invalid.
```

**Curl equivalent:**
```bash
# Step 1: Get user info (find keys + team)
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{keys: [.keys[]?.token], team: .keys[0]?.team_id, alias: .keys[0]?.key_alias}'

# Step 2: Delete old keys
curl -sk -X POST "$LITELLM_API_BASE/key/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-old-key"]}'

# Step 3: Generate new key on same team
curl -sk -X POST "$LITELLM_API_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "jsmith",
    "team_id": "<team-uuid>",
    "key_alias": "jsmith-key"
  }'
```

---

## 5. Bulk Onboard

Onboard multiple users from a CSV file. Same workflow as onboard-user.sh but in a loop.

**CSV format:**
```csv
user_id,email,role,team,key_alias
jsmith,john@company.com,internal_user,D102,jsmith-key
alee,alice@company.com,internal_user,D102,
bwong,bob@company.com,proxy_admin,D102,bwong-admin
```

- Header row is optional (skipped automatically)
- `key_alias` is optional — defaults to `<user_id>-key`
- Lines starting with `#` are skipped

**Script:**
```bash
./bulk-onboard.sh users.csv
```

**Output:**
```
Users to onboard:
---
  jsmith (john@company.com) as internal_user → D102
  alee (alice@company.com) as internal_user → D102
  bwong (bob@company.com) as proxy_admin → D102
---
Total: 3

Proceed? (y/n): y

OK:   jsmith (john@company.com) → sk-xxxxxxxxxxxx
OK:   alee (alice@company.com) → sk-xxxxxxxxxxxx
OK:   bwong (bob@company.com) → sk-xxxxxxxxxxxx

Done. 3 succeeded, 0 failed.
```

**Curl equivalent:** Same as onboard (section 1), repeated per user. The script just automates the 4-step onboard workflow for each CSV row.

---

## User Roles

| Role | Access | SSO Limit |
|------|--------|-----------|
| `proxy_admin` | Full admin — UI and API | Counts toward 5-user SSO cap |
| `proxy_admin_viewer` | Read-only admin | Counts toward 5-user SSO cap |
| `internal_user` | API-only access | **Bypasses** SSO limit |
| `internal_user_viewer` | Read-only API access | **Bypasses** SSO limit |

**Recommendation:** Use `internal_user` for developers who only need API key access (e.g. Claude Code). Reserve `proxy_admin` for people who need the LiteLLM UI dashboard.

---

## Useful Curl Commands

### Users

```bash
# List all users
curl -sk "$LITELLM_API_BASE/user/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.users[] | {user_id, user_email, user_role}'

# Get specific user
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .
```

### Teams

```bash
# List teams with budgets
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {team_alias, team_id, max_budget, spend: .spend, models}'

# Team members
curl -sk "$LITELLM_API_BASE/team/info?team_id=<uuid>" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.members_with_roles'

# Create team
curl -sk -X POST "$LITELLM_API_BASE/team/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "engineering",
    "max_budget": 500,
    "models": ["claude-sonnet", "claude-opus"]
  }'

# Delete team
curl -sk -X POST "$LITELLM_API_BASE/team/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_ids": ["<team-uuid>"]}'
```

### Keys

```bash
# Get key info
curl -sk "$LITELLM_API_BASE/key/info?key=sk-the-key" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .

# Check what models a key can access
curl -sk "$LITELLM_API_BASE/key/info?key=sk-the-key" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.info.models'

# Generate standalone key (no user)
curl -sk -X POST "$LITELLM_API_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-uuid>",
    "key_alias": "ci-cd-key",
    "max_budget": 100
  }'

# Delete key
curl -sk -X POST "$LITELLM_API_BASE/key/delete" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-delete"]}'

# Move key to different team
curl -sk -X POST "$LITELLM_API_BASE/key/update" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-the-key", "team_id": "<new-team-uuid>"}'
```

### Models

```bash
# List available models
curl -sk "$LITELLM_API_BASE/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'

# Model pricing info
curl -sk "$LITELLM_API_BASE/model/info" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[] | {model_name, input_cost: .model_info.input_cost_per_token, output_cost: .model_info.output_cost_per_token}'

# Add new model (when UI dropdown doesn't have it)
# IMPORTANT: custom_llm_provider must be "bedrock_converse" for Bedrock models
curl -sk -X POST "$LITELLM_API_BASE/model/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "claude-sonnet-4.6",
    "litellm_params": {
      "model": "au.anthropic.claude-sonnet-4-6",
      "custom_llm_provider": "bedrock_converse",
      "api_key": "BEDROCK_API_KEY",
      "aws_bedrock_runtime_endpoint": "https://your-endpoint.amazonaws.com"
    }
  }'
```

### Spend & Auditing

```bash
# Team spend summary
curl -sk "$LITELLM_API_BASE/team/info?team_id=<uuid>" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{team: .team_info.team_alias, spend: .team_info.spend, budget: .team_info.max_budget}'

# Spend logs (date range)
curl -sk "$LITELLM_API_BASE/spend/logs?start_date=2026-01-01&end_date=2026-01-31" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .

# All teams spend overview
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {team: .team_alias, spend, budget: .max_budget}'
```

### Health & Diagnostics

```bash
# Health check
curl -sk "$LITELLM_API_BASE/health" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .

# Find orphaned keys (no valid user)
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[].keys[]? | select(.user_id == null or .user_id == "") | {token: .token[0:20], alias: .key_alias, team_id: .team_id}'

# Find team UUID from alias
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | select(.team_alias == "D102") | .team_id'
```

---

## Troubleshooting

### SSO User Won't Delete via API

SSO-created users sometimes can't be deleted. Use the database directly:

```bash
kubectl run psql-temp -n <namespace> --restart=Never \
  --image=postgres:15-alpine -- sleep 3600

kubectl exec -it psql-temp -n <namespace> -- \
  psql -h <rds-endpoint> -U postgres -d <dbname>

# In psql:
DELETE FROM "LiteLLM_VerificationToken" WHERE user_id = 'the-user-id';
DELETE FROM "LiteLLM_UserTable" WHERE user_id = 'the-user-id';

# Clean up
kubectl delete pod psql-temp -n <namespace>
```

### Database Cleanup — Orphaned Keys

```sql
-- Find orphaned keys
SELECT token, key_alias, user_id
FROM "LiteLLM_VerificationToken"
WHERE user_id NOT IN (SELECT user_id FROM "LiteLLM_UserTable");

-- Delete them
DELETE FROM "LiteLLM_VerificationToken"
WHERE user_id NOT IN (SELECT user_id FROM "LiteLLM_UserTable");
```

### Adding Models When UI Dropdown Is Outdated

If a new model (e.g. Sonnet 4.6) isn't in the LiteLLM UI dropdown, use the `/model/new` curl command above. The dropdown is hardcoded per LiteLLM version — upgrading LiteLLM will add newer models.

### 504 Gateway Timeout on Large Requests

This is the ingress timeout (default 60s for nginx), not LiteLLM. Fix:

```bash
kubectl annotate ingress <litellm-ingress> -n <namespace> \
  "nginx.ingress.kubernetes.io/proxy-read-timeout=3600" --overwrite
```

Or set in Helm values:
```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
```
