# LiteLLM Testing Scenarios

## Overview

Testing validation of three permission levels in LiteLLM: Admin (platform team), Team Lead (internal_user), and End User (virtual key only). The goal is to confirm that team-based access control works on the free tier without enterprise license.

### Key Finding

The SSO 5-user limit applies to **admin roles only**. Internal users (`internal_user`) can be created without limit and have scoped access to key management, usage, and logs - but cannot create teams or access admin functions. This enables a self-service model for team leads without enterprise.

---

## Permission Model

| Role | Access | Creates Keys? | Sees Spend? | Creates Teams? | UI Access? |
|------|--------|---------------|-------------|----------------|------------|
| **Admin** (platform team) | Master key - full access | All teams | All teams | Yes | Yes (fallback login) |
| **Team Lead** (internal_user) | UI login - scoped to team | Own team only | Own team only | No | Yes (password login) |
| **End User** (developer) | Virtual key only | No | No | No | No |

### Workflow

```
Platform Team (Admin)
  │
  ├── Creates team + budget + model access
  ├── Creates team lead as internal_user
  │
  └── Team Lead (internal_user)
        │
        ├── Logs into UI (password reset link)
        ├── Creates/manages virtual keys for their team
        ├── Views usage and logs for their team
        │
        └── Developer (end user)
              │
              └── Uses virtual key for LLM requests only
```

---

## Test Environment Setup

```bash
# Set admin credentials
export LITELLM_API_BASE="https://litellm.example.com"
export LITELLM_MASTER_KEY="sk-..."
```

---

## Scenario 1: Admin (Platform Team)

### 1.1 CRUD Teams

```bash
# CREATE team with budget and model access
./litellm-admin.sh team create "Test-Engineering" 500 "claude-3-sonnet,claude-3-haiku"

# READ - list all teams
./litellm-admin.sh team list

# READ - team details
./litellm-admin.sh team info Test-Engineering

# UPDATE - change budget (via API)
curl -X POST "${LITELLM_API_BASE}/team/update" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team-uuid>", "max_budget": 1000}'

# DELETE team
curl -X POST "${LITELLM_API_BASE}/team/delete" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"team_ids": ["<team-uuid>"]}'
```

**Expected**: All operations succeed with master key.

### 1.2 CRUD Virtual Keys

```bash
# CREATE key for team
./litellm-admin.sh key create Test-Engineering "admin-test-key" 100

# READ - list keys for team
./litellm-admin.sh key list Test-Engineering

# UPDATE - change key budget (via API)
curl -X POST "${LITELLM_API_BASE}/key/update" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-...", "max_budget": 200}'

# DELETE key
curl -X POST "${LITELLM_API_BASE}/key/delete" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-..."]}'
```

**Expected**: All operations succeed with master key.

### 1.3 CRUD Users

```bash
# CREATE internal_user (team lead)
curl -X POST "${LITELLM_API_BASE}/user/new" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "teamlead@example.com",
    "user_role": "internal_user",
    "team_id": "<team-uuid>"
  }'

# CREATE admin user (expect: may fail if over 5 SSO users)
curl -X POST "${LITELLM_API_BASE}/user/new" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "admin2@example.com",
    "user_role": "proxy_admin"
  }'

# READ - list all users
./litellm-admin.sh user list

# DELETE user
curl -X POST "${LITELLM_API_BASE}/user/delete" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"user_ids": ["<user-id>"]}'
```

**Expected**:
- `internal_user` creation: succeeds (no limit)
- `proxy_admin` creation: fails if over 5 SSO users (free tier limit)

### 1.4 SSO Limitations

| Test | Expected Result |
|------|----------------|
| Create 6th admin user | Error - SSO 5 user limit on free tier |
| Create 6th+ internal_user | Succeeds - no limit on internal users |
| Admin login via fallback UI | Works with master key |
| Internal user login via fallback UI | Works with password reset link |

### 1.5 Budget Management

```bash
# Create team with monthly budget
./litellm-admin.sh team create "Budget-Test" 10 "claude-3-sonnet"

# Create key with individual budget
./litellm-admin.sh key create Budget-Test "budget-test-key" 5

# Verify budget
./litellm-admin.sh audit team-spend Budget-Test
```

### 1.6 Monitoring & Logging

```bash
# Audit all teams
./litellm-admin.sh audit all-teams

# Audit specific team
./litellm-admin.sh audit team-spend Test-Engineering

# Full audit
./litellm-admin.sh audit full
```

**Also verify**:
- Grafana Operations dashboard shows all teams
- Prometheus metrics flowing (`litellm_spend_metric_total`)
- Remaining budget metric visible (`litellm_remaining_team_budget_metric`)

---

## Scenario 2: Team Lead (internal_user)

### 2.0 Setup

Admin creates team lead account:

```bash
# Admin creates team
./litellm-admin.sh team create "Lead-Test-Team" 500 "claude-3-sonnet,claude-3-haiku"

# Admin creates internal_user for team lead
curl -X POST "${LITELLM_API_BASE}/user/new" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "teamlead@example.com",
    "user_role": "internal_user",
    "team_id": "<team-uuid>"
  }'
```

Team lead receives password reset link and logs into UI.

### 2.1 CRUD Virtual Keys (Own Team)

| Test | Action | Expected |
|------|--------|----------|
| Create key | Create new virtual key in UI for own team | Succeeds |
| View keys | List keys for own team | Succeeds - sees own team's keys |
| Delete key | Delete a key from own team | Succeeds |
| Create key for other team | Attempt to create key for different team | Should fail / not visible |

### 2.2 Team Scope Validation

| Test | Expected |
|------|----------|
| View own team's keys | Succeeds |
| View other team's keys | Not visible / access denied |
| View own team's usage | Succeeds |
| View other team's usage | Not visible / access denied |
| View own team's logs | Succeeds |
| View other team's logs | Not visible / access denied |

### 2.3 Restricted Operations

| Test | Expected |
|------|----------|
| Create a new team | Fails - no permission |
| Delete a team | Fails - no permission |
| Modify team budget | Fails - no permission |
| Add users to team | Fails - no permission |
| Access admin settings | Not visible / access denied |

### 2.4 Metrics Visibility

| Test | Expected |
|------|----------|
| View Grafana Team dashboard (own team) | Succeeds - filtered by team alias |
| View Grafana Team dashboard (other team) | No data (if filtered correctly) |
| View per-key spend breakdown | Succeeds for own team's keys |

---

## Scenario 3: End User (Developer with Virtual Key)

### 3.0 Setup

Team lead creates key for developer:

1. Team lead logs into LiteLLM UI
2. Creates new virtual key: alias `dev-alice`, budget $50
3. Sends key to developer

Developer configures Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://litellm.example.com"
export ANTHROPIC_API_KEY="sk-dev-alice-key-here"
```

### 3.1 Successful Request

```bash
curl -X POST "${LITELLM_API_BASE}/chat/completions" \
  -H "Authorization: Bearer sk-dev-alice-key-here" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3-sonnet",
    "messages": [{"role": "user", "content": "Say hello"}]
  }'
```

**Expected**: Succeeds. Spend attributed to team and key alias.

### 3.2 Blocked Model

```bash
curl -X POST "${LITELLM_API_BASE}/chat/completions" \
  -H "Authorization: Bearer sk-dev-alice-key-here" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Say hello"}]
  }'
```

**Expected**: Rejected - model not in team's allowed list.

### 3.3 Budget Exceeded

Make requests until key budget ($50) is exceeded.

**Expected**: Request blocked with "Budget has been exceeded" error.

### 3.4 Team Budget Exceeded

Even if individual key has budget remaining, if team budget is exhausted:

**Expected**: Request blocked at team level.

### 3.5 Key Revoked

Team lead deletes the key in UI. Developer tries same key.

**Expected**: Immediate rejection.

### 3.6 No Console Access

| Test | Expected |
|------|----------|
| Developer tries to log into LiteLLM UI | No credentials to do so |
| Developer tries admin API with their virtual key | Rejected - not admin |
| Developer tries to list other keys | Rejected |
| Developer tries to create a key | Rejected |

---

## Edge Cases

### Budget Timing

| Test | Expected |
|------|----------|
| Rapid burst of requests near budget limit | May slightly overshoot due to async spend recording |
| Streaming response near budget limit | Response completes, spend recorded after stream ends |

### Key & Team Lifecycle

| Test | Expected |
|------|----------|
| Delete team with active keys | Keys should be invalidated |
| Move key to different team | Spend attribution changes to new team |
| Two users hitting team budget simultaneously | Both may get through if spend hasn't been recorded yet |
| Pod restart during active request | Client gets error, no spend recorded for incomplete request |

### Model Access

| Test | Expected |
|------|----------|
| Request model with different casing | Test if model matching is case-sensitive |
| Request model alias vs actual model name | Depends on config - test both |

---

## Test Results Template

| Test ID | Scenario | Test | Expected | Actual | Pass/Fail | Notes |
|---------|----------|------|----------|--------|-----------|-------|
| A-1.1 | Admin | Create team | Succeeds | | | |
| A-1.2 | Admin | List teams | Succeeds | | | |
| A-1.3 | Admin | Update team budget | Succeeds | | | |
| A-1.4 | Admin | Delete team | Succeeds | | | |
| A-2.1 | Admin | Create key | Succeeds | | | |
| A-2.2 | Admin | List keys | Succeeds | | | |
| A-2.3 | Admin | Delete key | Succeeds | | | |
| A-3.1 | Admin | Create internal_user | Succeeds | | | |
| A-3.2 | Admin | Create 6th admin | Fails (SSO limit) | | | |
| A-3.3 | Admin | Create 6th+ internal_user | Succeeds | | | |
| T-1.1 | Team Lead | Create key (own team) | Succeeds | | | |
| T-1.2 | Team Lead | View keys (own team) | Succeeds | | | |
| T-1.3 | Team Lead | Delete key (own team) | Succeeds | | | |
| T-2.1 | Team Lead | View other team's data | Access denied | | | |
| T-2.2 | Team Lead | Create team | Fails | | | |
| T-2.3 | Team Lead | Modify budget | Fails | | | |
| T-2.4 | Team Lead | Add users | Fails | | | |
| U-1.1 | End User | Allowed model request | Succeeds | | | |
| U-1.2 | End User | Blocked model request | Rejected | | | |
| U-1.3 | End User | Key budget exceeded | Blocked | | | |
| U-1.4 | End User | Team budget exceeded | Blocked | | | |
| U-1.5 | End User | Revoked key | Rejected | | | |
| U-1.6 | End User | Admin API with virtual key | Rejected | | | |
