# LiteLLM Logging & Auditing

Current logging architecture, configuration, and future considerations.

---

## Current Setup

| Component | Purpose | Storage |
|-----------|---------|---------|
| LiteLLM UI | Spend tracking, per-user/team/model usage, error logs | PostgreSQL |
| Spend Logs | Request metadata (user, model, tokens, cost, tags, timestamps) | PostgreSQL, 30d TTL |
| Message Logging | **Off** — prompts and responses are not stored | — |

### Config (general_settings)

```yaml
general_settings:
  turn_off_message_logging: true              # metadata only, no prompt/response bodies
  store_prompts_in_spend_logs: false           # no payloads in spend_logs table
  maximum_spend_logs_retention_period: "30d"   # auto-delete logs older than 30 days
  maximum_spend_logs_retention_interval: "1d"  # cleanup runs daily
```

### What gets stored in Postgres

- User ID, team ID, API key hash
- Model name, provider
- Prompt tokens, completion tokens, total tokens
- Cost (USD)
- Timestamp (start/end)
- Request tags (if provided)
- Cache hit/miss
- HTTP status

### What does NOT get stored

- Prompt content (the messages sent to the model)
- Response content (the model's output)

---

## Why Message Logging Is Off

Tools like Claude Code send the **full conversation context on every turn** — every file read, tool call, and prior response. A single request can exceed 100k tokens (~400KB of JSON). Over 30 days with multiple users, this puts significant storage and performance pressure on RDS.

| Scenario | Per request | Per user/day (100 reqs) | 5 users / 30 days |
|----------|------------|------------------------|-------------------|
| With message logging | ~400KB | ~40MB | ~6GB |
| Without (metadata only) | ~500B | ~50KB | ~7.5MB |

The UI dashboards, spend tracking, and per-user/team reporting all work from metadata alone. Message content is not required for day-to-day operations.

---

## Tagging

LiteLLM supports request tags via API metadata:

```json
{
  "model": "sonnet-4.5",
  "messages": [...],
  "metadata": {
    "tags": ["claude-code", "engineering", "project-x"]
  }
}
```

Tags are stored in spend_logs regardless of message logging settings. They enable:
- Filtering in the UI by tool, team, or project
- Spend breakdowns by tag
- Identifying usage patterns across different tools

---

## Future: S3 Full Payload Logging

If full request/response logging is needed for compliance or security audit, the recommended path is S3 — not re-enabling Postgres message logging.

### Design

```
LiteLLM UI   →  day-to-day visibility (spend, usage, errors)
PostgreSQL   →  lightweight metadata, 30d TTL
S3           →  full request/response archive, lifecycle policies
```

### Config change

```yaml
general_settings:
  turn_off_message_logging: true               # keep metadata-only in Postgres
  store_prompts_in_spend_logs: false

litellm_settings:
  success_callback: ["s3"]                     # full payloads to S3
  s3_callback_params:
    s3_bucket_name: "litellm-logs"
    s3_region_name: "ap-southeast-2"
    s3_path: "logs/{model}/{date}"
```

### S3 lifecycle policy

| Age | Storage class | Cost/GB |
|-----|--------------|---------|
| 0-90 days | S3 Standard | ~$0.023 |
| 90-365 days | S3 Glacier | ~$0.004 |
| 365+ days | Deleted | — |

### Querying archived logs

Create an Athena table over the S3 path for ad-hoc queries:
- "What did user X send to the model on Tuesday?"
- "Show me all requests tagged `project-x` last week"
- "All Claude Code requests over 50k tokens in the last month"

### Prerequisites

- S3 bucket provisioned (Terraform)
- Lifecycle policy configured
- LiteLLM pod needs IAM access to write to the bucket
- Athena table definition (one-off DDL)
