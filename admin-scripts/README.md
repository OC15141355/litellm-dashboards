# LiteLLM Admin Scripts

Admin toolkit for managing LiteLLM deployments - teams, users, API keys, and auditing.

## Setup

### Environment Variables

```bash
export LITELLM_API_BASE="https://your-litellm-instance.com"
export LITELLM_MASTER_KEY="sk-your-master-key"
```

### Dependencies

**Bash version:**
- `curl`
- `jq`

**Python version:**
- Python 3.7+
- `requests` library (`pip install requests`)

## Quick Start

```bash
# List all teams
./litellm-admin.sh team list

# Create a new team with $500 budget
./litellm-admin.sh team create "Engineering" 500 "gpt-4,claude-3-sonnet"

# Create an API key for that team
./litellm-admin.sh key create team_abc123 "dev-key" 100

# Check spend across all teams
./litellm-admin.sh audit all-teams
```

## Commands Reference

### Team Management

| Command | Description |
|---------|-------------|
| `team list` | List all teams with IDs, aliases, budgets |
| `team info <team_id>` | Get detailed team information |
| `team create <alias> [budget] [models]` | Create a new team |
| `team update <team_id> <field> <value>` | Update team (alias, budget, models) |
| `team delete <team_id>` | Delete a team (with confirmation) |
| `team members <team_id>` | List team members and their roles |

### API Key Management

| Command | Description |
|---------|-------------|
| `key list [team_id]` | List all keys, optionally filter by team |
| `key info <key>` | Get key details (spend, limits, etc.) |
| `key create <team_id> [alias] [budget] [models]` | Generate new API key |
| `key update <key> <field> <value>` | Update key settings |
| `key delete <key>` | Revoke an API key |
| `key move <key> <new_team_id>` | Move key to different team |

### User Management

| Command | Description |
|---------|-------------|
| `user list` | List all users |
| `user info <user_id>` | Get user details |
| `user create <email> [team_id]` | Create new user |
| `user add-to-team <user_id> <team_id> [role]` | Add user to team |
| `user remove-from-team <user_id> <team_id>` | Remove user from team |

### Audit & Reporting

| Command | Description |
|---------|-------------|
| `audit spend [start] [end]` | Spend logs for date range |
| `audit team-spend <team_id>` | Detailed spend for one team |
| `audit all-teams` | Summary spend across all teams |
| `audit models` | Model usage summary |

### System

| Command | Description |
|---------|-------------|
| `health` | Check LiteLLM health status |
| `models` | List available models |

## Common Workflows

### Onboard a New Team

```bash
# 1. Create the team with monthly budget
./litellm-admin.sh team create "Data Science" 1000

# 2. Create initial API key
./litellm-admin.sh key create team_xxx "ds-primary" 500

# 3. Add team members
./litellm-admin.sh user add-to-team user@company.com team_xxx admin
```

### Move User Between Teams

```bash
# Remove from old team
./litellm-admin.sh user remove-from-team user123 old_team_id

# Add to new team
./litellm-admin.sh user add-to-team user123 new_team_id user
```

### Rotate API Key

```bash
# 1. Create new key with same settings
./litellm-admin.sh key create team_xxx "new-key" 500

# 2. Distribute new key to users

# 3. Delete old key
./litellm-admin.sh key delete sk-old-key
```

### Monthly Cost Review

```bash
# Get all teams spend summary
./litellm-admin.sh audit all-teams

# Detailed breakdown for specific team
./litellm-admin.sh audit team-spend team_xxx

# Export spend logs
./litellm-admin.sh audit spend 2026-01-01 2026-01-31 > january-spend.json
```

### Adjust Team Budget

```bash
# Increase budget
./litellm-admin.sh team update team_xxx max_budget 2000

# Add models access
./litellm-admin.sh team update team_xxx models "gpt-4,gpt-4-turbo,claude-3-opus"
```

## Python Version

The Python version (`litellm-admin.py`) offers the same functionality with additional features:

```bash
# Table output (default)
./litellm-admin.py team list

# JSON output for scripting
./litellm-admin.py team list -o json

# Force delete without confirmation
./litellm-admin.py team delete team_xxx -f
```

### Scripting Example

```python
from litellm_admin import LiteLLMAdmin

admin = LiteLLMAdmin("https://litellm.example.com", "sk-master-key")

# Get all teams over budget
teams = admin.list_teams()
for team in teams:
    if team.get('spend', 0) > team.get('max_budget', float('inf')):
        print(f"OVER BUDGET: {team['team_alias']} - ${team['spend']}")
```

## Troubleshooting

### "Unauthorized" errors
- Verify `LITELLM_MASTER_KEY` is correct
- Ensure key has admin permissions

### Team/Key not found
- Team IDs are UUIDs, not aliases
- Use `team list` to get correct IDs

### Budget not showing
- Team budgets are set on the team, not individual keys
- Key budgets limit individual key spend within team budget
