# LiteLLM Next Phase — AI Tooling Expansion & Usage Attribution

This document breaks down the next phase of work for the LiteLLM platform: onboarding new AI tools, adding GPT model access via Azure AI Foundry, implementing usage attribution by tool, and configuring standardised developer workspaces.

## Work Streams

1. [Azure AI Foundry — GPT Model Access](#1-azure-ai-foundry--gpt-model-access)
2. [Codex CLI Onboarding](#2-codex-cli-onboarding)
3. [Claude Code Workspace Configuration](#3-claude-code-workspace-configuration)
4. [Usage Attribution — Tool-Level Tracking](#4-usage-attribution--tool-level-tracking)
5. [S3 Logging Backend](#5-s3-logging-backend)
6. [Sourcegraph Backend Upgrade](#6-sourcegraph-backend-upgrade)

---

## 1. Azure AI Foundry — GPT Model Access

### Context

Azure AI Foundry (formerly Azure AI Studio, now being rebranded to Microsoft Foundry) is the unified AI platform that includes Azure OpenAI. Microsoft is migrating Azure OpenAI resources into the Foundry resource type. For GPT models (GPT-4o, GPT-4.1, o3), we provision through Azure OpenAI within Foundry.

### LiteLLM Configuration

LiteLLM uses two distinct provider prefixes for Azure:

- `azure/` — for Azure OpenAI GPT models
- `azure_ai/` — for Azure AI Foundry non-OpenAI models (Cohere, Mistral, etc.)

```yaml
# config.yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o-deployment
      api_key: os.environ/AZURE_API_KEY
      api_base: https://<resource>.openai.azure.com
      api_version: "2024-06-01"

  - model_name: gpt-4.1
    litellm_params:
      model: azure/gpt-4.1-deployment
      api_key: os.environ/AZURE_API_KEY
      api_base: https://<resource>.openai.azure.com
      api_version: "2024-06-01"
```

For o-series models, use the `azure/o_series/` prefix:
```yaml
  - model_name: o3
    litellm_params:
      model: azure/o_series/o3-deployment
      api_key: os.environ/AZURE_API_KEY
      api_base: https://<resource>.openai.azure.com
      api_version: "2024-06-01"
```

### Tasks

- [ ] Confirm Azure OpenAI resource provisioning (region, deployment type — Standard vs PTU)
- [ ] Obtain API key and endpoint from Azure portal
- [ ] Add GPT models to LiteLLM config
- [ ] Assign GPT models to appropriate teams via `update-team-models.sh`
- [ ] Test with Codex CLI and direct API calls
- [ ] Update governance doc with approved GPT models

---

## 2. Codex CLI Onboarding

### Overview

[Codex CLI](https://github.com/openai/codex) is OpenAI's open-source (Apache 2.0) terminal-based coding agent, built in Rust. It uses the Responses API wire format.

### Security Assessment

| Aspect | Status |
|--------|--------|
| Open source | Yes (Apache 2.0) |
| Sandboxing | OS-enforced — `workspace-write` (default), `untrusted`, `danger-full-access` |
| Network access | Off by default in sandbox |
| Telemetry | On by default, fully disableable via config |
| Admin policies | `requirements.toml` — enforce sandbox modes, MCP allowlists, command restrictions |
| Custom endpoint | Yes — `OPENAI_BASE_URL` or `config.toml` |
| Data sent | Only prompt context to API endpoint, source code stays local |

### LiteLLM Integration

Codex CLI can point at LiteLLM via environment variables:

```bash
export OPENAI_BASE_URL=https://<litellm-proxy>/v1
export OPENAI_API_KEY=sk-<litellm-key>
codex --model gpt-4o
```

Or via `~/.codex/config.toml`:

```toml
[model_providers.litellm]
name = "LiteLLM Proxy"
base_url = "https://<litellm-proxy>"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

Requires LiteLLM v1.66.3.dev5+ for Responses API support.

### Recommended Configuration for Workspace Deployment

Disable telemetry and enforce sandbox policy:

```toml
# ~/.codex/config.toml
[analytics]
enabled = false

[feedback]
enabled = false

[history]
persistence = "none"  # or "summary" — no full transcripts stored
```

Admin-managed `requirements.toml` for policy enforcement:

```toml
[sandbox]
mode = "workspace-write"    # restrict to workspace only

[mcp]
allowlist = []              # no MCP servers unless approved

[approval]
auto_approve = false        # require user approval for commands
```

### Tasks

- [ ] Security team approval for Codex CLI
- [ ] Define standard `config.toml` and `requirements.toml`
- [ ] Test LiteLLM Responses API compatibility (version check)
- [ ] Create onboarding guide for developers
- [ ] Generate Codex-specific keys with `tool=codex` tag

---

## 3. Claude Code Workspace Configuration

### Overview

Claude Code can be pre-configured to route all traffic through the LiteLLM proxy. For AWS Workspaces, these settings can be baked into the workspace image.

### Environment Variables

```bash
# Point at LiteLLM proxy
export ANTHROPIC_BASE_URL=https://<litellm-proxy>
export ANTHROPIC_AUTH_TOKEN=sk-<litellm-key>

# If routing through Bedrock via LiteLLM
export ANTHROPIC_BEDROCK_BASE_URL=https://<litellm-proxy>/bedrock
export CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
export CLAUDE_CODE_USE_BEDROCK=1

# Strip beta headers for third-party proxy compatibility
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

### Managed Settings

Deploy `managed-settings.json` to the system directory on the workspace image. This prevents users from overriding security-critical settings:

- macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`
- Linux: `/etc/claude-code/managed-settings.json`

### AWS Workspaces Deployment Pattern

1. Install Claude Code (npm) in the base workspace image
2. Set environment variables in `/etc/environment` or workspace user profile
3. Deploy `managed-settings.json` to system directory
4. Pre-configure LiteLLM API key (or use a key helper script that fetches from Secrets Manager)
5. Test with workspace provisioning pipeline

### Dynamic Key Helper

For environments where static keys are undesirable, Claude Code supports a `apiKeyHelper` that runs a script to fetch keys at runtime:

```json
{
  "apiKeyHelper": "/usr/local/bin/fetch-litellm-key.sh"
}
```

The script could fetch from AWS Secrets Manager, Vault, or a token endpoint.

### Tasks

- [ ] Define standard workspace image configuration
- [ ] Create `managed-settings.json` with approved settings
- [ ] Decide on key distribution: static keys vs key helper
- [ ] Build and test workspace image with Claude Code pre-installed
- [ ] Document workspace setup for IT/infrastructure team

---

## 4. Usage Attribution — Tool-Level Tracking

### How It Works

LiteLLM provides multiple mechanisms for tracking which tool generated a request. The best part: **User-Agent tracking is automatic**.

### Automatic User-Agent Tagging (Zero Config)

LiteLLM automatically captures the `User-Agent` header as a request tag. Each tool sends a distinct User-Agent:

| Tool | User-Agent |
|------|------------|
| Claude Code | `claude-code/<version>` |
| Codex CLI | `codex-cli/<version>` |
| curl / scripts | `curl/x.x.x` |

These appear in `LiteLLM_SpendLogs.request_tags` automatically. No client-side or proxy-side configuration needed.

To disable (not recommended): `litellm_settings.disable_add_user_agent_to_request_tags: true`

### Key-Level Tags

When generating keys, attach metadata tags that auto-apply to all requests from that key:

```bash
curl -X POST 'https://<litellm-proxy>/key/generate' \
  -H 'Authorization: Bearer MASTER_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "user_id": "jsmith",
    "team_id": "<team-uuid>",
    "key_alias": "jsmith-claudecode",
    "metadata": {
      "tags": ["tool=claude-code", "team=platform"]
    }
  }'
```

### Custom Header Tracking

Capture arbitrary headers as spend tags:

```yaml
litellm_settings:
  extra_spend_tag_headers:
    - "x-tool-name"
    - "x-project-id"
```

### Querying Tool Usage

On free tier, query PostgreSQL directly (no `/spend/tags` endpoint — that's Enterprise):

```sql
-- Spend by tool (User-Agent tag)
SELECT
  unnest(request_tags) AS tag,
  COUNT(*) AS requests,
  SUM(spend) AS total_spend
FROM "LiteLLM_SpendLogs"
WHERE starttime >= NOW() - INTERVAL '30 days'
GROUP BY tag
HAVING unnest(request_tags) LIKE 'User-Agent:%'
ORDER BY total_spend DESC;
```

This query can power a Grafana panel for tool-level cost attribution.

### Grafana Dashboard Panel (Tool Attribution)

Add to the finance or admin dashboard — spend breakdown by tool:

```sql
SELECT
  date_trunc('day', starttime) AS time,
  CASE
    WHEN request_tags::text LIKE '%claude-code%' THEN 'Claude Code'
    WHEN request_tags::text LIKE '%codex%' THEN 'Codex CLI'
    ELSE 'Other'
  END AS metric,
  SUM(spend) AS value
FROM "LiteLLM_SpendLogs"
WHERE starttime >= $__timeFrom()
  AND starttime <= $__timeTo()
GROUP BY 1, 2
ORDER BY 1
```

Note: This queries `LiteLLM_SpendLogs` (per-request), not the pre-aggregated daily tables. Performance may degrade with high request volumes — consider a materialised view or the S3 backend for historical analysis.

### Tasks

- [ ] Verify User-Agent auto-tagging is enabled (default on)
- [ ] Update key generation to include `tool=` tags in metadata
- [ ] Add tool attribution panel to Grafana admin/finance dashboard
- [ ] Test with Claude Code and Codex CLI requests
- [ ] Document tag conventions in governance doc

---

## 5. S3 Logging Backend

### Overview

LiteLLM can log all requests to S3 via the `s3_v2` callback. This provides a durable audit trail and enables historical analysis beyond the PostgreSQL retention window.

### Configuration

```yaml
litellm_settings:
  success_callback: ["s3_v2"]
  s3_callback_params:
    s3_bucket_name: litellm-audit-logs
    s3_region_name: ap-southeast-2
    s3_path: litellm/requests
    s3_use_team_prefix: true     # prefix with team alias
    s3_use_key_prefix: true      # prefix with key alias
```

If using IAM roles (EKS service account, ECS task role), no credentials needed — the SDK uses the instance role.

### S3 Key Structure

With team and key prefixes enabled:
```
litellm/requests/<team-alias>/<key-alias>/<call-id>.json
```

### Data Content

Each request logs a JSON payload containing:
- Request metadata: model, tokens, cost, cost breakdown, tags
- Timing: start time, end time, response time
- Identity: key hash, team ID, user ID, team alias, key alias
- Content: full messages and response (**by default**)

### Content Redaction

| Setting | Effect on S3 | Effect on PostgreSQL |
|---------|-------------|---------------------|
| `turn_off_message_logging: true` | Redacts messages/response from S3 payload | Redacts from all callbacks |
| `store_prompts_in_spend_logs: false` | No effect on S3 | No prompts in DB spend table |
| `s3_strip_base64_files: true` | Strips base64 content from S3 payload | No effect |

**Recommended for our deployment** (metadata-only audit trail):
```yaml
litellm_settings:
  turn_off_message_logging: true    # no prompt/response content anywhere
  success_callback: ["s3_v2"]
  s3_callback_params:
    s3_bucket_name: litellm-audit-logs
    s3_region_name: ap-southeast-2
    s3_path: litellm/requests
    s3_use_team_prefix: true
    s3_use_key_prefix: true
```

### Audit Logs (Admin Actions)

Separately log key create/delete/rotate actions to S3:
```yaml
general_settings:
  store_audit_logs: true
  audit_log_callbacks: ["s3_v2"]
```

### Tasks

- [ ] Create S3 bucket with appropriate lifecycle policy (retention, transitions to Glacier)
- [ ] Configure IAM role/policy for LiteLLM pod to write to S3
- [ ] Add `s3_v2` callback to LiteLLM config
- [ ] Confirm `turn_off_message_logging: true` redacts content from S3
- [ ] Test S3 log structure with sample requests
- [ ] Consider Athena for ad-hoc querying of S3 logs

---

## 6. Sourcegraph Backend Upgrade

### Context

Evaluating an upgrade to Sourcegraph's backend. Details TBD — this section will be populated once the scope is clearer.

### Considerations

- Does Sourcegraph's Cody AI assistant route through LiteLLM, or does it have its own LLM backend?
- If Cody can use a custom endpoint, it should go through the LiteLLM proxy for cost attribution
- Version compatibility and migration path
- Impact on existing code search and intelligence features

### Tasks

- [ ] Determine current Sourcegraph version and deployment method
- [ ] Evaluate upgrade path and breaking changes
- [ ] Assess Cody AI integration with LiteLLM proxy
- [ ] Plan upgrade window and rollback strategy

---

## Security Notes

### LiteLLM Supply Chain Advisory

LiteLLM PyPI versions **1.82.7 and 1.82.8 were compromised** with credential-stealing malware. If these versions were ever installed, rotate all credentials on affected systems. Pin to known-good versions and verify checksums.

### nginx Considerations

If placing nginx in front of LiteLLM:
- Set `underscores_in_headers on;` — nginx silently drops headers with underscores by default, breaking LiteLLM metadata headers
- Enable `proxy_buffering off;` for SSE/streaming support
- LiteLLM's built-in rate limiting (per-key RPM/TPM) is generally better than nginx rate limiting for this use case

---

## Dependencies & Sequencing

```
1. Azure AI Foundry setup ──────────┐
                                    ├──> 4. Usage Attribution (needs both tools active)
2. Codex CLI onboarding ────────────┤
                                    ├──> 5. S3 Logging (can run in parallel)
3. Claude Code workspace config ────┘

6. Sourcegraph (independent, scope TBD)
```

Streams 1-3 can run in parallel. Stream 4 (usage attribution) benefits from having both tools onboarded so you can validate the tagging end-to-end. Stream 5 (S3) is independent and can be set up at any time. Stream 6 is separate.
