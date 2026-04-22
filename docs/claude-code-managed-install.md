# Claude Code — Managed-Scope Installation on AWS Workspaces

**Status:** Recommendation (ticket outcome)
**Audience:** Platform / workstation engineering, security, LiteLLM admin team
**Related docs:** [litellm-governance.md](./litellm-governance.md), [litellm-next-phase.md](./litellm-next-phase.md), [litellm-ops-guide.md](./litellm-ops-guide.md)

## 1. Purpose & Scope

This doc is the outcome of the ticket to investigate how Claude Code should be installed and configured on AWS Workspaces under admin control.

It answers, per aspect raised in the ticket:

1. **Security** — what do we lock down, and how
2. **Keeping things up to date** — how do we own the upgrade cadence
3. **Model availability** — how do we force all traffic through our internal LiteLLM proxy
4. **Marketplace / plugin availability** — how do we constrain what plugins can be installed
5. **MCP availability** — how do we whitelist the MCP servers we consider safe

For each, a recommendation and the rationale behind it. A complete example `managed-settings.json` is at the end.

**Out of scope:** the Ansible role itself, the Jira pipeline that issues LiteLLM keys, and the AWS Workspaces bundle-build process. Those are downstream implementation tasks that consume the recommendations here.

## 2. Background — How Admin Control Works in Claude Code

Claude Code reads settings from multiple scopes. The precedence order (highest first) is:

1. **Managed settings** — admin-controlled, cannot be overridden
2. CLI flags
3. Project-local settings (`.claude/settings.local.json`)
4. Project-shared settings (`.claude/settings.json`)
5. User settings (`~/.claude/settings.json`)

On Linux (the AWS Workspaces target OS), managed settings live at:

```
/etc/claude-code/managed-settings.json        # primary policy file
/etc/claude-code/managed-settings.d/*.json    # drop-in fragments (merged)
/etc/claude-code/managed-mcp.json             # MCP server policies
```

Ansible should manage these via the drop-in directory — one file per concern (network, permissions, plugins, MCP) gives clean diffs and lets us layer role-specific overlays later.

### The one thing that matters most

By default, managed settings **merge** with user settings. A user can add an allow rule and expand what Claude Code can do. To make the lockdown real, we have to explicitly flip a small set of "managed-only" switches that reject user-scope additions:

| Switch | Without it... |
|---|---|
| `allowManagedPermissionRulesOnly: true` | Users can add their own allow/ask rules |
| `allowManagedHooksOnly: true` | Users can register hooks that bypass policy |
| `allowManagedMcpServersOnly: true` | Users can add any MCP server they like |
| `sandbox.network.allowManagedDomainsOnly: true` | Users can whitelist new domains |
| `sandbox.filesystem.allowManagedReadPathsOnly: true` | Users can expand filesystem read access |
| `permissions.disableBypassPermissionsMode: "disable"` | One flag (`--dangerously-skip-permissions`) defeats the whole permission system |

These are the load-bearing switches for this design. Every recommendation below assumes they're set.

Two other useful primitives:

- **Deny always wins.** A managed `deny` rule cannot be overridden by anything — not by CLI flags, hooks, or user settings. Prefer deny-first design over trying to enumerate every allowed thing.
- **`apiKeyHelper` script** — a script path we can set so Claude Code calls it to fetch credentials dynamically. Not needed for our current design (users will `export ANTHROPIC_AUTH_TOKEN` from the onboarding email), but worth knowing exists if we ever move to short-lived tokens.

## 3. Recommendations by Aspect

### 3.1 Security

**Goal:** minimise blast radius if a user runs a malicious prompt, a prompt-injected tool result, or an untrusted plugin.

#### Recommendations

| Setting | Value | Rationale |
|---|---|---|
| `allowManagedPermissionRulesOnly` | `true` | Without this, the whole permission scheme is advisory |
| `allowManagedHooksOnly` | `true` | Blocks users from defining hooks that rubber-stamp tool calls |
| `permissions.disableBypassPermissionsMode` | `"disable"` | Blocks `--dangerously-skip-permissions` — otherwise a single flag defeats everything |
| `permissions.disableAutoMode` | `"disable"` | Restricts operating modes to `default` / `plan` / `dontAsk` |
| `permissions.deny` | see below | Deny-list for high-risk Bash patterns and sensitive files |
| `sandbox.network.allowedDomains` | internal + minimal external | Claude Code's Bash sandbox enforces this at process level |
| `sandbox.network.allowManagedDomainsOnly` | `true` | Users cannot add domains |
| `sandbox.filesystem.denyRead` | secret dirs | Backstop in case a user project settings file allows too much |

Recommended `permissions.deny` baseline (expand as learnings come in):

```
Bash(curl *)
Bash(wget *)
Bash(rm -rf *)
Bash(ssh *)
Bash(scp *)
Bash(dd *)
Read(~/.ssh/**)
Read(~/.aws/**)
Read(**/.env)
Read(**/.env.*)
Read(**/credentials*)
Read(**/*_rsa)
Read(**/*.pem)
```

Recommended `allowedDomains` baseline:

```
litellm-gateway.internal.company.com
*.internal.company.com
github.com
*.github.com
registry.npmjs.org
pypi.org
files.pythonhosted.org
```

Anything else should require a change-controlled update to managed settings.

**Audit logging (optional, v2):** if we want an audit trail of tool invocations, a forced `PreToolUse` hook in managed config can stream to CloudWatch/S3. Requires `allowManagedHooksOnly: true` so the user can't unhook it. Leaving this out of v1 scope — User-Agent auto-tagging in `LiteLLM_SpendLogs` already gives us API-level attribution.

### 3.2 Keeping Things Up to Date

**Goal:** admins own the version, not users. Predictable, auditable, rollback-able.

#### Recommendations

| Setting | Value | Rationale |
|---|---|---|
| `autoUpdatesChannel` | `"disabled"` | Golden image controls version; disables in-place npm updates |
| `env.CLAUDE_CODE_DISABLE_AUTOUPDATER` | `"1"` | Belt-and-braces — env var also suppresses the updater |
| `minimumVersion` | `"X.Y.Z"` | Reject execution if somehow a downgrade happens; set to the bundle version |

**Upgrade path:**
1. Test new Claude Code version on a staging Workspace bundle
2. Rebuild golden image with pinned version
3. Roll out to user Workspaces via Workspaces image-update (scheduled, user-notified)
4. Bump `minimumVersion` in the managed settings drop-in

**Why not let it auto-update?**
- Plugin/marketplace/MCP compatibility regressions have happened historically
- Permission-rule semantics have changed between minor versions
- We want change to be correlated with a controlled event, not silent

### 3.3 Model Availability — Forcing LiteLLM

**Goal:** all Claude Code traffic goes through our LiteLLM proxy. No direct `api.anthropic.com` calls. Users see a curated model list.

#### Recommendations

| Setting | Value | Rationale |
|---|---|---|
| `env.ANTHROPIC_BASE_URL` | `https://litellm-gateway.internal.company.com/v1` | Redirects all API traffic to our proxy |
| `availableModels` | curated list | Restricts UI model selection to what LiteLLM has wired up |
| `model` | default choice (e.g. `claude-sonnet-4-6`) | Sets the initial selection |
| `env.CLAUDE_CODE_DISABLE_TELEMETRY` | `"1"` | No analytics leakage to Anthropic; we log at the proxy instead |
| `env.CLAUDE_CODE_DISABLE_ERROR_REPORTING` | `"1"` | No crash dumps to Anthropic |

Authentication:
- Users run `export ANTHROPIC_AUTH_TOKEN=sk-...` using the LiteLLM virtual key delivered in their onboarding email.
- `ANTHROPIC_AUTH_TOKEN` sends `Authorization: Bearer <token>` — LiteLLM accepts this natively.
- **Do not** also set `ANTHROPIC_API_KEY`. Both being present is a footgun (precedence is `ANTHROPIC_AUTH_TOKEN` > `ANTHROPIC_API_KEY`, but a user who thinks they're "fixing" auth by setting both will be confused).

**Network-layer enforcement:** block `api.anthropic.com` at the VPC/firewall level. `ANTHROPIC_BASE_URL` is a config override — a user who `unset`s it on their shell reverts to direct Anthropic. The firewall rule is the actual enforcement; the env var is the ergonomic default.

**LiteLLM prerequisites (already done or tracked elsewhere):**
- Every model in `availableModels` must have a matching `model_name` entry in the LiteLLM config
- For Bedrock models, `custom_llm_provider: "bedrock_converse"` and model IDs like `au.anthropic.claude-sonnet-4-6` (no `v1:0` suffix, no `bedrock/` prefix) — see [litellm-work.md](../litellm-work.md)
- User-Agent auto-tagging will tag Claude Code calls in `LiteLLM_SpendLogs` with no extra config

Recommended initial `availableModels`:
```
claude-opus-4-7
claude-sonnet-4-6
claude-haiku-4-5-20251001
```

Keep this list short. More options = more LiteLLM model config to maintain.

### 3.4 Marketplace / Plugin Availability

**Goal:** users get curated, approved plugins (starting with Superpowers). Can't install arbitrary community plugins.

#### Recommendations

| Setting | Value | Rationale |
|---|---|---|
| `strictKnownMarketplaces` | internal GitHub repo only | Only our marketplace can be added |
| `blockedMarketplaces` | `["claude-plugins-official"]` | Explicit block on the public marketplace |
| `enabledPlugins` | curated set (e.g. `superpowers`) | Pre-enabled, users cannot disable |

**v1 approach — "bake in" path:**
For the initial rollout, bake the plugin files directly into the Workspaces golden image under `/etc/claude-code/plugins/`. Updates require a bundle rebuild, which is acceptable at v1 cadence.

**v2 approach — internal marketplace:**
Stand up an internal GitHub repo that mirrors the plugins we've vetted (starting with Superpowers — OC15141355 already has this on personal kit, worth reviewing what's appropriate for a work context first). Point `strictKnownMarketplaces` at it. Users get updates when we cut them, not when upstream ships.

**Why this matters:**
Plugins can register skills, hooks, MCP servers, and agents. An unvetted plugin has the full Claude Code surface to play with. Pinning the marketplace is the difference between "we approved this code" and "a user installed something from a GitHub gist."

**Note on Superpowers specifically:** review the skill set before enabling wholesale. Many skills assume a personal dev workflow (TDD, brainstorming, git worktrees) which may or may not match how work teams operate. Consider starting with a subset.

### 3.5 MCP Availability

**Goal:** whitelist only the MCP servers we've reviewed.

#### Recommendations

| Setting | Value | Rationale |
|---|---|---|
| `allowManagedMcpServersOnly` | `true` | Users can't add MCP servers outside the whitelist |
| `allowedMcpServers` | approved servers only | Explicit whitelist |
| `deniedMcpServers` | known-bad or unneeded | Defence in depth |

**v1 whitelist — propose:**
- `filesystem` (built-in, scoped to working dir)
- None else, until business cases come in

**Review questions for each proposed MCP server:**
1. What data does it read / write?
2. Does it need credentials? Where do those live?
3. What's the blast radius if a prompt injection triggers its tools?
4. Is it read-only or does it mutate?
5. Who maintains it (Anthropic, a major vendor, a random GitHub user)?

MCP tool-level permissions can scope further — e.g. allow `mcp__kubernetes__get_*` and `mcp__kubernetes__describe_*` but deny `mcp__kubernetes__delete_*`. Use this when an MCP server has both read and mutating tools and we only want the read side.

**Out of scope for v1 but worth flagging:**
credential delivery for MCP servers (how do users get, say, a scoped Grafana token into their Workspaces MCP config) is a separate mini-design. Don't ship MCP servers that need per-user secrets until we've solved that.

## 4. Complete `managed-settings.json` — Worked Example

This is the v1 starting point. Ansible drop-in at `/etc/claude-code/managed-settings.d/00-policy.json`:

```json
{
  "allowManagedPermissionRulesOnly": true,
  "allowManagedHooksOnly": true,
  "allowManagedMcpServersOnly": true,

  "autoUpdatesChannel": "disabled",
  "minimumVersion": "X.Y.Z",

  "model": "claude-sonnet-4-6",
  "availableModels": [
    "claude-opus-4-7",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001"
  ],

  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm-gateway.internal.company.com/v1",
    "CLAUDE_CODE_DISABLE_TELEMETRY": "1",
    "CLAUDE_CODE_DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_ERROR_REPORTING": "1"
  },

  "permissions": {
    "defaultMode": "default",
    "disableBypassPermissionsMode": "disable",
    "disableAutoMode": "disable",
    "deny": [
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(rm -rf *)",
      "Bash(ssh *)",
      "Bash(scp *)",
      "Bash(dd *)",
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/credentials*)",
      "Read(**/*_rsa)",
      "Read(**/*.pem)"
    ],
    "allow": [
      "Bash(git *)",
      "Bash(npm *)",
      "Bash(node *)",
      "Bash(python *)",
      "Bash(pip *)",
      "Bash(pytest *)"
    ]
  },

  "sandbox": {
    "network": {
      "allowedDomains": [
        "litellm-gateway.internal.company.com",
        "*.internal.company.com",
        "github.com",
        "*.github.com",
        "registry.npmjs.org",
        "pypi.org",
        "files.pythonhosted.org"
      ]
    },
    "filesystem": {
      "denyRead": [
        "~/.ssh",
        "~/.aws",
        "~/.config/gcloud"
      ]
    }
  },
  "sandbox.network.allowManagedDomainsOnly": true,
  "sandbox.filesystem.allowManagedReadPathsOnly": false,

  "enabledPlugins": {},
  "strictKnownMarketplaces": [
    { "source": "github", "repo": "our-org/claude-plugins-internal" }
  ],
  "blockedMarketplaces": ["claude-plugins-official"],

  "allowedMcpServers": {
    "filesystem": { "disabled": false }
  },
  "deniedMcpServers": []
}
```

Note: `allowManagedReadPathsOnly` is left `false` at v1 so users can work freely in their own repos — tighten once we have confidence in the path patterns users need.

## 5. Open Decisions Before Implementation

These need product/security sign-off before the Ansible work starts:

1. **Plugin marketplace — bake vs internal repo?** Recommend bake for v1, migrate to internal repo in v2.
2. **Superpowers in v1?** Review skill set for work-context fit before enabling. Personal-workflow skills may be noise.
3. **MCP whitelist scope.** v1 proposal is "filesystem only." Does anyone have a concrete use case that would change this?
4. **PreToolUse audit hook.** Worth the engineering for v1, or defer until we see how users actually use this?
5. **Update cadence target.** Monthly bundle rebuild? Quarterly? Security-only? Set expectations upfront.
6. **Rollback plan.** If a new Claude Code version breaks something, what's the process — old AMI, feature-flag override, revert single setting?

## 6. References

- Claude Code settings & precedence: https://code.claude.com/docs/en/settings.md
- Claude Code permissions (deepest reference): https://code.claude.com/docs/en/permissions.md
- Claude Code hooks: https://code.claude.com/docs/en/hooks.md
- Claude Code authentication: https://code.claude.com/docs/en/authentication.md
- Claude Code plugins & marketplaces: https://code.claude.com/docs/en/plugins.md
- Claude Code MCP: https://code.claude.com/docs/en/mcp.md
- Claude Code sandboxing: https://code.claude.com/docs/en/sandboxing.md
- Internal: [litellm-governance.md](./litellm-governance.md), [litellm-next-phase.md](./litellm-next-phase.md)
