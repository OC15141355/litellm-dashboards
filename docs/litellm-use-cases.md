# LiteLLM Use Cases & Test Scenarios

End-to-end walkthroughs from the admin and developer perspective, with test cases to verify each flow.

---

## Personas

| Persona | Role | Access |
|---------|------|--------|
| **Platform Admin** | `proxy_admin` | UI dashboard + API + scripts |
| **Team Lead** | `proxy_admin_viewer` | UI dashboard (read-only) |
| **Developer** | `internal_user` | API key only (Claude Code) |

---

## 1. New Developer Onboarding

**Scenario:** A new developer joins team D102 and needs Claude Code access.

### Admin Steps

```bash
# 1. Onboard the user
./onboard-user.sh jsmith john@company.com internal_user D102

# Expected output:
# [1/4] Creating user: jsmith (john@company.com) as internal_user
# [2/4] Removing orphan key
# [3/4] Adding to team: D102
# [4/4] Generating key: jsmith-key
#
# Done! User: jsmith | Team: D102 | Key: sk-xxxxxxxxxxxxxxxx
```

```bash
# 2. Verify the user exists
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{
    user_id: .user_info.user_id,
    email: .user_info.user_email,
    role: .user_info.user_role,
    teams: .user_info.teams
  }'
```

```bash
# 3. Verify the key works
curl -sk -X POST "$LITELLM_API_BASE/chat/completions" \
  -H "Authorization: Bearer sk-the-generated-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4.6","messages":[{"role":"user","content":"say hi"}],"max_tokens":10}'
```

### Developer Steps

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code@latest`
2. VS Code: add to `settings.json`:
   ```json
   "claudeCode.environmentVariables": {
     "ANTHROPIC_BASE_URL": "https://litellm.dev.your-domain.com",
     "ANTHROPIC_AUTH_TOKEN": "sk-the-generated-key",
     "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4.6",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus",
     "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4.6",
     "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
   }
   ```
3. CLI: add to `~/.claude/settings.json`:
   ```json
   {
     "env": {
       "ANTHROPIC_BASE_URL": "https://litellm.dev.your-domain.com",
       "ANTHROPIC_AUTH_TOKEN": "sk-the-generated-key",
       "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4.6",
       "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus",
       "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4.6",
       "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
     }
   }
   ```
4. Open terminal, run `claude` — should connect without login prompt
5. Test: ask Claude Code to explain a file in the repo

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 1.1 | Run onboard script | Key returned, no errors | |
| 1.2 | Query `/user/info` | User exists with correct role and team | |
| 1.3 | Hit `/chat/completions` with generated key | Model responds | |
| 1.4 | Hit `/chat/completions` with wrong model | Error: team doesn't have access | |
| 1.5 | Open Claude Code in VS Code | Connects, no login prompt | |
| 1.6 | Run a prompt in Claude Code | Response returned, no 400/401/504 | |
| 1.7 | Check spend logs after prompt | User's request appears in logs | |

---

## 2. Bulk Team Onboarding

**Scenario:** 5 new developers joining team D102 at once.

### Admin Steps

```bash
# 1. Create CSV
cat > new-users.csv << 'EOF'
user_id,email,role,team,key_alias
dev1,dev1@company.com,internal_user,D102,
dev2,dev2@company.com,internal_user,D102,
dev3,dev3@company.com,internal_user,D102,
dev4,dev4@company.com,internal_user,D102,
dev5,dev5@company.com,internal_user,D102,
EOF

# 2. Run bulk onboard
./bulk-onboard.sh new-users.csv

# 3. Distribute keys securely (e.g. direct message, password manager)
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 2.1 | Run bulk onboard with 5-user CSV | All 5 succeed, keys printed | |
| 2.2 | Verify all 5 users in `/user/list` | All present with correct roles | |
| 2.3 | Verify all 5 keys work | Each key can hit `/chat/completions` | |
| 2.4 | Check no orphan keys created | No unattributed keys in DB | |

---

## 3. Developer Offboarding

**Scenario:** A developer leaves the team. Revoke all access immediately.

### Admin Steps

```bash
# 1. Offboard
./offboard-user.sh jsmith

# Expected: shows summary, asks confirmation, deletes everything

# 2. Verify removal
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
# Should return user not found

# 3. Verify old key is dead
curl -sk -X POST "$LITELLM_API_BASE/chat/completions" \
  -H "Authorization: Bearer sk-the-old-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4.6","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
# Should return 401/403
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 3.1 | Run offboard script | Confirmation shown, user deleted | |
| 3.2 | Query deleted user | Not found | |
| 3.3 | Use deleted user's key | 401 unauthorized | |
| 3.4 | Check team membership | User removed from team | |
| 3.5 | Check for orphan keys | None left behind | |

---

## 4. Key Compromise / Rotation

**Scenario:** Developer reports their API key may have been exposed (committed to Git, shared in Slack, etc.).

### Admin Steps

```bash
# 1. Rotate immediately
./rotate-key.sh jsmith

# Expected: old key deleted, new key generated on same team

# 2. Send new key to developer securely

# 3. Developer updates their config with new key
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 4.1 | Run rotate script | Old key deleted, new key returned | |
| 4.2 | Use old key | 401 unauthorized | |
| 4.3 | Use new key | Works, model responds | |
| 4.4 | New key has same team attribution | Correct team_id on key info | |

---

## 5. New Model Rollout

**Scenario:** New Claude model available on Bedrock (e.g. Sonnet 4.6). Need to add it and give teams access.

### Admin Steps

```bash
# 1. Verify model exists on Bedrock
aws bedrock-runtime invoke-model \
  --model-id "au.anthropic.claude-sonnet-4-6" \
  --region ap-southeast-2 \
  --content-type "application/json" \
  --accept "application/json" \
  --body file:///tmp/body.json \
  /tmp/response.json

# 2. Add to LiteLLM (use bedrock_converse!)
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

# 3. Test it works
curl -sk -X POST "$LITELLM_API_BASE/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4.6","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'

# 4. Update team models
./update-team-models.sh D102

# 5. Notify developers to update their config:
#    ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4.6
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 5.1 | Model exists on Bedrock | Response returned | |
| 5.2 | Add model via curl | Model appears in `/models` list | |
| 5.3 | Model persists (doesn't disappear) | Still there after 5 minutes | |
| 5.4 | Test with master key | Response returned | |
| 5.5 | Update team, test with user key | Response returned | |
| 5.6 | Developer updates Claude Code config | Claude Code uses new model | |

---

## 6. Team Budget Management

**Scenario:** Set spending limits per team and monitor usage.

### Admin Steps

```bash
# 1. Create team with budget
curl -sk -X POST "$LITELLM_API_BASE/team/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "D103",
    "max_budget": 500,
    "models": ["claude-sonnet-4.6", "claude-opus"]
  }'

# 2. Check team spend
curl -sk "$LITELLM_API_BASE/team/info?team_id=<uuid>" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{
    team: .team_info.team_alias,
    spend: .team_info.spend,
    budget: .team_info.max_budget
  }'

# 3. All teams overview
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {team: .team_alias, spend, budget: .max_budget}'
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 6.1 | Create team with $500 budget | Team created | |
| 6.2 | User makes requests | Spend increments | |
| 6.3 | Check team spend | Reflects actual usage | |
| 6.4 | Budget exceeded (if testable) | Requests rejected | |

> **Note:** LiteLLM spend tracking uses default public pricing, not your contracted Bedrock rates. Treat as relative usage, not actual cost.

---

## 7. 504 Timeout During Large Operations

**Scenario:** Developer reports 504 Gateway Timeout during a large Claude Code refactoring task.

### Admin Diagnosis

```bash
# 1. Check LiteLLM logs — if no error, it's the ingress
kubectl logs deployment/litellm -n <namespace> --tail=100

# 2. Check ingress annotations
kubectl get ingress <litellm-ingress> -n <namespace> -o yaml | grep -A5 annotations

# 3. Fix if proxy-read-timeout is missing or low
kubectl annotate ingress <litellm-ingress> -n <namespace> \
  "nginx.ingress.kubernetes.io/proxy-read-timeout=3600" --overwrite

# 4. Verify
kubectl get ingress <litellm-ingress> -n <namespace> -o jsonpath='{.metadata.annotations}'
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 7.1 | Send long-running request (large context) | Completes without 504 | |
| 7.2 | Check ingress annotation | `proxy-read-timeout: 3600` present | |
| 7.3 | LiteLLM logs show no timeout error | Clean logs | |

---

## 8. Spend Auditing & Prompt Logging

**Scenario:** Manager asks "what are people using it for and how much?"

### Admin Steps

```bash
# 1. Overall team spend
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {team: .team_alias, spend, budget: .max_budget}'

# 2. Specific user's activity
curl -sk "$LITELLM_API_BASE/user/info?user_id=jsmith" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{
    user: .user_info.user_id,
    spend: .user_info.spend,
    keys: [.keys[]? | {alias: .key_alias, spend}]
  }'

# 3. Recent spend logs (with prompts if enabled)
curl -sk "$LITELLM_API_BASE/spend/logs?limit=10" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | {
    user: .user,
    model: .model,
    tokens: .total_tokens,
    cost: .spend,
    time: .startTime
  }'

# 4. Full prompts (if store_prompts_in_spend_logs is true)
curl -sk "$LITELLM_API_BASE/spend/logs?limit=1" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[0] | {request_body, response_body}'
```

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 8.1 | Team spend endpoint returns data | Spend values present | |
| 8.2 | User spend endpoint returns data | Per-key spend breakdown | |
| 8.3 | Spend logs return recent requests | Timestamps, models, tokens | |
| 8.4 | Prompt content logged (if enabled) | `request_body` is not null | |
| 8.5 | Logs older than 30 days auto-deleted | No entries beyond retention period | |

---

## 9. Admin Account Setup

**Scenario:** New team lead needs UI dashboard access.

### Admin Steps

```bash
# Use proxy_admin for full access, proxy_admin_viewer for read-only
./onboard-user.sh teamlead1 lead@company.com proxy_admin D102

# Important: proxy_admin counts toward SSO 5-user limit
# Only use for people who NEED the UI. Everyone else = internal_user.
```

### Developer Steps

1. Navigate to LiteLLM UI in browser
2. Log in via SSO or with provided credentials
3. Verify dashboard loads — teams, models, spend visible

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 9.1 | Onboard as proxy_admin | User created with admin role | |
| 9.2 | Log in to UI | Dashboard accessible | |
| 9.3 | View teams and spend | Data visible | |
| 9.4 | Check SSO user count | Under 5 admin/viewer users | |

---

## 10. Disaster Recovery — Database Wipe

**Scenario:** Database is lost or corrupted. LiteLLM needs to be rebuilt.

### What Survives
- ConfigMap settings and model_list (if models are in config, not just DB)
- Helm values / Terraform code
- Admin scripts and documentation (in Git)

### What's Lost
- All users, teams, keys
- All models added via UI/API
- Spend logs and audit trail

### Recovery Steps

1. Ensure new PostgreSQL is running and accessible
2. Update connection string in LiteLLM config/secrets
3. Redeploy LiteLLM (Helm upgrade or pod restart)
4. LiteLLM auto-creates tables on startup
5. Re-add models (via ConfigMap or curl)
6. Re-create teams
7. Bulk onboard users from backup CSV
8. Distribute new keys

### Mitigation
- Keep a CSV of current users/teams as backup
- Put critical models in ConfigMap (not just DB)
- Regular RDS snapshots

### Test Cases

| # | Test | Expected | Pass? |
|---|------|----------|-------|
| 10.1 | LiteLLM starts with fresh DB | Pod runs, tables created | |
| 10.2 | Models re-added | Available in `/models` | |
| 10.3 | Teams re-created | Present in `/team/list` | |
| 10.4 | Users bulk onboarded | All keys work | |

---

## Quick Smoke Test (Run After Any Change)

Run these after any deployment, upgrade, or config change:

```bash
# 1. Health check
curl -sk "$LITELLM_API_BASE/health" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .status

# 2. Models available
curl -sk "$LITELLM_API_BASE/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'

# 3. Test a completion
curl -sk -X POST "$LITELLM_API_BASE/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4.6","messages":[{"role":"user","content":"say ok"}],"max_tokens":5}'

# 4. Teams intact
curl -sk "$LITELLM_API_BASE/team/list" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.[] | .team_alias'
```

All 4 pass = you're good.
