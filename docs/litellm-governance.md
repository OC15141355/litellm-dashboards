# LiteLLM Governance Process

This document outlines the governance framework for the LiteLLM proxy deployment, covering tool approval, user lifecycle, cost attribution, and oversight.

## 1. Tool Approval

New AI coding tools must be approved by the security team before use in the work environment.

- **Currently approved**: Claude Code (only agentic CLI tool)
- **Evaluation criteria**:
  - Data residency and prompt handling
  - Telemetry, callbacks, and outbound connections
  - Privacy policy review
  - Known CVEs and security track record
- All LLM traffic routes through the LiteLLM proxy — no direct provider API keys are distributed to end users.

## 2. User Onboarding

| Step | Action | Owner |
|------|--------|-------|
| 1 | Team lead raises onboarding request | Team lead |
| 2 | Platform team creates user and assigns to team | Platform team |
| 3 | User receives a single API key scoped to their team | Platform team |
| 4 | User configures approved tool to point at LiteLLM proxy | User |

**Tooling**:
- Single user: `onboard-user.sh`
- Bulk: `bulk-onboard.sh` (CSV input: `user_id,email,role,team,key_alias`)

**Key naming convention**: `<user>-<tool>` (e.g. `jsmith-claudecode`)

## 3. Access Controls

### Team Level
- Budget caps (with configurable reset periods)
- Model allowlists — only approved models are exposed per team
- Rate limits (TPM/RPM)

### User Level
- Individual budget caps where required
- Keys scoped to a single team

### Provider Level
- No direct Bedrock credentials distributed
- LiteLLM handles provider authentication via IAM role
- Models managed centrally via `update-team-models.sh`

## 4. Cost Attribution & Reporting

### Dashboards
- Grafana cost attribution dashboards for team leads
- Access scoped via bookmarked URLs (`?var-team=<team_id>`)
- Panels include: total spend, budget remaining, avg cost per request, avg cost per 1K output tokens, model mix %, per-user spend trends, period-over-period comparison

### Ad-Hoc Reporting
- `spend-report.sh` supports `--team`, `--start`, `--end`, `--csv` flags
- Budget reset cycles aligned to billing periods

### Chargeback
- Jira cost code mapping (planned) — maps LiteLLM teams to business unit charge codes for financial reporting

## 5. Key Lifecycle

| Action | Method | Notes |
|--------|--------|-------|
| **Issue** | `onboard-user.sh` | Key created, scoped to team |
| **Rotate** | `rotate-key.sh` | Old key deleted, new key issued |
| **Revoke** | API key deletion | Immediate, for compromised keys |
| **Offboard** | `offboard-user.sh` | Keys deleted, team membership removed, user deleted |

## 6. Data Handling & Privacy

| Setting | Value | Effect |
|---------|-------|--------|
| `store_prompts_in_spend_logs` | `false` | Metadata only in PostgreSQL — no prompt or response content stored |
| `turn_off_message_logging` | `true` | No content sent to external callbacks |
| `maximum_spend_logs_retention_period` | `30d` | Spend metadata retained for 30 days |

- LiteLLM stores request metadata (model, tokens, cost, user, team, timestamp) for cost attribution
- No prompt or response content is persisted or forwarded

## 7. Monitoring & Oversight

### Spend Monitoring
- Total and per-user spend tracked against budget caps
- Period-over-period comparison flags anomalies
- Model mix % shows shifts toward more expensive models

### Operational Monitoring
- Success rate tracking catches misuse or upstream errors
- Request volume trends for capacity planning

### Alerting (Planned)
- Grafana alerting on budget threshold breaches (e.g. 80% budget consumed)
- Model to be determined: Grafana native alerting or Alertmanager integration

## 8. Audit Trail

| What | Where |
|------|-------|
| Request metadata (model, tokens, cost, user, team) | `LiteLLM_SpendLogs` table |
| Key creation and deletion | LiteLLM API logs |
| Infrastructure changes | Terraform state and git history |
| Script and config changes | `litellm-dashboards` repo git history |
| Dashboard changes | Grafana JSON in `litellm-dashboards` repo |

## 9. Roles & Responsibilities

| Role | Responsibilities |
|------|-----------------|
| **Platform team** | Proxy deployment, user lifecycle, model management, dashboard maintenance, cost reporting |
| **Security team** | Tool approval, periodic review of data handling, access control audit |
| **Team leads** | Onboarding requests, spend review via dashboards, usage policy enforcement within team |
| **End users** | Use approved tools only, report key compromise immediately |
