# LiteLLM Platform Guide

## Overview

LiteLLM is an open-source LLM proxy that provides a unified OpenAI-compatible API for managing access to multiple LLM providers (AWS Bedrock, OpenAI, Anthropic, etc). It serves as the gateway layer for all LLM API calls, enabling cost attribution, access control, and observability across teams.

### Why LiteLLM?

- **Cost Attribution**: Track spend per team, user, and API key
- **Budget Controls**: Set spending limits per team with automatic enforcement
- **Unified API**: Single OpenAI-compatible endpoint regardless of provider
- **Model Access Control**: Restrict which teams can use which models
- **Observability**: Prometheus metrics, Grafana dashboards, audit logging

---

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Developers     │     │  Applications   │     │  CI/CD          │
│  (Claude Code)  │     │  (Internal)     │     │  (Pipelines)    │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         │              ┌────────▼────────┐              │
         └──────────────►    LiteLLM      ◄──────────────┘
                        │    Proxy        │
                        │  (K8s Deploy)   │
                        └────────┬────────┘
                                 │
                    ┌────────────┼────────────┐
                    ▼            ▼            ▼
             ┌──────────┐ ┌──────────┐ ┌──────────┐
             │ Bedrock  │ │ OpenAI   │ │ Anthropic│
             │ (Claude) │ │ (GPT-4)  │ │ (Direct) │
             └──────────┘ └──────────┘ └──────────┘
```

### Components

| Component | Purpose | Location |
|-----------|---------|----------|
| LiteLLM Proxy | API gateway, routing, budgets | K8s (Helm chart) |
| PostgreSQL | Teams, keys, spend data | Existing DB |
| Prometheus | Metrics collection | Monitoring stack |
| Grafana | Dashboards, visualisation | Monitoring stack |
| Keycloak | SSO authentication | Existing IdP |

---

## Deployment

### Repository Structure

```
02_install/charts/litellm/
├── helmfile.yaml.gotmpl      # Helm release definition
├── litellm.yaml.gotmpl       # Application values (hardcoded, requiredEnv for hostname)
├── secrets.tmpl               # K8s secret template (master key, database URL)
├── pre-install.sh             # Pulls secrets from AWS Secrets Manager
├── post-install.sh            # Deploys Grafana dashboards, cleans env
├── dashboards/                # Grafana dashboard JSON files
│   ├── grafana-dashboard.json
│   ├── grafana-dashboard-team.json
│   └── grafana-dashboard-models.json
└── scripts/
    └── litellm-admin.sh       # Admin CLI tool
```

### Secrets Management

Secrets are stored in **AWS Secrets Manager** and pulled at deploy time:

```
AWS Secrets Manager (litellm-dev)
    → pre-install.sh (aws secretsmanager get-secret-value)
    → envsubst renders secrets.tmpl → secrets.yml
    → kubectl apply creates K8s secret
    → LiteLLM pod references the secret
```

| Secret | Key | Purpose |
|--------|-----|---------|
| `litellm-dev` | `MASTER_KEY` | Admin API access |
| `litellm-dev` | `DATABASE_URL` | PostgreSQL connection string |

### Environment Variables

Defined in `02_install/env/work-devops-tools-dev/common/vars.env`:

```bash
LITELLM_SECRET_SM=litellm-dev
LITELLM_NAMESPACE=litellm
```

---

## Team & User Management

### Concepts

| Concept | Description |
|---------|-------------|
| **Team** | Organisational unit (e.g., "Engineering", "Data Science"). Has budget, model access |
| **User** | Individual developer. Belongs to one or more teams |
| **Virtual Key** | API key tied to a team. All spend attributed to the team |
| **Budget** | Maximum spend limit per team. Can be set with duration (e.g., monthly) |

### Admin CLI

```bash
# Set environment
export LITELLM_API_BASE="https://litellm.example.com"
export LITELLM_MASTER_KEY="sk-..."

# Team management
./litellm-admin.sh team list
./litellm-admin.sh team create "Engineering" 500 "claude-3-sonnet,gpt-4"
./litellm-admin.sh team info Engineering        # supports alias or UUID

# Key management
./litellm-admin.sh key create Engineering "dev-key" 100
./litellm-admin.sh key list Engineering
./litellm-admin.sh key move <key> NewTeam

# User management
./litellm-admin.sh user list
./litellm-admin.sh user add-to-team <user_id> Engineering admin

# Audit
./litellm-admin.sh audit all-teams
./litellm-admin.sh audit team-spend Engineering
./litellm-admin.sh audit full
```

### Workflow: Onboarding a New Team

1. Create team with budget and model access
2. Generate virtual API key(s) for the team
3. Distribute key to team lead
4. Team members use the key in their applications
5. All spend is attributed to the team automatically

---

## SSO & Authentication

### Current State

| Feature | Status |
|---------|--------|
| Keycloak SSO (UI login) | Working (via oauth2-proxy) |
| Team attribution from SSO | Not configured (requires enterprise) |
| JWT Auth (API calls) | Not configured (requires enterprise) |
| SCIM (group sync) | Not available (requires enterprise) |
| Fallback UI (non-SSO) | Working |
| SSO user limit | 5 users (free tier) |

### Keycloak Integration Options

#### Option 1: JWT Auth with Group Claims (Enterprise Required)

Maps Keycloak groups directly to LiteLLM teams at the API level.

```yaml
general_settings:
  enable_jwt_auth: True
  litellm_jwtauth:
    user_id_jwt_field: "sub"
    team_ids_jwt_field: "groups"
    user_id_upsert: true
    enforce_team_based_model_access: true
```

Teams must be pre-created with `team_id` matching Keycloak group UUID.

#### Option 2: SCIM Sync (Enterprise Required)

Automatic group/user sync from Keycloak to LiteLLM:
- Teams auto-created from Keycloak groups
- User removal in Keycloak revokes API keys automatically
- Cleanest approach for team binding from Keycloak

#### Option 3: Current (oauth2-proxy Wrapper)

- Keycloak handles login only
- No team attribution from SSO claims
- Manual team/key management via CLI or API

### Recommendation

If parent company has LiteLLM enterprise license, SCIM provides the cleanest path. Without enterprise, team attribution from Keycloak claims is not available - manual team management is required.

---

## Enterprise vs Free License

### Feature Comparison

| Feature | Free (OSS) | Enterprise |
|---------|-----------|------------|
| OpenAI-compatible proxy | ✓ | ✓ |
| Cost attribution & reporting | ✓ | ✓ |
| Budgets & rate limits | ✓ | ✓ |
| Virtual keys | ✓ | ✓ |
| Prometheus metrics | ✓ | ✓ |
| Guardrails | ✓ | ✓ |
| SSO (Admin UI) | ✓ (up to 5 users) | ✓ (unlimited) |
| JWT Auth (OIDC) | ✗ | ✓ |
| SCIM (group sync) | ✗ | ✓ |
| Audit logs with retention | ✗ | ✓ |
| Secret managers integration | ✗ | ✓ |
| IP-based access control | ✗ | ✓ |
| Granular RBAC | ✗ | ✓ |
| Professional support (Slack) | ✗ | ✓ |
| Custom integrations | ✗ | ✓ |

### Pricing

- Enterprise: ~$250/mo starting, scales with usage
- Contact sales for custom pricing
- Available on AWS/Azure Marketplace

### When Do We Need Enterprise?

- More than 5 SSO users on Admin UI
- Team attribution from Keycloak groups (JWT Auth or SCIM)
- Audit log retention requirements
- Professional support SLAs (1hr Sev0, 6hr Sev1, 24hr Sev2-3)

---

## Claude Code with Amazon Bedrock

### Overview

Claude Code is Anthropic's AI-powered CLI coding assistant. Using Amazon Bedrock as the backend, all usage stays within our AWS account with unified billing, CloudTrail audit logging, and existing IAM controls.

### Setup

```bash
# Required environment variables
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=ap-southeast-2    # or your region

# Model configuration (optional)
export ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0
export ANTHROPIC_SMALL_FAST_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
```

### Authentication Methods

| Method | Use Case | Security |
|--------|----------|----------|
| **AWS SSO (IAM Identity Center)** | Day-to-day development | Recommended - temp credentials, auto-refresh |
| **Direct OIDC Federation** | Production/Enterprise | Best - IdP integration, full user context |
| **AWS CLI Credentials** | Quick setup/testing | OK - env vars or ~/.aws/credentials |
| **Bedrock API Keys** | Short-term testing only | Not recommended - no MFA, no attribution |

### IAM Policy Required

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream",
                "bedrock:ListInferenceProfiles"
            ],
            "Resource": [
                "arn:aws:bedrock:*::foundation-model/anthropic.*",
                "arn:aws:bedrock:*:*:inference-profile/*"
            ]
        }
    ]
}
```

### LiteLLM + Claude Code Integration

When using Claude Code through LiteLLM proxy:

1. LiteLLM routes Claude Code requests to Bedrock
2. All usage is attributed to the developer's team via virtual key
3. Budget limits apply per team
4. Metrics appear in Grafana dashboards

```bash
# Developer sets LiteLLM as their endpoint
export ANTHROPIC_BASE_URL="https://litellm.example.com"
export ANTHROPIC_API_KEY="sk-team-virtual-key"
```

### Benefits of Bedrock Backend

- **Unified billing**: Appears in AWS bill alongside EC2, S3, etc.
- **CloudTrail audit**: All API calls logged alongside other AWS activity
- **Data residency**: Requests stay within your AWS account/region
- **Prompt caching**: Reduces cost for repeated codebases
- **No separate vendor**: Uses existing AWS relationship

---

## Monitoring & Dashboards

### Grafana Dashboards

| Dashboard | Audience | Purpose |
|-----------|----------|---------|
| **Operations & FinOps** | Platform team | System health, costs, budgets |
| **Team View** | Team leads | Per-team spend, usage, performance |
| **Model Comparison** | Developers | Compare models on cost, latency, reliability |

### Prerequisites

1. LiteLLM Prometheus callback enabled in config
2. Prometheus scraping LiteLLM `/metrics/` endpoint (trailing slash required)
3. Grafana with Prometheus data source configured

### Key Metrics

| Metric | Description |
|--------|-------------|
| `litellm_requests_metric_total` | Total LLM requests by model, team, key |
| `litellm_spend_metric_total` | Spend in USD by model, team, key |
| `litellm_total_tokens_metric_total` | Total tokens used |
| `litellm_request_total_latency_metric` | End-to-end request latency |
| `litellm_remaining_team_budget_metric` | Remaining budget per team |
| `litellm_deployment_state` | Health: 0=healthy, 1=partial, 2=outage |

---

## Master Key Security

### Purpose

The master key provides root admin access to the LiteLLM proxy. It is required for all team, user, and key management operations and bypasses all budget limits.

### Storage

Stored in AWS Secrets Manager (`litellm-dev`). Access controlled via IAM policies.

### Risk If Compromised

| Risk | Impact |
|------|--------|
| Full admin access | Create/delete any team, user, key |
| Budget bypass | Unlimited spend, no guardrails |
| Data exposure | View all teams' spend and usage data |
| Key minting | Generate unlimited API keys |

### Best Practices

- Never embed in code or share with end users
- Use only for admin operations, not application calls
- Rotate periodically (quarterly recommended)
- Limit IAM access to Secrets Manager entry
- Audit access via CloudTrail

---

## Next Steps

- [ ] Confirm enterprise license availability with parent company
- [ ] If enterprise available: configure SCIM or JWT Auth for Keycloak group → team mapping
- [ ] If no enterprise: continue with manual team management via CLI
- [ ] Senior dev review of deployment PR (secrets flow, ESO)
- [ ] Production deployment after review
