# Claude Code Onboarding Guide

Getting started with Claude Code using our LiteLLM proxy.

Claude Code is an AI coding assistant that runs in your terminal or VS Code. We run it through our LiteLLM gateway, which routes requests to Claude models on AWS Bedrock.

> **Note:** Claude Code only supports Claude models. It does not work with GPT or other non-Anthropic models.

## Prerequisites

- A LiteLLM virtual key (ask your team lead)
- The LiteLLM server URL: `https://litellm.yourcompany.com`
- Node.js 18+ installed

---

## Option 1: VS Code Extension

### Install

1. Open VS Code
2. Go to Extensions (`Cmd+Shift+X` / `Ctrl+Shift+X`)
3. Search for **"Claude Code"** and install the Anthropic extension

### Configure

Open VS Code settings (`Cmd+,`) and edit `settings.json` (click the `{}` icon top-right). Add the following:

```json
{
  "claudeCode.disableLoginPrompt": true,
  "claudeCode.environmentVariables": [
    {
      "name": "ANTHROPIC_BASE_URL",
      "value": "https://litellm.yourcompany.com"
    },
    {
      "name": "ANTHROPIC_AUTH_TOKEN",
      "value": "sk-your-litellm-virtual-key"
    },
    {
      "name": "ANTHROPIC_DEFAULT_SONNET_MODEL",
      "value": "au.anthropic.claude-sonnet-4-5-20250929-v1:0"
    },
    {
      "name": "ANTHROPIC_DEFAULT_OPUS_MODEL",
      "value": "au.anthropic.claude-opus-4-6-v1:0"
    },
    {
      "name": "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
      "value": "1"
    }
  ]
}
```

> **Important:**
> - `disableLoginPrompt` must be `true` — we authenticate via LiteLLM, not Anthropic directly.
> - `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` is required to prevent beta header errors with Bedrock.
> - Opus is optional — remove it if you only want Sonnet.

### Verify

1. Reload VS Code (`Cmd+Shift+P` → "Developer: Reload Window")
2. Open the Claude Code panel
3. Type a message — if it responds, you're connected
4. To verify Opus: type `/model`, select Opus, then ask "What model are you?"

---

## Option 2: CLI Tool

### Install

```bash
npm install -g @anthropic-ai/claude-code
```

### Configure

Set these environment variables in your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
# Claude Code - LiteLLM Configuration
export ANTHROPIC_BASE_URL="https://litellm.yourcompany.com"
export ANTHROPIC_AUTH_TOKEN="sk-your-litellm-virtual-key"
export ANTHROPIC_DEFAULT_SONNET_MODEL="au.anthropic.claude-sonnet-4-5-20250929-v1:0"
export ANTHROPIC_DEFAULT_OPUS_MODEL="au.anthropic.claude-opus-4-6-v1:0"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

Then reload your shell:

```bash
source ~/.zshrc  # or ~/.bashrc
```

Alternatively, set them in Claude Code's config file at `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.yourcompany.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-your-litellm-virtual-key",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "au.anthropic.claude-sonnet-4-5-20250929-v1:0",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "au.anthropic.claude-opus-4-6-v1:0",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

> **Note:** `~/.claude/settings.json` applies to both the CLI and the VS Code extension.

### Verify

```bash
claude
```

If it drops you into an interactive session without asking you to log in, you're good.

---

## How Claude Code Uses Models

Claude Code uses up to three model tiers:

| Tier       | Used for                                  | Env var                          |
|------------|-------------------------------------------|----------------------------------|
| **Sonnet** | Default for all interactions              | `ANTHROPIC_DEFAULT_SONNET_MODEL` |
| **Opus**   | Complex tasks (manually selected by user) | `ANTHROPIC_DEFAULT_OPUS_MODEL`   |
| **Haiku**  | Lightweight internal subtasks             | `ANTHROPIC_DEFAULT_HAIKU_MODEL`  |

- **Sonnet** is used for everything by default — code edits, chat, searches.
- **Opus** is only used when you explicitly switch to it (via `/model` in CLI or the model selector in VS Code). Use it for harder tasks.
- **Haiku** is used internally for lightweight subtasks. Optional.

**You only need Sonnet to get started.** Opus and Haiku are optional extras.

---

## LiteLLM Admin Notes

These settings are required on the LiteLLM server side. If you're setting up LiteLLM (not just using it as a dev), make sure these are in place:

### Global drop_params (Required)

Claude Code sends Anthropic beta headers that Bedrock doesn't support. LiteLLM must be configured to strip them at the global level:

```yaml
litellm_settings:
  drop_params: true
```

Without this, all requests will fail with `400 invalid beta flag`.

> **Note:** Per-model `drop_params` only strips body parameters, not headers. The **global** `litellm_settings` level is required.

### Model Configuration

When adding Bedrock models in LiteLLM, use the `bedrock/` prefix and the full model ID:

- **Sonnet:** `bedrock/au.anthropic.claude-sonnet-4-5-20250929-v1:0`
- **Opus:** `bedrock/au.anthropic.claude-opus-4-6-v1:0`

The `au.` prefix indicates an Australia-region cross-region inference profile. Your model IDs may differ depending on your AWS region.

Required credentials per model:
- `aws_access_key_id`
- `aws_secret_access_key`
- `aws_region_name` (e.g. `ap-southeast-2`)

### Team/Key Access

Virtual keys are scoped to teams. Make sure the team has access to the model, otherwise users get `401 team doesn't have access to the model`.

---

## Troubleshooting

### "invalid beta flag" (400)
- This means LiteLLM is rejecting Anthropic beta headers. Ensure `litellm_settings.drop_params: true` is set globally (not just per-model) and LiteLLM has been restarted.
- On the client side, set `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`.

### "team doesn't have access to the model" (401)
- The virtual key's team doesn't have the model in its allowed models list. Update team permissions in LiteLLM admin UI.

### "the provided model identifier is invalid" (400 from Bedrock)
- Double-check the exact model ID. Verify it exists in your region: `aws bedrock list-foundation-models --region ap-southeast-2 --query "modelSummaries[].modelId" --output text`
- Make sure the model has the `bedrock/` prefix in LiteLLM and includes the `:0` version suffix.

### "Authentication failed" or 401 errors
- Check your virtual key is correct and active.
- Verify the key has access to the model in LiteLLM.

### "Model not found" or 404 errors
- Your `ANTHROPIC_DEFAULT_SONNET_MODEL` value must match the model name in LiteLLM exactly (the alias, not the full Bedrock ID).
- Check available models: `curl -s https://litellm.yourcompany.com/model/info -H "Authorization: Bearer sk-your-key" | jq '.data[].model_name'`

### Extension doesn't pick up env vars
- Make sure `claudeCode.disableLoginPrompt` is `true`.
- Reload VS Code after changing settings (`Cmd+Shift+P` → "Developer: Reload Window").
- Check the env vars are in `claudeCode.environmentVariables`.

### CLI says "please log in"
- You're missing `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL`.
- Run `env | grep ANTHROPIC` to verify they're set in your current shell.
- If using `~/.claude/settings.json`, make sure the JSON is valid (no trailing commas).

---

## Quick Reference

| Setting                        | Value                                            |
|--------------------------------|--------------------------------------------------|
| LiteLLM Server                 | `https://litellm.yourcompany.com`                |
| Auth env var                   | `ANTHROPIC_AUTH_TOKEN`                           |
| Base URL env var               | `ANTHROPIC_BASE_URL`                             |
| Sonnet model env var           | `ANTHROPIC_DEFAULT_SONNET_MODEL`                 |
| Opus model env var             | `ANTHROPIC_DEFAULT_OPUS_MODEL`                   |
| Disable beta flags             | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`       |
| Config file (shared)           | `~/.claude/settings.json`                        |
| VS Code setting                | `claudeCode.environmentVariables`                |
| Disable login                  | `claudeCode.disableLoginPrompt: true`            |
| LiteLLM global setting         | `litellm_settings.drop_params: true`             |
