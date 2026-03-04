# LiteLLM Admin Scripts

Standalone bash scripts for managing LiteLLM users, keys, and teams.

## Prerequisites

- `curl`, `jq`
- Set env vars or scripts will prompt:
  ```bash
  export LITELLM_API_BASE="https://your-litellm-instance.com"
  export LITELLM_MASTER_KEY="sk-your-master-key"
  ```

## Scripts

| Script | Usage |
|--------|-------|
| `onboard-user.sh` | `./onboard-user.sh <user_id> <email> <role> <team> [key_alias]` |
| `offboard-user.sh` | `./offboard-user.sh <user_id>` |
| `rotate-key.sh` | `./rotate-key.sh <user_id>` |
| `update-team-models.sh` | `./update-team-models.sh <team>` (no args = list teams) |
| `bulk-onboard.sh` | `./bulk-onboard.sh <csv_file>` |
| `bulk-offboard.sh` | `./bulk-offboard.sh <file>` or `./bulk-offboard.sh --team <team>` |
| `spend-report.sh` | `./spend-report.sh [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--team <team>] [--csv]` |
| `set-team-key-budgets.sh` | `./set-team-key-budgets.sh <team> <max_budget_usd> [budget_duration]` |

**Roles:** `proxy_admin`, `proxy_admin_viewer`, `internal_user`, `internal_user_viewer`

**Teams:** pass a team alias or UUID — scripts resolve aliases automatically.

## Bulk CSV Format

```csv
user_id,email,role,team,key_alias
jsmith,jsmith@company.com,internal_user,engineering,jsmith-key
```

## Legacy

`litellm-admin.sh` and `litellm-admin.py` are the older interactive CLI tools with broader command sets (team/key/user CRUD, audit, spend reporting).
