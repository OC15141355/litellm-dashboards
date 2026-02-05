# LiteLLM Proxy Deployment Guide

> **Version**: 1.81.0 | **Chart**: ghcr.io/berriai/litellm-helm:0.1.837
> **Last Updated**: February 2026

LiteLLM is a unified API gateway that provides OpenAI-compatible endpoints for multiple LLM providers. This guide covers the complete deployment, configuration, and operation of LiteLLM in both homelab and enterprise environments.

## Table of Contents

- [Architecture](#architecture)
- [Homelab Deployment](#homelab-deployment)
- [Corporate/Enterprise Deployment](#corporateenterprise-deployment)
- [Configuration Reference](#configuration-reference)
- [Prometheus Metrics](#prometheus-metrics)
- [API Usage](#api-usage)
- [AI Agent Integration](#ai-agent-integration)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Runbooks](#runbooks)

---

## Architecture

### Homelab Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          RKE2 Kubernetes Cluster                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         litellm namespace                            │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐ │   │
│  │  │   LiteLLM   │◄───│   Service   │◄───│   Ingress (nginx)       │ │   │
│  │  │   Pod       │    │  :4000/TCP  │    │   litellm.homelab       │ │   │
│  │  └──────┬──────┘    └─────────────┘    └─────────────────────────┘ │   │
│  │         │                                                           │   │
│  │         │ ┌─────────────────┐  ┌─────────────────┐                 │   │
│  │         ├─│ litellm-secrets │  │ ConfigMap       │                 │   │
│  │         │ │ (SOPS encrypted)│  │ (proxy_config)  │                 │   │
│  │         │ └─────────────────┘  └─────────────────┘                 │   │
│  │         │                                                           │   │
│  │         ▼                                                           │   │
│  │  ┌─────────────────┐                                               │   │
│  │  │ ServiceMonitor  │──────────────────────────────────────────┐    │   │
│  │  │ /metrics/       │                                          │    │   │
│  │  └─────────────────┘                                          │    │   │
│  └───────────────────────────────────────────────────────────────│────┘   │
│                                                                   │        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                       monitoring namespace                      │    │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │    │   │
│  │  │ Prometheus  │◄───│ServiceMonit.│    │      Grafana        │ │◄───┘   │
│  │  │             │    │  Discovery  │    │  grafana.homelab    │ │        │
│  │  └─────────────┘    └─────────────┘    └─────────────────────┘ │        │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
         │                                              │
         ▼                                              ▼
┌─────────────────────┐                    ┌─────────────────────┐
│   PostgreSQL        │                    │   Ollama Server     │
│   docker-01 VM      │                    │   192.168.0.92      │
│   192.168.0.21:5432 │                    │   :11434            │
└─────────────────────┘                    └─────────────────────┘
```

### Data Flow

1. **Client Request** → Ingress (litellm.homelab) → LiteLLM Service → Pod
2. **LiteLLM** authenticates via `LITELLM_MASTER_KEY`
3. **LiteLLM** routes to configured model backend (Ollama, OpenAI, etc.)
4. **Response** flows back through the same path
5. **Metrics** scraped by Prometheus via ServiceMonitor at `/metrics/`

---

## Homelab Deployment

### Prerequisites

- RKE2 Kubernetes cluster (1.25+)
- Argo CD installed with SOPS plugin configured
- PostgreSQL database (external or in-cluster)
- Ollama or other LLM backend
- age keypair for SOPS encryption

### Directory Structure

```
homelab-k8s/
├── apps/litellm/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   └── ingress.yaml
│   ├── secrets/
│   │   ├── kustomization.yaml
│   │   └── secrets.yaml          # SOPS encrypted
│   └── values.yaml               # Helm values
├── argocd/
│   ├── app-litellm.yaml          # Main Helm Application
│   └── app-litellm-secrets.yaml  # SOPS secrets Application
```

### Step 1: Create Secrets (SOPS Encrypted)

```bash
# Create plaintext secrets file
cat > apps/litellm/secrets/secrets.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: litellm
type: Opaque
stringData:
  DATABASE_USERNAME: litellm
  DATABASE_PASSWORD: your-secure-password
  DATABASE_URL: postgresql://litellm:your-secure-password@192.168.0.21:5432/litellm
  LITELLM_MASTER_KEY: sk-your-master-key-here
  UI_USERNAME: admin
  UI_PASSWORD: your-ui-password
EOF

# Encrypt with SOPS
sops --encrypt --in-place apps/litellm/secrets/secrets.yaml
```

### Step 2: Configure Helm Values

```yaml
# apps/litellm/values.yaml
image:
  repository: ghcr.io/berriai/litellm-database
  pullPolicy: Always
  tag: "main-stable"

replicaCount: 1

# Use existing SOPS-managed secrets
masterkeySecretName: litellm-secrets
masterkeySecretKey: LITELLM_MASTER_KEY

# External PostgreSQL
db:
  useExisting: true
  endpoint: 192.168.0.21
  database: litellm
  secret:
    name: litellm-secrets
    usernameKey: DATABASE_USERNAME
    passwordKey: DATABASE_PASSWORD

# Disable bundled PostgreSQL
postgresql:
  enabled: false

# Disable migrations (run manually or handled externally)
migrationJob:
  enabled: false

# Model routing configuration
proxy_config:
  model_list:
    - model_name: qwen-local
      litellm_params:
        model: ollama_chat/qwen2.5:7b-instruct
        api_base: http://192.168.0.92:11434
  litellm_settings:
    callbacks:
      - prometheus    # REQUIRED for /metrics/ endpoint
  general_settings:
    master_key: os.environ/LITELLM_MASTER_KEY
    database_url: os.environ/DATABASE_URL

# Prometheus metrics
serviceMonitor:
  enabled: true
  interval: 30s
  scrapeTimeout: 10s
  path: /metrics/     # NOTE: trailing slash required

# Pod annotations (fallback scraping)
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "4000"
  prometheus.io/path: "/metrics/"

environmentSecrets:
  - litellm-secrets
```

### Step 3: Create Argo CD Applications

**Secrets Application** (deploys first via sync-wave):
```yaml
# argocd/app-litellm-secrets.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: litellm-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: git@github.com:YOUR_ORG/homelab-k8s.git
    targetRevision: main
    path: apps/litellm/secrets
    plugin:
      name: sops-kustomize
  destination:
    server: https://kubernetes.default.svc
    namespace: litellm
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Main Application** (Helm deployment):
```yaml
# argocd/app-litellm.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: litellm
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: git@github.com:YOUR_ORG/homelab-k8s.git
      targetRevision: main
      path: apps/litellm/base
    - repoURL: ghcr.io/berriai
      chart: litellm-helm
      targetRevision: 0.1.837
      helm:
        releaseName: litellm
        valueFiles:
          - $values/apps/litellm/values.yaml
    - repoURL: git@github.com:YOUR_ORG/homelab-k8s.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: litellm
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
      - ServerSideApply=true
```

### Step 4: Deploy

```bash
# Push to Git (triggers Argo CD sync)
git add -A && git commit -m "feat(litellm): initial deployment" && git push

# Or manually apply
kubectl apply -f argocd/app-litellm-secrets.yaml
kubectl apply -f argocd/app-litellm.yaml

# Monitor deployment
watch kubectl get applications -n argocd
```

### Step 5: Verify Deployment

```bash
# Check pods
kubectl get pods -n litellm

# Check health
curl -s https://litellm.homelab/health/readiness

# Expected output:
# {"status":"connected","db":"connected","litellm_version":"1.81.0",...}

# Test API
curl -s https://litellm.homelab/v1/models \
  -H "Authorization: Bearer sk-your-master-key"
```

---

## Corporate/Enterprise Deployment

### Key Differences from Homelab

| Aspect | Homelab | Corporate |
|--------|---------|-----------|
| **Database** | Docker VM PostgreSQL | AWS RDS / Azure SQL |
| **Secrets** | SOPS + age | AWS Secrets Manager / Vault |
| **Ingress** | nginx (self-signed) | ALB / API Gateway (ACM certs) |
| **LLM Backend** | Ollama (local) | AWS Bedrock / OpenAI API |
| **Auth** | Master key | OIDC / SSO integration |
| **Replicas** | 1 | 2+ (HA) |
| **Monitoring** | Self-hosted Prometheus | CloudWatch / Datadog |

### AWS Example Configuration

```yaml
# values-aws.yaml
replicaCount: 2

db:
  useExisting: true
  endpoint: litellm-db.xxxxx.us-east-1.rds.amazonaws.com
  database: litellm
  secret:
    name: litellm-secrets
    usernameKey: DB_USER
    passwordKey: DB_PASSWORD

postgresql:
  enabled: false

proxy_config:
  model_list:
    - model_name: claude-3-sonnet
      litellm_params:
        model: bedrock/anthropic.claude-3-sonnet-20240229-v1:0
        aws_region_name: us-east-1
    - model_name: gpt-4-turbo
      litellm_params:
        model: openai/gpt-4-turbo
        api_key: os.environ/OPENAI_API_KEY
  litellm_settings:
    callbacks:
      - prometheus
  general_settings:
    master_key: os.environ/LITELLM_MASTER_KEY
    database_url: os.environ/DATABASE_URL

ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
  hosts:
    - host: litellm.internal.company.com
      paths:
        - path: /
          pathType: Prefix

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```

---

## Configuration Reference

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `LITELLM_MASTER_KEY` | Yes | API authentication key (format: `sk-*`) |
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `UI_USERNAME` | No | Admin UI username |
| `UI_PASSWORD` | No | Admin UI password |
| `OPENAI_API_KEY` | No | OpenAI API key (if using OpenAI models) |
| `ANTHROPIC_API_KEY` | No | Anthropic API key (if using Claude) |
| `DOCS_URL` | No | Set to `""` to disable `/docs` FastAPI swagger UI |
| `REDOC_URL` | No | Set to `""` to disable `/redoc` ReDoc documentation |
| `PROXY_BASE_URL` | No | Required for SSO - the external URL of LiteLLM (e.g., `https://litellm.homelab`) |

### SSO Environment Variables (Keycloak/OIDC)

| Variable | Description |
|----------|-------------|
| `GENERIC_CLIENT_ID` | OIDC client ID from Keycloak |
| `GENERIC_CLIENT_SECRET` | OIDC client secret from Keycloak |
| `GENERIC_AUTHORIZATION_ENDPOINT` | `https://<keycloak>/realms/<realm>/protocol/openid-connect/auth` |
| `GENERIC_TOKEN_ENDPOINT` | `https://<keycloak>/realms/<realm>/protocol/openid-connect/token` |
| `GENERIC_USERINFO_ENDPOINT` | `https://<keycloak>/realms/<realm>/protocol/openid-connect/userinfo` |
| `GENERIC_SCOPE` | OIDC scopes (default: `openid profile email`) |
| `GENERIC_USER_ID_ATTRIBUTE` | Claim for user ID (default: `preferred_username`) |
| `GENERIC_USER_EMAIL_ATTRIBUTE` | Claim for email (default: `email`) |

### Model Configuration

```yaml
proxy_config:
  model_list:
    # Local Ollama
    - model_name: local-llama
      litellm_params:
        model: ollama_chat/llama2:7b
        api_base: http://ollama-server:11434

    # OpenAI
    - model_name: gpt-4
      litellm_params:
        model: openai/gpt-4-turbo
        api_key: os.environ/OPENAI_API_KEY

    # Anthropic
    - model_name: claude-3
      litellm_params:
        model: anthropic/claude-3-opus-20240229
        api_key: os.environ/ANTHROPIC_API_KEY

    # AWS Bedrock
    - model_name: bedrock-claude
      litellm_params:
        model: bedrock/anthropic.claude-3-sonnet-20240229-v1:0
        aws_region_name: us-east-1

    # Azure OpenAI
    - model_name: azure-gpt4
      litellm_params:
        model: azure/gpt-4-deployment
        api_base: https://your-resource.openai.azure.com/
        api_key: os.environ/AZURE_API_KEY
        api_version: "2024-02-15-preview"
```

### Callbacks Configuration

```yaml
litellm_settings:
  callbacks:
    - prometheus           # Enable /metrics/ endpoint
    - langfuse            # Optional: LLM observability
    - custom_callback     # Optional: Custom webhook

  # Optional: Selective metrics
  prometheus_metrics_config:
    - group: "deployment_health"
      metrics:
        - "litellm_deployment_success_responses"
        - "litellm_deployment_failure_responses"
    - group: "performance"
      metrics:
        - "litellm_request_total_latency_metric"
```

---

## Prometheus Metrics

### Enabling Metrics

**IMPORTANT**: Metrics require the prometheus callback:

```yaml
litellm_settings:
  callbacks:
    - prometheus
```

**IMPORTANT**: The metrics endpoint uses a trailing slash: `/metrics/`

### Available Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `litellm_proxy_total_requests_metric_total` | Counter | Total requests to proxy |
| `litellm_proxy_failed_requests_metric_total` | Counter | Failed requests |
| `litellm_deployment_success_responses` | Counter | Successful model responses |
| `litellm_deployment_failure_responses` | Counter | Failed model responses |
| `litellm_request_total_latency_metric` | Histogram | End-to-end latency |
| `litellm_llm_api_latency_metric` | Histogram | LLM API call latency |
| `process_resident_memory_bytes` | Gauge | Memory usage |
| `python_gc_objects_collected_total` | Counter | GC statistics |

### Grafana Dashboards

Three dashboards are included in `apps/litellm/`:

| Dashboard | File | Audience | Purpose |
|-----------|------|----------|---------|
| **Operations & FinOps** | `grafana-dashboard.json` | Platform team | Overall system health, costs, budgets |
| **Team View** | `grafana-dashboard-team.json` | Team leads | Per-team spend, usage, performance |
| **Model Comparison** | `grafana-dashboard-models.json` | Developers | Compare models on cost, latency, reliability |

**Import to Grafana:**
1. Open Grafana → Dashboards → Import
2. Upload JSON file or paste contents
3. Select your Prometheus data source
4. Click Import

---

#### Dashboard 1: Operations & FinOps

**Audience:** Platform/SRE team

| Section | Panels | Use Case |
|---------|--------|----------|
| **Overview** | Total Requests, Spend, Tokens, Error Rate | Quick health check |
| **Operations/SRE** | Request rate, Latency (p50/p95/p99), TTFT, Success/Failure, Overhead | Performance monitoring |
| **FinOps** | Spend by API Key, Spend by Model, Token Usage, Spend Distribution | Cost tracking |
| **Budget Tracking** | Remaining Team/Key Budgets, Budget Reset Timers | Budget enforcement |
| **Cache & Efficiency** | Cache Hit Rate, Cached Tokens | Optimization insights |

---

#### Dashboard 2: Team View (Customer-Facing)

**Audience:** Team leads, chargeback visibility

**Features:**
- **Team selector dropdown** - filter all panels by team
- Budget gauge with remaining/max and reset timer
- Spend vs budget trend line
- Usage breakdown by model and API key
- Team-specific latency and error rates

**Sections:**
| Section | What it shows |
|---------|---------------|
| **Team Overview** | Total spend, requests, tokens, budget remaining |
| **Spend & Usage** | Spend by model, requests over time, token breakdown |
| **Performance** | Latency, TTFT, error rate for the team's requests |
| **API Keys** | Table of usage per API key within the team |

> **Use Case:** Share with team leads so they can see their consumption without platform team involvement.

---

#### Dashboard 3: Model Comparison

**Audience:** Developers choosing which model to use

**Features:**
- Side-by-side bar charts for cost, latency, success rate
- Model health status indicators
- Fallback and cooldown event tracking
- Summary comparison table

**Sections:**
| Section | What it shows |
|---------|---------------|
| **Overview** | Cost per 1K tokens, median latency, success rate (bar charts) |
| **Latency** | P95 latency, TTFT, latency per output token, p50 vs p99 distribution |
| **Cost & Usage** | Spend over time, request distribution, token distribution |
| **Reliability** | Error rate, deployment health status, fallback attempts, cooldowns |
| **Summary Table** | All models compared: requests, spend, cost/1K tokens, latency |

> **Use Case:** "Which model should I use?" - helps developers pick cost-effective models for their use case.

---

#### Setup Guide

**Prerequisites:**
1. Prometheus scraping LiteLLM's `/metrics/` endpoint (via ServiceMonitor or pod annotations)
2. Grafana with Prometheus configured as a data source

**Step 1: Verify Prometheus is scraping LiteLLM**

```bash
# Check metrics are available
curl -s "https://litellm.dev.work.com/metrics/" | head -20

# In Prometheus UI, query:
litellm_requests_metric_total
```

**Step 2: Import dashboards into Grafana**

```bash
# Dashboard files in the repo:
apps/litellm/grafana-dashboard.json        # Operations & FinOps
apps/litellm/grafana-dashboard-team.json   # Team View
apps/litellm/grafana-dashboard-models.json # Model Comparison
```

1. Open Grafana → **Dashboards** → **Import**
2. Click **Upload JSON file** or paste the JSON contents
3. Select your **Prometheus data source** from the dropdown
4. Click **Import**
5. Repeat for each dashboard

**Step 3: Verify data is flowing**

After import, panels should populate within the scrape interval (default: 30s). If panels show "No data":
- Check time range (top right) - try "Last 1 hour"
- Verify Prometheus data source is correct
- Check Prometheus is scraping: `up{job="litellm"}`

---

#### How to Use the Dashboards

| Dashboard | How to Use |
|-----------|------------|
| **Operations & FinOps** | Open and set time range. Shows global view of all teams, models, spend. Use for daily platform monitoring. |
| **Team View** | Select a team from the **Team** dropdown at top. All panels filter to that team. Share the URL with team leads. |
| **Model Comparison** | Open and view - shows all models side-by-side. No filters needed. Use when choosing which model to recommend. |

**Time Ranges:**
- Operations dashboard defaults to **24 hours**
- Team and Model dashboards default to **7 days**
- Adjust using the time picker (top right)

**Sharing with Team Leads:**

Option 1: **Direct link**
- Navigate to Team View dashboard
- Select their team from dropdown
- Copy URL (includes team parameter)
- Share the link

Option 2: **Grafana Viewer role**
- Create Grafana users with Viewer role
- They can view but not edit dashboards
- Set Team View as their home dashboard

Option 3: **Dashboard snapshots**
- Dashboard → Share → Snapshot
- Creates a point-in-time snapshot
- Can be shared without Grafana login

---

**Key Metrics Visualized:**

| Metric | Description |
|--------|-------------|
| `litellm_requests_metric_total` | Total LLM requests (by model, key) |
| `litellm_spend_metric_total` | Spend in USD (by model, key) |
| `litellm_request_total_latency_metric` | End-to-end request latency |
| `litellm_llm_api_time_to_first_token_metric` | Time to first token (TTFT) |
| `litellm_deployment_success_responses_total` | Successful model calls |
| `litellm_deployment_failure_responses_total` | Failed model calls |
| `litellm_remaining_team_budget_metric` | Remaining budget per team |
| `litellm_cache_hits_metric_total` | Cache hit count |

**Sample PromQL Queries:**

```promql
# Request rate
rate(litellm_proxy_total_requests_metric_total[5m])

# Error rate
rate(litellm_proxy_failed_requests_metric_total[5m])
  / rate(litellm_proxy_total_requests_metric_total[5m])

# P95 latency
histogram_quantile(0.95, rate(litellm_request_total_latency_metric_bucket[5m]))

# Memory usage
process_resident_memory_bytes{job="litellm"}
```

### ServiceMonitor Configuration

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: litellm
  namespace: litellm
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: litellm
  endpoints:
    - port: http
      path: /metrics/      # Trailing slash required!
      interval: 30s
      scrapeTimeout: 10s
```

---

## Logging & Audit

### Current Implementation

| Feature | Status | Notes |
|---------|--------|-------|
| JSON structured logging | ✅ Enabled | `json_logs: true` in config |
| Audit log storage | ✅ Enabled | `store_audit_logs: true` |
| CloudWatch integration | ✅ Working | Via Fluent Bit → `lp-tools-cluster` log group |
| Basic request logging | ✅ Working | Method, path, status code |
| Prometheus metrics | ✅ Working | Per-tenant labels (team, api_key_alias) |

### Configuration

```yaml
# In litellm-values.yaml
proxy_config:
  litellm_settings:
    json_logs: true              # Structured JSON to stdout
    store_audit_logs: true       # Track admin actions in DB
    callbacks:
      - prometheus
```

### What Gets Logged (stdout → CloudWatch)

- HTTP request method and path
- Response status codes
- Internal scheduler events (model cost map reload)
- Error messages and warnings

### Limitation: Detailed Audit Logging

LiteLLM's stdout logs only capture basic request metadata. **Detailed audit-grade logging** (tokens, spend, full request/response payloads, user context) requires a dedicated logging callback.

| Callback | What it logs | Storage |
|----------|--------------|---------|
| `s3` | Full request/response + spend | S3 bucket |
| `dynamodb` | Structured records | DynamoDB |
| `langfuse` | Full observability | Langfuse SaaS/self-hosted |
| `custom_callback` | Custom payload | Your API endpoint |

> **Note (Feb 2026):** S3 callback not available per infrastructure constraints. To meet full audit requirements (per-tenant visibility, token usage, spend tracking), consider:
> - DynamoDB callback
> - Custom logging endpoint
> - Langfuse integration

### Alternative: Spend Tracking via API

LiteLLM tracks spend internally. Query via API instead of logs:

```bash
# Get spend for specific key
curl "https://litellm.dev.work.com/spend/logs?api_key=sk-xxx" \
  -H "Authorization: Bearer $MASTER_KEY"

# Get global spend
curl "https://litellm.dev.work.com/global/spend" \
  -H "Authorization: Bearer $MASTER_KEY"

# Get spend by team
curl "https://litellm.dev.work.com/spend/tags" \
  -H "Authorization: Bearer $MASTER_KEY"
```

### Azure Model Cost Tracking

For accurate cost tracking with Azure models, set `base_model` so LiteLLM knows the pricing:

**Via UI:** Models → Edit → Set Base Model (e.g., `azure/gpt-4`)

**Via API:**
```bash
curl -X POST "https://litellm.dev.work.com/model/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "your-model-id",
    "base_model": "azure/gpt-4"
  }'
```

Without this, you'll see: `could not identify azure model... set azure 'base_model' for accurate cost tracking`

---

## Cost Reporting & Chargeback

LiteLLM tracks spend per request in the database. Use the spend APIs for tenant-level chargeback.

### Spend Data Available

Each request logs:

| Field | Description |
|-------|-------------|
| `team_id` | Team UUID |
| `metadata.user_api_key_team_alias` | Team name (e.g., "engineering") |
| `metadata.user_api_key_alias` | API key name |
| `spend` | Cost in USD |
| `total_tokens` | Total tokens used |
| `prompt_tokens` | Input tokens |
| `completion_tokens` | Output tokens |
| `model` | Model used |
| `status` | success / failure |

### API Endpoints

**Global spend summary:**
```bash
curl -s "https://litellm.dev.work.com/global/spend" \
  -H "Authorization: Bearer $MASTER_KEY"
# Returns: {"spend": 0.107, "max_budget": 0.0}
```

**Spend by team:**
```bash
curl -s "https://litellm.dev.work.com/global/spend/teams" \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Spend by API key:**
```bash
curl -s "https://litellm.dev.work.com/global/spend/keys" \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Spend by model:**
```bash
curl -s "https://litellm.dev.work.com/global/spend/models" \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Detailed spend logs:**
```bash
# All logs (paginated)
curl -s "https://litellm.dev.work.com/spend/logs?limit=100" \
  -H "Authorization: Bearer $MASTER_KEY"

# Filter by team
curl -s "https://litellm.dev.work.com/spend/logs?team_id=TEAM_UUID" \
  -H "Authorization: Bearer $MASTER_KEY"

# Filter by API key
curl -s "https://litellm.dev.work.com/spend/logs?api_key=sk-xxx" \
  -H "Authorization: Bearer $MASTER_KEY"

# Filter by date range
curl -s "https://litellm.dev.work.com/spend/logs?start_date=2026-02-01&end_date=2026-02-28" \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Spend by tags:**
```bash
curl -s "https://litellm.dev.work.com/spend/tags" \
  -H "Authorization: Bearer $MASTER_KEY"
```

### Setting Up Teams for Chargeback

**1. Create teams:**
```bash
curl -X POST "https://litellm.dev.work.com/team/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "engineering",
    "max_budget": 100.0
  }'
```

**2. Create virtual keys per team:**
```bash
curl -X POST "https://litellm.dev.work.com/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "TEAM_UUID_FROM_STEP_1",
    "key_alias": "engineering-cline-key",
    "max_budget": 50.0
  }'
```

**3. Distribute keys to teams** - they use their key for all requests.

**4. Query spend by team:**
```bash
curl -s "https://litellm.dev.work.com/global/spend/teams" \
  -H "Authorization: Bearer $MASTER_KEY"
```

### Sample Chargeback Report Script

```bash
#!/bin/bash
# monthly-chargeback.sh

MASTER_KEY="sk-your-master-key"
BASE_URL="https://litellm.dev.work.com"
START_DATE="2026-02-01"
END_DATE="2026-02-28"

echo "=== Monthly Spend Report ==="
echo "Period: $START_DATE to $END_DATE"
echo ""

# Global spend
echo "Total Spend:"
curl -s "$BASE_URL/global/spend" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .

echo ""
echo "Spend by Team:"
curl -s "$BASE_URL/global/spend/teams" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .

echo ""
echo "Spend by Model:"
curl -s "$BASE_URL/global/spend/models" \
  -H "Authorization: Bearer $MASTER_KEY" | jq .
```

### Prometheus Metrics for Dashboards

Spend is also exposed via Prometheus:

```promql
# Total spend
sum(litellm_spend_metric_total)

# Spend by team
sum by (team) (litellm_spend_metric_total)

# Spend by model
sum by (model) (litellm_spend_metric_total)

# Token usage by team
sum by (team) (litellm_tokens_total)
```

---

## API Usage

### Authentication

All API requests require the master key:

```bash
curl -H "Authorization: Bearer sk-your-master-key" \
  https://litellm.homelab/v1/models
```

### Chat Completions

```bash
curl -X POST https://litellm.homelab/v1/chat/completions \
  -H "Authorization: Bearer sk-your-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-local",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ]
  }'
```

### List Models

```bash
curl https://litellm.homelab/v1/models \
  -H "Authorization: Bearer sk-your-master-key"
```

### Health Checks

```bash
# Readiness (includes DB check)
curl https://litellm.homelab/health/readiness

# Liveness
curl https://litellm.homelab/health/liveliness
```

### Python SDK Usage

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-your-master-key",
    base_url="https://litellm.homelab/v1"
)

response = client.chat.completions.create(
    model="qwen-local",
    messages=[
        {"role": "user", "content": "Explain kubernetes in one sentence"}
    ]
)
print(response.choices[0].message.content)
```

---

## AI Agent Integration

### Overview

LiteLLM serves as the unified LLM gateway for AI agents operating within the cluster. This enables:

- **Centralized API key management** - Agents don't need individual API keys
- **Model abstraction** - Agents request by capability, not specific model
- **Cost tracking** - All LLM usage tracked through single proxy
- **Rate limiting** - Protect backend services from runaway agents
- **Audit logging** - Complete request/response logging

### Agent Access Pattern

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   AI Agent      │────▶│    LiteLLM      │────▶│   LLM Backend   │
│   (Claude Code) │     │    Proxy        │     │   (Ollama/API)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │
        │                       ▼
        │               ┌─────────────────┐
        │               │   PostgreSQL    │
        │               │   (Usage logs)  │
        │               └─────────────────┘
        │
        ▼
┌─────────────────┐
│   Kubernetes    │
│   API Server    │
└─────────────────┘
```

### Recommended Agent Configuration

For AI agents (like Claude Code) accessing the cluster:

```yaml
# Agent environment configuration
LITELLM_API_BASE: "https://litellm.homelab/v1"
LITELLM_API_KEY: "sk-agent-specific-key"
LITELLM_MODEL: "qwen-local"  # or specific model for agent tasks
```

### Creating Agent-Specific Keys

```bash
# Via LiteLLM API (requires admin key)
curl -X POST https://litellm.homelab/key/generate \
  -H "Authorization: Bearer sk-admin-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "claude-code-agent",
    "max_budget": 10.0,
    "models": ["qwen-local"],
    "metadata": {"purpose": "kubernetes-management"}
  }'
```

### Security Best Practices for Agents

1. **Least Privilege Keys** - Generate keys with limited model access
2. **Budget Limits** - Set max_budget to prevent runaway costs
3. **Namespace Isolation** - Run agents in dedicated namespace with RBAC
4. **Network Policies** - Restrict agent egress to only LiteLLM endpoint
5. **Audit Logging** - Enable LiteLLM request logging for compliance

See [AI Agent Cluster Access](./ai-agent-access.md) for complete guide.

---

## SSO Configuration (Keycloak)

> **WARNING: Enterprise Feature**
>
> LiteLLM's native SSO (`enable_oauth2_auth: true`) is an **enterprise-only feature**.
> Enabling it in the open-source version breaks ALL API authentication with error:
> `"Oauth2 token validation is only available for premium users"`
>
> **Use oauth2-proxy instead** to protect the `/ui/` dashboard while keeping API auth working.

### Recommended Approach: oauth2-proxy

Use oauth2-proxy as a sidecar to protect the UI, while LiteLLM handles API auth via keys.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    Browser      │────▶│  oauth2-proxy   │────▶│    LiteLLM      │
│    (/ui/)       │     │  (Keycloak SSO) │     │    /ui/         │
└─────────────────┘     └─────────────────┘     └─────────────────┘

┌─────────────────┐                            ┌─────────────────┐
│   API Client    │───────────────────────────▶│    LiteLLM      │
│   (API key)     │      (direct, no proxy)    │    /v1/*        │
└─────────────────┘                            └─────────────────┘
```

### SSO User Limits

| Tier | SSO Users | Enforcement | Notes |
|------|-----------|-------------|-------|
| Free | 5 | **Soft limit** (warning only) | Native SSO via `enable_oauth2_auth` or oauth2-proxy |
| Enterprise | Unlimited | N/A | Requires `LITELLM_LICENSE` |

> **Tested (Feb 2026):** Created 6+ SSO users. Result:
> - UI shows warning: "You are over the SSO user limit"
> - All functionality still works (create keys, add users, API calls)
> - **Limit is NOT enforced** - just a notification

### If Enforcement Changes

If LiteLLM enforces the 5-user limit in future versions, use the **split oauth approach**:

1. **SSO users (up to 5):** Access via `/ui` with Keycloak SSO
2. **Additional admins:** Use `/fallback/login` with LiteLLM credentials

```bash
# Create fallback user (not counted as SSO user)
curl -X POST "https://litellm.dev.work.com/user/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "admin@work.com",
    "user_role": "proxy_admin",
    "password": "securepassword"
  }'
```

Fallback users authenticate directly with LiteLLM, bypassing SSO entirely.

### What NOT to Use (Enterprise Only)

Do NOT add these settings in open-source LiteLLM:

```yaml
# DO NOT USE - ENTERPRISE ONLY - BREAKS API AUTH
general_settings:
  enable_oauth2_auth: true      # BREAKS API - oauth2 token validation is enterprise
  ui_access_mode: "all"         # REQUIRES ENTERPRISE
```

### What oauth2-proxy Protects

| Endpoint | Protected | Notes |
|----------|------------|-------|
| `/ui/*` | Yes | Admin dashboard |
| `/` | No | FastAPI Swagger UI (root path) - disable recommended |
| `/docs` | No | FastAPI Swagger (alternate path) |
| `/redoc` | No | ReDoc documentation |
| `/v1/*` | No | API - uses API key auth |
| `/health/*` | No | Health checks - intentionally public |

> **Note:** By default, the root path `/` serves the FastAPI Swagger UI. This exposes your API schema publicly. For production deployments, **recommend disabling docs** rather than using oauth2-proxy, as protecting `/` with a path prefix would also protect all API endpoints.

### Option 1: Native SSO Only (Recommended)

Protects `/ui/` with Keycloak login. API docs remain public (or disable them).

**Step 1: Configure Keycloak Client**

1. Create client in Keycloak:
   - Client ID: `litellm`
   - Client Protocol: `openid-connect`
   - Access Type: `confidential`
   - Valid Redirect URIs: `https://litellm.homelab/*`
   - Web Origins: `https://litellm.homelab`

2. Get client secret from Credentials tab

**Step 2: Add to secrets**

```yaml
# In litellm-secrets (SOPS encrypted)
stringData:
  GENERIC_CLIENT_ID: litellm
  GENERIC_CLIENT_SECRET: your-client-secret
  GENERIC_AUTHORIZATION_ENDPOINT: https://keycloak.homelab/realms/homelab/protocol/openid-connect/auth
  GENERIC_TOKEN_ENDPOINT: https://keycloak.homelab/realms/homelab/protocol/openid-connect/token
  GENERIC_USERINFO_ENDPOINT: https://keycloak.homelab/realms/homelab/protocol/openid-connect/userinfo
  PROXY_BASE_URL: https://litellm.homelab
```

**Step 3: Enable in values.yaml**

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  enable_oauth2_auth: true
  ui_access_mode: "all"
```

**Step 4: (Recommended for Production) Disable API docs**

The root path `/` serves FastAPI Swagger UI by default, exposing your API schema publicly. For production/enterprise deployments, disable it:

```yaml
envVars:
  DOCS_URL: ""    # Disables /docs and root Swagger UI
  REDOC_URL: ""   # Disables /redoc
```

Users access the protected `/ui/` dashboard instead. API consumers use the API directly without needing Swagger.

### Option 2: oauth2-proxy as Reverse Proxy (Recommended for Work)

Deploy oauth2-proxy as a reverse proxy in front of LiteLLM's UI. This provides:
- Keycloak SSO authentication for `/ui`
- Automatic user creation in LiteLLM
- API endpoints remain unprotected (use API keys)

**oauth2-proxy Helm Values:**

```yaml
# oauth2-proxy-values.yaml
config:
  clientID: "litellm"
  cookieName: "_oauth2_proxy_litellm"

extraArgs:
  provider: "keycloak-oidc"
  oidc-issuer-url: "https://idp.dev.work.com/realms/master"
  redirect-url: "https://litellm.dev.work.com/oauth2/callback"
  email-domain: "*"
  upstream: "http://litellm.litellm-helm.svc.cluster.local:4000"
  http-address: "0.0.0.0:4180"
  skip-provider-button: "true"
  cookie-secure: "true"
  whitelist-domain: ".dev.work.com"

existingSecret: "oauth2-proxy-secrets"

service:
  type: ClusterIP
  portNumber: 4180
```

**Secrets:**

```yaml
# oauth2-proxy-secrets.yaml (encrypt with SOPS)
apiVersion: v1
kind: Secret
metadata:
  name: oauth2-proxy-secrets
  namespace: litellm-helm
type: Opaque
stringData:
  client-secret: "YOUR_KEYCLOAK_CLIENT_SECRET"
  cookie-secret: "GENERATE_WITH_OPENSSL"  # openssl rand -base64 32 | tr -- '+/' '-_'
```

**Ingresses:**

```yaml
# oauth2-ingress.yaml - handles SSO callbacks
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm-oauth2
  namespace: litellm-helm
spec:
  ingressClassName: nginx
  rules:
    - host: litellm.dev.work.com
      http:
        paths:
          - path: /oauth2
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 4180
---
# litellm-ui-ingress.yaml - UI through oauth2-proxy
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm-ui
  namespace: litellm-helm
spec:
  ingressClassName: nginx
  rules:
    - host: litellm.dev.work.com
      http:
        paths:
          - path: /ui
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy
                port:
                  number: 4180
```

**Deploy:**

```bash
# Create secret
kubectl apply -f oauth2-proxy-secrets.yaml

# Install oauth2-proxy via Helm
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm install oauth2-proxy oauth2-proxy/oauth2-proxy \
  -n litellm-helm \
  -f oauth2-proxy-values.yaml

# Apply ingresses
kubectl apply -f oauth2-ingress.yaml
kubectl apply -f litellm-ui-ingress.yaml
```

**Traffic Flow:**

```
/ui/* ──► oauth2-proxy ──► Keycloak login ──► LiteLLM UI (SSO auto-login)
/v1/* ──► LiteLLM directly (API key auth)
/oauth2/* ──► oauth2-proxy (SSO callbacks)
```

### User Role Management

New SSO users are created with `internal_user_viewer` role by default (least privilege).

**Available roles:**

| Role | Permissions |
|------|-------------|
| `proxy_admin` | Full access - manage models, keys, teams, settings |
| `internal_user` | Create keys, use models |
| `internal_user_viewer` | View only (default for SSO users) |

**Promote user to admin:**
```bash
curl -X POST "https://litellm.dev.work.com/user/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user@work.com", "user_role": "proxy_admin"}'
```

**List all users:**
```bash
curl -X GET "https://litellm.dev.work.com/user/list" \
  -H "Authorization: Bearer $MASTER_KEY" | jq '.[] | {user_id, user_role}'
```

### Troubleshooting SSO

| Issue | Cause | Solution |
|-------|-------|----------|
| `invalid redirect_uri` | PROXY_BASE_URL not set | Add PROXY_BASE_URL to secrets |
| `client disabled` | Browser cache | Clear cookies, use incognito |
| UI shows old key | Browser localStorage | Clear site data in DevTools |
| 401 after login | Wrong client secret | Verify secret matches Keycloak |
| Models page missing | User role too low | Promote user to `proxy_admin` via API |
| New users not admin | Default role is viewer | Manually promote via `/user/update` |

---

## Security Considerations

### Network Security

```yaml
# NetworkPolicy: Restrict litellm egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: litellm-egress
  namespace: litellm
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: litellm
  policyTypes:
    - Egress
  egress:
    # Allow PostgreSQL
    - to:
        - ipBlock:
            cidr: 192.168.0.21/32
      ports:
        - port: 5432
    # Allow Ollama
    - to:
        - ipBlock:
            cidr: 192.168.0.92/32
      ports:
        - port: 11434
    # Allow DNS
    - to: []
      ports:
        - port: 53
          protocol: UDP
```

### Secret Management

- **Never** commit plaintext secrets to Git
- Use SOPS + age for homelab, AWS Secrets Manager/Vault for enterprise
- Rotate `LITELLM_MASTER_KEY` periodically
- Use short-lived tokens for CI/CD pipelines

### TLS Configuration

```yaml
# Ingress with TLS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - litellm.homelab
      secretName: litellm-tls
```

---

## Troubleshooting

### Common Issues

#### 1. Metrics endpoint returns 404

**Cause**: Prometheus callback not enabled
**Solution**: Add to values.yaml:
```yaml
proxy_config:
  litellm_settings:
    callbacks:
      - prometheus
```

#### 2. Prometheus target shows "down"

**Cause**: Wrong metrics path (missing trailing slash)
**Solution**: Ensure ServiceMonitor uses `/metrics/` not `/metrics`

#### 3. Database connection failed

**Check**:
```bash
# Verify secret exists
kubectl get secret litellm-secrets -n litellm -o yaml

# Test connectivity
kubectl run psql-test --rm -it --image=postgres:15 -- \
  psql "postgresql://litellm:password@192.168.0.21:5432/litellm"
```

#### 4. Model routing errors

**Check**:
```bash
# View pod logs
kubectl logs -n litellm -l app.kubernetes.io/name=litellm --tail=100

# Verify config
kubectl get configmap -n litellm -o yaml | grep -A50 proxy_config
```

#### 5. OCI chart pull fails (401 Unauthorized)

**Cause**: Docker Hub rate limiting or auth required
**Solution**: Use GHCR registry:
```yaml
repoURL: ghcr.io/berriai
chart: litellm-helm
```

### Debug Commands

```bash
# Full pod status
kubectl describe pod -n litellm -l app.kubernetes.io/name=litellm

# Recent events
kubectl get events -n litellm --sort-by='.lastTimestamp' | tail -20

# Exec into pod
kubectl exec -it -n litellm deploy/litellm -- /bin/sh

# Port-forward for local testing
kubectl port-forward -n litellm svc/litellm 4000:4000

# Check Argo CD sync status
kubectl get application litellm -n argocd -o yaml | grep -A20 status:
```

---

## Runbooks

### Runbook: Upgrade LiteLLM Version

1. **Check current version**:
   ```bash
   curl -s https://litellm.homelab/health/readiness | jq .litellm_version
   ```

2. **Review changelog**: https://github.com/BerriAI/litellm/releases

3. **Update Argo CD Application**:
   ```yaml
   # argocd/app-litellm.yaml
   targetRevision: 0.1.XXX  # New version
   ```

4. **Commit and push**:
   ```bash
   git commit -am "chore(litellm): upgrade to 0.1.XXX" && git push
   ```

5. **Monitor rollout**:
   ```bash
   kubectl rollout status deployment/litellm -n litellm
   ```

6. **Verify health**:
   ```bash
   curl -s https://litellm.homelab/health/readiness
   ```

### Runbook: Add New Model

1. **Update values.yaml**:
   ```yaml
   proxy_config:
     model_list:
       - model_name: new-model
         litellm_params:
           model: provider/model-name
           api_key: os.environ/NEW_API_KEY
   ```

2. **Add API key to secrets** (if needed):
   ```bash
   # Decrypt, edit, re-encrypt
   sops apps/litellm/secrets/secrets.yaml
   ```

3. **Commit and push**
4. **Verify**:
   ```bash
   curl https://litellm.homelab/v1/models -H "Authorization: Bearer $KEY"
   ```

### Runbook: Rotate Master Key

1. **Generate new key**:
   ```bash
   NEW_KEY="sk-$(openssl rand -hex 32)"
   ```

2. **Update SOPS secret**:
   ```bash
   sops apps/litellm/secrets/secrets.yaml
   # Update LITELLM_MASTER_KEY value
   ```

3. **Commit and push**
4. **Wait for pod restart**
5. **Update all clients** with new key
6. **Verify**:
   ```bash
   curl -H "Authorization: Bearer $NEW_KEY" https://litellm.homelab/v1/models
   ```

---

## References

- [LiteLLM Documentation](https://docs.litellm.ai/)
- [LiteLLM GitHub](https://github.com/BerriAI/litellm)
- [LiteLLM Helm Chart](https://github.com/BerriAI/litellm/tree/main/deploy/charts/litellm-helm)
- [Prometheus Metrics](https://docs.litellm.ai/docs/proxy/prometheus)
- [Model Providers](https://docs.litellm.ai/docs/providers)
