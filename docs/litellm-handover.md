# LiteLLM Handover — Things You Need to Know

Everything that isn't obvious, learned the hard way. Read this before touching anything.

---

## Architecture

```
Users (Claude Code / API)
  → Ingress (nginx)
    → LiteLLM Proxy (K8s deployment)
      → AWS Bedrock (Claude models)

Config sources:
  - ConfigMap (litellm-config) → startup settings, model_list
  - PostgreSQL (RDS)           → users, teams, keys, models added via UI/API, spend logs
  - Helm values                → deployment config, image tag, ingress, env vars
  - Terraform (future)         → wraps Helm + secrets into IaC
```

---

## Terraform

### Current State
- Terraform code exists but was migrated from an existing Helm deployment
- State backend: S3 + DynamoDB (see `environments/*/backend.tfvars`)
- Existing resources were imported via `terraform import`
- **Do not blindly `terraform apply`** — always `plan` first and read the diff

### Key Files
```
terraform/
├── main.tf                         # Root module declarations
├── variables.tf                    # Variable definitions
├── modules/litellm/                # LiteLLM Helm release + secrets
├── modules/launchpad_keycloak/     # Keycloak (separate, can cause issues)
└── environments/
    ├── dev/
    │   ├── backend.tfvars          # S3 state config
    │   └── terraform.tfvars        # Dev values (chart_version, secret name, etc.)
    └── prod/
        ├── backend.tfvars
        └── terraform.tfvars
```

### Common Commands
```bash
# Init (required once per environment or after backend changes)
terraform init --backend-config=environments/dev/backend.tfvars

# Plan (always scope to litellm)
terraform plan \
  -var-file=environments/dev/terraform.tfvars \
  -target=module.litellm \
  -out=plan

# Apply
terraform apply plan
```

### Gotchas

- **Terraform validates ALL modules** even with `-target`. If `modules/launchpad_keycloak/` has errors, your LiteLLM plan will fail. Comment out broken modules if needed.
- **`chart_version` in tfvars must match what's deployed.** If someone Helm-upgraded manually and didn't update tfvars, Terraform will try to downgrade. Always check `helm list -n <namespace>` first.
- **Don't mix Helm CLI and Terraform.** If you `helm upgrade` manually, Terraform state drifts. Next `terraform apply` may revert your changes. Pick one.
- **Variables without defaults will prompt interactively.** If `terraform plan` asks you for values, add them to the tfvars file so the next person doesn't have to guess.
- **PostgreSQL provider** in Terraform needs network access to the DB. If running locally, you may need VPN, port-forward, or `/etc/hosts` entry.
- **`terraform plan` showing destroy+recreate on the Helm release?** That means tfvars don't match live state. Do NOT apply — reconcile first.

### Import Commands (Reference)
If you ever need to re-import:
```bash
terraform import -var-file=environments/dev/terraform.tfvars \
  'module.litellm.helm_release.litellm_chart' '<namespace>/litellm'

terraform import -var-file=environments/dev/terraform.tfvars \
  'module.litellm.kubernetes_secret_v1.litellm_secrets' '<namespace>/litellm-secrets'
```

---

## Bedrock Model Configuration

### The `bedrock_converse` Gotcha
This caused hours of debugging. When adding models via API/curl:

- `custom_llm_provider` **must** be `"bedrock_converse"` (not `"bedrock"`)
- The UI sets this automatically — curl does not
- Without it, models fail health checks and **silently disappear** from LiteLLM

**Working curl:**
```bash
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

### Model ID Formats
- `au.` prefix = cross-region inference profile (Australia). Used for all our models.
- Base model IDs (from `aws bedrock list-foundation-models`) don't have `au.`
- Some models have `:0` or `-v1:0` suffix, some don't. Check existing working models and match exactly.
- New models (e.g. Sonnet 4.6 released Feb 2026) may not appear in LiteLLM's UI dropdown until LiteLLM is upgraded. Use the curl method above.

### Current Models
| Model Name | Bedrock ID |
|---|---|
| claude-opus | au.anthropic.claude-opus-4-6-v1 |
| claude-sonnet | au.anthropic.claude-sonnet-4-5-20250929-v1:0 |
| claude-sonnet-4.6 | au.anthropic.claude-sonnet-4-6 |

### Where Models Live
- **UI/API-added models** → stored in PostgreSQL, managed at runtime
- **ConfigMap models** → `model_list` in litellm-config, loaded on startup
- **Don't duplicate** the same model in both — you'll get load-balancing between two identical entries

---

## LiteLLM Quirks

### Orphan Keys
`/user/new` auto-generates a key not attributed to any team. If you don't delete it, orphan keys accumulate. **Always use the onboard script** or clean up manually.

### Health Checks Delete Models
If `background_health_checks: true`, LiteLLM periodically tests models. If a model fails (wrong credentials, wrong provider, etc.), it can be **silently removed**. Check logs if a model disappears.

### SSO 5-User Limit (Free Tier)
- `proxy_admin` and `proxy_admin_viewer` count toward the 5-user SSO cap
- `internal_user` and `internal_user_viewer` **bypass** this limit
- Use `internal_user` for developers who only need API keys (Claude Code users)
- Reserve `proxy_admin` for people who actually need the UI dashboard

### Team Model Updates (Free Tier)
- You can set models when **creating** a team
- **Updating** team models via the UI may be blocked (enterprise feature)
- The API `/team/update` endpoint works — use `update-team-models.sh` or curl

### Invitation Links Are Reusable
Security finding — invitation links generated by LiteLLM can be used multiple times. Be aware when sharing.

---

## ConfigMap (litellm-config)

### Recommended Production Config
```yaml
general_settings:
  store_prompts_in_spend_logs: true
  maximum_spend_logs_retention_period: "30d"
  maximum_spend_logs_retention_interval: "1d"
  disable_master_key_return: true
  database_connection_pool_limit: 10
  background_health_checks: true
  health_check_interval: 300

litellm_settings:
  drop_params: true
  request_timeout: 3600
  json_logs: true
  num_retries: 2
```

### Key Settings Explained

| Setting | Why It Matters |
|---------|---------------|
| `drop_params: true` | **Required for Bedrock.** Strips `anthropic-beta` headers that Bedrock doesn't support. Without this, Claude Code gets 400 errors. |
| `request_timeout: 3600` | Prevents LiteLLM from timing out on large refactoring tasks. Default is 6000s but the **ingress** defaults to 60s (see below). |
| `store_prompts_in_spend_logs` | Logs full prompts/responses to PostgreSQL. Useful for auditing but grows the DB fast. Use with retention period. |
| `maximum_spend_logs_retention_period` | Auto-deletes old spend logs. "30d" = 30 days. This is the TTL. |
| `disable_master_key_return` | Don't echo the master key in API responses. Security hardening. |
| `json_logs` | Structured logging. Useful if shipping to a log aggregator. |
| `background_health_checks` | Periodic model health pings. Good for production but can auto-remove misconfigured models. |

### Editing the ConfigMap
```bash
kubectl edit configmap litellm-config -n <namespace>
# Then restart:
kubectl rollout restart deployment litellm -n <namespace>
```

Config changes require a pod restart — they're read on startup, not hot-reloaded.

---

## Ingress / 504 Timeouts

The #1 support request. Users will report "504 Gateway Timeout" on large Claude Code operations.

**Root cause:** nginx ingress default `proxy-read-timeout` is 60 seconds. Large refactoring prompts take longer.

**NOT LiteLLM's fault.** LiteLLM defaults to 6000s timeout. The request dies at the ingress before LiteLLM even times out. Clue: LiteLLM logs show **no error** for a 504.

**Fix:**
```bash
kubectl annotate ingress <litellm-ingress> -n <namespace> \
  "nginx.ingress.kubernetes.io/proxy-read-timeout=3600" --overwrite
```

Or in Helm values:
```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
```

**Watch for typos** — `kuberenetes` instead of `kubernetes` in the annotation will silently do nothing.

---

## Claude Code Integration

### Required Environment Variables
```json
{
  "ANTHROPIC_BASE_URL": "https://litellm.dev.your-domain.com",
  "ANTHROPIC_AUTH_TOKEN": "sk-virtual-key",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4.6",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4.6",
  "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
}
```

### Key Points
- **`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`** is required. Without it, Claude Code sends `anthropic-beta` headers that Bedrock rejects with 400 errors. `drop_params` alone is not enough — it only strips body params, not headers.
- **All 3 model tiers must be set.** Claude Code uses Sonnet (default), Opus (manual selection), and Haiku (internal subtasks). If Haiku isn't configured, it errors silently in the background. Map Haiku to Sonnet if you don't have a Haiku model.
- **Claude Code only speaks Anthropic Messages API.** It cannot use GPT models even through LiteLLM translation. Don't try to route GPT models through it.
- **VS Code extension config** goes in `claudeCode.environmentVariables` in settings.json
- **CLI config** goes in `~/.claude/settings.json` under `env`
- **Old CLI versions** (pre-2.2) don't read settings.json properly. Ensure `npm install -g @anthropic-ai/claude-code@latest`

---

## Helm Upgrades

### Process
```bash
# 1. Backup current values
helm get values litellm -n <namespace> > /tmp/litellm-values-backup.yaml

# 2. Dry run
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  -n <namespace> --version <new-version> --reuse-values --dry-run

# 3. Apply
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  -n <namespace> --version <new-version> --reuse-values

# 4. Verify
kubectl get pods -n <namespace> | grep litellm
kubectl logs deployment/litellm -n <namespace> --tail=20

# 5. Update Terraform tfvars if applicable
# chart_version = "<new-version>"
```

### Gotchas
- OCI charts don't show in `helm search repo`. Check versions at https://github.com/BerriAI/litellm/pkgs/container/litellm-helm
- Rancher may not show newer OCI versions in its upgrade dropdown. Use Helm CLI.
- `--reuse-values` keeps current config. Without it, you'll reset to chart defaults.
- After Helm upgrade, update `chart_version` in Terraform tfvars or next `terraform apply` will downgrade.

### Rollback
```bash
helm history litellm -n <namespace>
helm rollback litellm <revision> -n <namespace>
```

---

## Database

- **PostgreSQL on RDS** — stores users, teams, keys, spend logs, UI-added models
- **LiteLLM is stateless** — the pod itself holds nothing. All state is in the DB. You can delete and recreate the pod freely.
- **DB wipe = start over.** All users, teams, keys, models added via UI are lost. ConfigMap models and settings survive.
- **Spend logs grow fast** with `store_prompts_in_spend_logs: true`. Set `maximum_spend_logs_retention_period` or monitor disk.
- **Migration job:** When upgrading LiteLLM versions, check if `migrationJob.enabled: true` is needed in Helm values. New versions may require DB schema migrations.

### Useful Queries
```sql
-- Find orphaned keys
SELECT token, key_alias, user_id
FROM "LiteLLM_VerificationToken"
WHERE user_id NOT IN (SELECT user_id FROM "LiteLLM_UserTable");

-- Check spend log size
SELECT pg_size_pretty(pg_total_relation_size('"LiteLLM_SpendLogs"'));

-- Delete old spend logs manually
DELETE FROM "LiteLLM_SpendLogs" WHERE "startTime" < NOW() - INTERVAL '30 days';

-- SSO users that won't delete via API
DELETE FROM "LiteLLM_VerificationToken" WHERE user_id = 'the-user-id';
DELETE FROM "LiteLLM_UserTable" WHERE user_id = 'the-user-id';
```

---

## Admin Scripts

All in `admin-scripts/`. Set `LITELLM_API_BASE` and `LITELLM_MASTER_KEY` env vars or scripts will prompt.

| Script | Purpose |
|--------|---------|
| `litellm-admin.sh` | Full CLI tool (all operations) |
| `onboard-user.sh` | Create user + team + clean key |
| `offboard-user.sh` | Remove user + keys + teams |
| `rotate-key.sh` | Delete old keys, generate new |
| `bulk-onboard.sh` | Onboard from CSV |
| `update-team-models.sh` | Interactive team model assignment |

See `docs/litellm-admin-quickref.md` for usage + curl equivalents.

---

## Cost Tracking

- LiteLLM tracks spend per user/team/key using **default public pricing** (not your Bedrock contracted rates)
- There will be a discrepancy between LiteLLM-reported spend and your AWS bill
- Cache hits, prompt caching, and volume discounts are not reflected
- Treat LiteLLM spend as **relative usage tracking**, not actual cost

---

## Quick Diagnostic Checklist

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| 400 "invalid beta flag" | Missing `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` or `drop_params: true` | Set both |
| 401 "team doesn't have access" | Team model permissions | Update team models |
| 504 Gateway Timeout | Nginx ingress 60s default | Set `proxy-read-timeout: 3600` |
| Model disappears after adding | Wrong `custom_llm_provider` or failed health check | Use `bedrock_converse`, check logs |
| "LLM provider not provided" | Missing `custom_llm_provider` in model config | Set to `bedrock_converse` |
| Orphaned keys accumulating | Using `/user/new` without cleanup | Use onboard script |
| SSO user won't delete | LiteLLM API limitation | Delete directly from DB |
| Haiku errors in logs | No Haiku model configured | Map Haiku env var to Sonnet |
| Can't update team models in UI | Free tier enterprise gate | Use API/script instead |
| `terraform plan` wants to downgrade | `chart_version` in tfvars is outdated | Update tfvars |
