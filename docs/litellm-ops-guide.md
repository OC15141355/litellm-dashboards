# LiteLLM Operations Guide

Helm upgrades, Terraform workflow, ConfigMap settings, and how they fit together.

---

## How It All Fits Together

```
┌─────────────────────────────────────────────┐
│  Terraform (future source of truth)         │
│  - Manages Helm release + K8s secrets       │
│  - terraform plan → terraform apply         │
│  - State stored in S3 backend               │
├─────────────────────────────────────────────┤
│  Helm (current deployment method)           │
│  - Chart: oci://ghcr.io/berriai/litellm-helm│
│  - Installed via Rancher / helm CLI         │
│  - Values = config, image tag, ingress, etc │
├─────────────────────────────────────────────┤
│  ConfigMap (litellm-config)                 │
│  - Runtime settings (general_settings, etc) │
│  - model_list (config-based models)         │
│  - Edited via kubectl or Helm values        │
├─────────────────────────────────────────────┤
│  Database (PostgreSQL)                      │
│  - Models added via UI/API                  │
│  - Users, teams, keys, spend logs           │
│  - Survives restarts and upgrades           │
└─────────────────────────────────────────────┘
```

**Key distinction:**
- **ConfigMap** = settings that load on startup (general_settings, litellm_settings, model_list)
- **Database** = runtime data managed via UI/API (users, teams, keys, models added through UI)
- **Helm values** = generates the ConfigMap + manages the deployment itself
- **Terraform** = wraps Helm into infrastructure-as-code (not yet active)

---

## Helm Upgrade

### Pre-flight Checks

```bash
# What's currently running?
helm list -n <namespace> | grep litellm

# Current image version
kubectl get deployment litellm -n <namespace> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Current values (save as backup)
helm get values litellm -n <namespace> > /tmp/litellm-values-backup.yaml
```

### Check Available Versions

The chart is OCI-based so `helm search` won't work. Check GitHub:

https://github.com/BerriAI/litellm/pkgs/container/litellm-helm

Or ask a teammate to check the tags list.

### Upgrade via Helm CLI

```bash
# Dry run first — always
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  -n <namespace> \
  --version <new-version> \
  --reuse-values \
  --dry-run

# If dry run looks clean, apply
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  -n <namespace> \
  --version <new-version> \
  --reuse-values
```

### Upgrade via Rancher

1. **Apps → Installed Apps → litellm → Upgrade**
2. Pick version from dropdown (if available)
3. Don't change values unless intentional
4. Hit Upgrade

> **Note:** Rancher may not show newer OCI chart versions. If the version you want isn't in the dropdown, use the Helm CLI method.

### Post-upgrade Checks

```bash
# Verify new version
helm list -n <namespace> | grep litellm

# Check pod is running
kubectl get pods -n <namespace> | grep litellm

# Check logs for errors
kubectl logs deployment/litellm -n <namespace> --tail=50

# Health check
curl -sk "$LITELLM_API_BASE/health" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .
```

### Rollback

If something breaks:

```bash
# See history
helm history litellm -n <namespace>

# Rollback to previous
helm rollback litellm <revision-number> -n <namespace>
```

---

## Terraform Workflow

Terraform wraps the Helm deployment into infrastructure-as-code. It doesn't replace Helm — it drives it.

### Directory Structure

```
terraform/
├── main.tf                    # Module declarations
├── variables.tf               # Variable definitions
├── outputs.tf                 # Output values
├── modules/
│   └── litellm/
│       ├── main.tf            # helm_release + kubernetes_secret
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── dev/
    │   ├── backend.tfvars     # S3 state bucket config
    │   └── terraform.tfvars   # Dev-specific values
    └── prod/
        ├── backend.tfvars
        └── terraform.tfvars
```

### Init (First Time / New Environment)

```bash
terraform init --backend-config=environments/dev/backend.tfvars
```

This connects to the S3 state backend. Required once per environment or when backend config changes.

### Plan (Preview Changes)

```bash
# Scoped to LiteLLM only
terraform plan \
  -var-file=environments/dev/terraform.tfvars \
  -target=module.litellm \
  -out=plan
```

**Read the plan output carefully:**
- `+` = create (new resource)
- `~` = update in-place (usually safe)
- `-` = destroy (dangerous)
- `-/+` = destroy and recreate (dangerous — causes downtime)

### Apply

```bash
terraform apply plan
```

Only run after reviewing the plan. Under the hood this runs `helm upgrade` with the values from your tfvars.

### Import Existing Resources

If LiteLLM was deployed manually and you're bringing it under Terraform:

```bash
# Import existing Helm release
terraform import \
  -var-file=environments/dev/terraform.tfvars \
  'module.litellm.helm_release.litellm_chart' \
  '<namespace>/litellm'

# Import existing K8s secret
terraform import \
  -var-file=environments/dev/terraform.tfvars \
  'module.litellm.kubernetes_secret_v1.litellm_secrets' \
  '<namespace>/litellm-secrets'
```

After import, run `terraform plan` — it should show minimal or no changes if the Terraform code matches what's deployed. If it shows destroy/recreate, **do not apply** until the code matches.

### Key Variables (tfvars)

```hcl
# environments/dev/terraform.tfvars
chart_version           = "1.81.9-stable"
litellm_aws_secret_name = "litellm-dev"
namespace               = "work-devops-tools"
# ... other env-specific values
```

### When to Use Terraform vs Helm Directly

| Action | Use |
|--------|-----|
| Full deployment from scratch | Terraform |
| Upgrade chart version | Terraform (change `chart_version` in tfvars) |
| Quick hotfix / emergency rollback | Helm CLI directly |
| Change Helm values | Terraform (update tfvars) |
| Add/remove models | LiteLLM API (not Terraform) |
| Manage users/teams/keys | LiteLLM API (not Terraform) |

### Important Warnings

- **Terraform validates ALL code** in the directory before plan/apply, even with `-target`. If another module (e.g. Keycloak) has errors, it'll fail. Comment out broken modules or fix them.
- **Don't mix Helm CLI changes with Terraform** — if you `helm upgrade` manually, Terraform state drifts. Next `terraform apply` may revert your manual changes.
- **`--reuse-values` is Helm-only** — Terraform always applies from tfvars. Make sure tfvars matches what's running before your first apply.

---

## ConfigMap Reference (litellm-config)

### Viewing Current Config

```bash
kubectl get configmap litellm-config -n <namespace> -o yaml
```

### Editing

```bash
kubectl edit configmap litellm-config -n <namespace>
```

After editing, restart the pod to pick up changes:

```bash
kubectl rollout restart deployment litellm -n <namespace>
```

### Config Structure

```yaml
model_list:
  # Models defined here load on startup (vs models added via UI stored in DB)
  - model_name: claude-sonnet-4.6
    litellm_params:
      model: au.anthropic.claude-sonnet-4-6
      custom_llm_provider: bedrock_converse
      aws_access_key_id: os.environ/AWS_ACCESS_KEY_ID
      aws_bedrock_runtime_endpoint: https://your-endpoint.amazonaws.com

general_settings:
  # See settings reference below

litellm_settings:
  # See settings reference below
```

> **Tip:** Use `os.environ/VARIABLE_NAME` to reference environment variables instead of hardcoding secrets in the ConfigMap.

### Useful general_settings

```yaml
general_settings:
  # --- Logging & Auditing ---
  store_prompts_in_spend_logs: true    # Log full request/response text (DB heavy!)
  disable_spend_logs: false            # Set true to stop all spend logging

  # --- Spend Log Retention ---
  maximum_spend_logs_retention_period: "30d"   # Auto-delete logs older than 30 days
  maximum_spend_logs_retention_interval: "1d"  # Cleanup runs daily

  # --- Request Limits ---
  max_parallel_requests: 0             # Per-deployment limit (0 = unlimited)
  global_max_parallel_requests: 0      # Proxy-wide limit (0 = unlimited)
  max_request_size_mb: 100             # Max request payload size

  # --- Database ---
  database_connection_pool_limit: 10   # Connections per worker (10-20 recommended)
  database_connection_timeout: 60      # Seconds before DB connection timeout
  allow_requests_on_db_unavailable: false  # Keep serving if DB goes down

  # --- Health ---
  background_health_checks: true       # Periodic model health checks
  health_check_interval: 300           # Seconds between checks

  # --- Security ---
  disable_master_key_return: true      # Don't echo master key in API responses
  enforce_user_param: false            # Require user_id on all requests

  # --- Alerting ---
  alerting: ["slack"]                  # Enable Slack alerts
  alerting_threshold: 300              # Alert if request takes >300s
```

### Useful litellm_settings

```yaml
litellm_settings:
  # --- Core ---
  drop_params: true                    # Strip unsupported params (REQUIRED for Bedrock)
  request_timeout: 6000                # Max seconds per LLM call

  # --- Logging ---
  json_logs: true                      # Structured JSON log output
  turn_off_message_logging: false      # Hide prompt content from logs (keeps metadata)

  # --- Reliability ---
  default_fallbacks: ["claude-sonnet"] # Fallback model if primary fails
  context_window_fallbacks:            # Use when token limit exceeded
    - claude-opus: ["claude-sonnet"]

  # --- Caching ---
  cache: true                          # Enable response caching
  cache_params:
    type: redis                        # redis, s3, or local
    host: redis.example.com
    port: 6379
    ttl: 3600                          # Cache expiry in seconds

  # --- Network ---
  force_ipv4: false                    # Force IPv4 for all LLM API calls

  # --- Routing ---
  routing_strategy: simple-shuffle     # simple-shuffle, least-busy, latency-based-routing
  num_retries: 2                       # Retry failed requests
  retry_policy:
    RateLimitError: 3
    ContentPolicyViolationError: 0     # Don't retry content violations
```

### Settings Quick Reference

| Setting | What It Does | When to Use |
|---------|-------------|-------------|
| `drop_params: true` | Strip unsupported API params | **Always** with Bedrock |
| `store_prompts_in_spend_logs` | Log full prompts/responses | Auditing (warning: DB heavy) |
| `maximum_spend_logs_retention_period` | Auto-delete old logs | When prompt logging is on |
| `json_logs: true` | Structured log output | If shipping to log aggregator |
| `turn_off_message_logging` | Redact prompts from logs | Privacy without losing metadata |
| `background_health_checks` | Periodic model pings | Production |
| `default_fallbacks` | Backup models | Production reliability |
| `disable_master_key_return` | Don't expose master key | Security hardening |
| `request_timeout` | Max call duration | Prevent hung requests |
| `database_connection_pool_limit` | DB connection pool size | Tune if seeing DB timeouts |

---

## Adding Models

### Via UI (Preferred)
Best for models the dropdown supports. Sets all fields correctly.

### Via API (When UI Doesn't Have the Model)

```bash
curl -sk -X POST "$LITELLM_API_BASE/model/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "claude-sonnet-4.6",
    "litellm_params": {
      "model": "au.anthropic.claude-sonnet-4-6",
      "custom_llm_provider": "bedrock_converse",
      "aws_access_key_id": "YOUR_KEY",
      "aws_bedrock_runtime_endpoint": "https://your-endpoint.amazonaws.com"
    }
  }'
```

> **Critical:** For Bedrock models, `custom_llm_provider` must be `bedrock_converse` (not `bedrock`). This is what the UI sets behind the scenes. Without it, the model will fail health checks and disappear.

### Via ConfigMap (Startup-loaded)

Add to `model_list` in the ConfigMap. Useful for models that keep disappearing when added via API.

### Provider Reference

| Cloud Provider | `custom_llm_provider` | Model Prefix Example |
|---|---|---|
| AWS Bedrock (Claude) | `bedrock_converse` | `au.anthropic.claude-sonnet-4-6` |
| Azure OpenAI (GPT) | `azure` | `gpt-4o` |
| OpenAI Direct | `openai` | `gpt-4o` |
| Google Vertex AI | `vertex_ai` | `gemini-pro` |
| Anthropic Direct | `anthropic` | `claude-sonnet-4-6` |

---

## Common Operations

### Restart (No Config Change)

```bash
kubectl rollout restart deployment litellm -n <namespace>
```

Or in Rancher: scale to 0, then back to 1.

### Check Current Config

```bash
kubectl get configmap litellm-config -n <namespace> -o yaml
```

### Check Logs

```bash
kubectl logs deployment/litellm -n <namespace> --tail=100
```

### Emergency Rollback (Helm)

```bash
helm history litellm -n <namespace>
helm rollback litellm <revision> -n <namespace>
```

### 504 Timeout Fix

```bash
kubectl annotate ingress <litellm-ingress> -n <namespace> \
  "nginx.ingress.kubernetes.io/proxy-read-timeout=3600" --overwrite
```

---

## Sources

- [LiteLLM All Settings](https://docs.litellm.ai/docs/proxy/config_settings)
- [LiteLLM Config Overview](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM Production Best Practices](https://docs.litellm.ai/docs/proxy/prod)
- [LiteLLM Deploy (Docker, Helm, Terraform)](https://docs.litellm.ai/docs/proxy/deploy)
