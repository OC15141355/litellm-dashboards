#!/bin/bash
# LiteLLM Admin CLI
# Admin toolkit for managing teams, users, keys, and auditing LiteLLM deployments
#
# Usage: ./litellm-admin.sh <command> [options]
#
# Configuration:
#   Set these environment variables or they will be prompted:
#   - LITELLM_API_BASE: Base URL of LiteLLM (e.g., https://litellm.example.com)
#   - LITELLM_MASTER_KEY: Master key for admin operations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
check_deps() {
    for cmd in curl jq; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}Error: $cmd is required but not installed.${NC}"
            exit 1
        fi
    done
}

# Load config
load_config() {
    if [ -z "$LITELLM_API_BASE" ]; then
        echo -e "${YELLOW}LITELLM_API_BASE not set.${NC}"
        read -p "Enter LiteLLM API Base URL: " LITELLM_API_BASE
    fi

    if [ -z "$LITELLM_MASTER_KEY" ]; then
        echo -e "${YELLOW}LITELLM_MASTER_KEY not set.${NC}"
        read -sp "Enter Master Key: " LITELLM_MASTER_KEY
        echo
    fi

    # Remove trailing slash
    LITELLM_API_BASE="${LITELLM_API_BASE%/}"
}

# API helper
# Set LITELLM_INSECURE=1 to skip SSL verification
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3

    local url="${LITELLM_API_BASE}${endpoint}"
    local curl_opts="-s"

    # Skip SSL verification if requested (for self-signed certs)
    if [ "${LITELLM_INSECURE:-0}" = "1" ]; then
        curl_opts="$curl_opts -k"
    fi

    if [ -n "$data" ]; then
        curl $curl_opts -X "$method" "$url" \
            -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl $curl_opts -X "$method" "$url" \
            -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
            -H "Content-Type: application/json"
    fi
}

# Resolve team alias to team_id (allows using either)
resolve_team() {
    local input=$1
    # If it looks like a UUID, return as-is
    if [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$input"
        return
    fi
    # Otherwise, look up by alias
    local team_id=$(api_call GET "/team/list" | jq -r ".[] | select(.team_alias == \"$input\") | .team_id")
    if [ -z "$team_id" ]; then
        echo -e "${RED}Error: Team '$input' not found${NC}" >&2
        return 1
    fi
    echo "$team_id"
}

# ==================== TEAM COMMANDS ====================

team_list() {
    echo -e "${BLUE}Listing all teams...${NC}"
    api_call GET "/team/list" | jq -r '.[] | "\(.team_id)\t\(.team_alias // "N/A")\t$\(.max_budget // "unlimited")\t\(.models // [] | length) models"' | \
        column -t -s $'\t'
}

team_info() {
    local input=$1
    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 team info <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Team details for: $team_id${NC}"
    api_call GET "/team/info?team_id=${team_id}" | jq '.'
}

team_create() {
    local team_alias=$1
    local max_budget=$2
    local models=$3

    if [ -z "$team_alias" ]; then
        echo -e "${RED}Usage: $0 team create <team_alias> [max_budget] [models_comma_separated]${NC}"
        exit 1
    fi

    local payload="{\"team_alias\": \"${team_alias}\""

    if [ -n "$max_budget" ]; then
        payload="${payload}, \"max_budget\": ${max_budget}"
    fi

    if [ -n "$models" ]; then
        # Convert comma-separated to JSON array
        local models_json=$(echo "$models" | jq -R 'split(",")')
        payload="${payload}, \"models\": ${models_json}"
    fi

    payload="${payload}}"

    echo -e "${BLUE}Creating team: $team_alias${NC}"
    api_call POST "/team/new" "$payload" | jq '.'
}

team_update() {
    local input=$1
    local field=$2
    local value=$3

    if [ -z "$input" ] || [ -z "$field" ] || [ -z "$value" ]; then
        echo -e "${RED}Usage: $0 team update <team_id|team_alias> <field> <value>${NC}"
        echo "Fields: team_alias, max_budget, budget_duration, models"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    local payload="{\"team_id\": \"${team_id}\", \"${field}\": "

    # Handle different field types
    case $field in
        max_budget)
            payload="${payload}${value}}"
            ;;
        models)
            local models_json=$(echo "$value" | jq -R 'split(",")')
            payload="${payload}${models_json}}"
            ;;
        *)
            payload="${payload}\"${value}\"}"
            ;;
    esac

    echo -e "${BLUE}Updating team: $team_id${NC}"
    api_call POST "/team/update" "$payload" | jq '.'
}

team_delete() {
    local input=$1
    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 team delete <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${YELLOW}Are you sure you want to delete team $input ($team_id)? (y/N)${NC}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    echo -e "${BLUE}Deleting team: $team_id${NC}"
    api_call POST "/team/delete" "{\"team_ids\": [\"${team_id}\"]}" | jq '.'
}

team_members() {
    local input=$1
    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 team members <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Members of team: $input${NC}"
    api_call GET "/team/info?team_id=${team_id}" | jq -r '.members_with_roles[]? | "\(.user_id)\t\(.role)"' | column -t -s $'\t'
}

# ==================== KEY COMMANDS ====================

key_list() {
    local input=$1

    echo -e "${BLUE}Listing keys...${NC}"
    # Keys are nested in team objects, so we pull from /team/list
    if [ -n "$input" ]; then
        local team_id=$(resolve_team "$input") || exit 1
        api_call GET "/team/info?team_id=${team_id}" | jq -r '.keys[]? | "\(.token[0:20])...\t\(.key_alias // "N/A")\t\(.team_id // "N/A")\t$\(.max_budget // "unlimited")\t$\(.spend // 0)"' | column -t -s $'\t'
    else
        api_call GET "/team/list" | jq -r '.[] | .team_alias as $team | .keys[]? | "\(.token[0:20])...\t\(.key_alias // "N/A")\t\($team // "N/A")\t$\(.max_budget // "unlimited")\t$\(.spend // 0)"' | column -t -s $'\t'
    fi
}

key_info() {
    local key=$1
    if [ -z "$key" ]; then
        echo -e "${RED}Usage: $0 key info <key>${NC}"
        exit 1
    fi

    echo -e "${BLUE}Key details...${NC}"
    api_call GET "/key/info?key=${key}" | jq '.'
}

key_create() {
    local input=$1
    local key_alias=$2
    local max_budget=$3
    local models=$4

    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 key create <team_id|team_alias> [key_alias] [max_budget] [models]${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    local payload="{\"team_id\": \"${team_id}\""

    if [ -n "$key_alias" ]; then
        payload="${payload}, \"key_alias\": \"${key_alias}\""
    fi

    if [ -n "$max_budget" ]; then
        payload="${payload}, \"max_budget\": ${max_budget}"
    fi

    if [ -n "$models" ]; then
        local models_json=$(echo "$models" | jq -R 'split(",")')
        payload="${payload}, \"models\": ${models_json}"
    fi

    payload="${payload}}"

    echo -e "${BLUE}Creating key for team: $team_id${NC}"
    result=$(api_call POST "/key/generate" "$payload")
    echo "$result" | jq '.'

    # Extract and highlight the key
    key=$(echo "$result" | jq -r '.key // empty')
    if [ -n "$key" ]; then
        echo -e "\n${GREEN}New API Key: ${key}${NC}"
        echo -e "${YELLOW}Save this key! It cannot be retrieved later.${NC}"
    fi
}

key_update() {
    local key=$1
    local field=$2
    local value=$3

    if [ -z "$key" ] || [ -z "$field" ] || [ -z "$value" ]; then
        echo -e "${RED}Usage: $0 key update <key> <field> <value>${NC}"
        echo "Fields: key_alias, max_budget, team_id, models"
        exit 1
    fi

    local payload="{\"key\": \"${key}\", \"${field}\": "

    case $field in
        max_budget)
            payload="${payload}${value}}"
            ;;
        models)
            local models_json=$(echo "$value" | jq -R 'split(",")')
            payload="${payload}${models_json}}"
            ;;
        *)
            payload="${payload}\"${value}\"}"
            ;;
    esac

    echo -e "${BLUE}Updating key...${NC}"
    api_call POST "/key/update" "$payload" | jq '.'
}

key_delete() {
    local key=$1
    if [ -z "$key" ]; then
        echo -e "${RED}Usage: $0 key delete <key>${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Are you sure you want to delete this key? (y/N)${NC}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    echo -e "${BLUE}Deleting key...${NC}"
    api_call POST "/key/delete" "{\"keys\": [\"${key}\"]}" | jq '.'
}

key_move() {
    local key=$1
    local input=$2

    if [ -z "$key" ] || [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 key move <key> <new_team_id|new_team_alias>${NC}"
        exit 1
    fi

    local new_team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Moving key to team: $input ($new_team_id)${NC}"
    api_call POST "/key/update" "{\"key\": \"${key}\", \"team_id\": \"${new_team_id}\"}" | jq '.'
}

# ==================== USER COMMANDS ====================

user_list() {
    echo -e "${BLUE}Listing users...${NC}"
    api_call GET "/user/list" | jq -r '.users[]? | "\(.user_id)\t\(.user_email // "N/A")\t\(.teams // [] | join(","))"' | column -t -s $'\t'
}

user_info() {
    local user_id=$1
    if [ -z "$user_id" ]; then
        echo -e "${RED}Usage: $0 user info <user_id>${NC}"
        exit 1
    fi

    echo -e "${BLUE}User details...${NC}"
    api_call GET "/user/info?user_id=${user_id}" | jq '.'
}

user_create() {
    local user_email=$1
    local team_id=$2

    if [ -z "$user_email" ]; then
        echo -e "${RED}Usage: $0 user create <user_email> [team_id]${NC}"
        exit 1
    fi

    local payload="{\"user_email\": \"${user_email}\""

    if [ -n "$team_id" ]; then
        payload="${payload}, \"teams\": [\"${team_id}\"]"
    fi

    payload="${payload}}"

    echo -e "${BLUE}Creating user: $user_email${NC}"
    api_call POST "/user/new" "$payload" | jq '.'
}

user_add_to_team() {
    local user_id=$1
    local input=$2
    local role=${3:-"user"}

    if [ -z "$user_id" ] || [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 user add-to-team <user_id> <team_id|team_alias> [role]${NC}"
        echo "Roles: user, admin"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Adding user $user_id to team $input as $role${NC}"
    api_call POST "/team/member_add" "{\"team_id\": \"${team_id}\", \"member\": {\"user_id\": \"${user_id}\", \"role\": \"${role}\"}}" | jq '.'
}

user_remove_from_team() {
    local user_id=$1
    local input=$2

    if [ -z "$user_id" ] || [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 user remove-from-team <user_id> <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Removing user $user_id from team $input${NC}"
    api_call POST "/team/member_delete" "{\"team_id\": \"${team_id}\", \"user_id\": \"${user_id}\"}" | jq '.'
}

# ==================== AUDIT COMMANDS ====================

audit_spend() {
    local start_date=$1
    local end_date=$2

    if [ -z "$start_date" ]; then
        # Default to last 30 days
        start_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d "30 days ago" +%Y-%m-%d)
    fi

    if [ -z "$end_date" ]; then
        end_date=$(date +%Y-%m-%d)
    fi

    echo -e "${BLUE}Spend report from $start_date to $end_date${NC}"
    api_call GET "/spend/logs?start_date=${start_date}&end_date=${end_date}" | jq '.'
}

audit_team_spend() {
    local input=$1

    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 audit team-spend <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Spend for team: $input${NC}"
    api_call GET "/team/info?team_id=${team_id}" | jq '.team_info | {team_alias: .team_alias, spend: (.spend // 0), max_budget: (.max_budget // "unlimited"), budget_remaining: (if .max_budget then (.max_budget - (.spend // 0)) else "unlimited" end)}'
}

audit_all_teams() {
    echo -e "${BLUE}All teams spend summary${NC}"
    api_call GET "/team/list" | jq -r '.[] | "\(.team_alias // .team_id)\t$\(.spend // 0)\t$\(.max_budget // "unlimited")"' | \
        (echo -e "TEAM\tSPEND\tBUDGET" && cat) | column -t -s $'\t'
}

audit_models() {
    echo -e "${BLUE}Model usage summary${NC}"
    api_call GET "/model/info" | jq '.'
}

audit_full() {
    echo -e "${BLUE}Full Audit Report${NC}"
    echo "================="
    echo ""

    api_call GET "/team/list" | jq -r '
        .[] |
        "Team: \(.team_alias // .team_id) [$\(.spend // 0)/\(.max_budget // "unlimited")]",
        "  Budget Duration: \(.budget_duration // "none")",
        "  Models: \(.models // [] | join(", "))",
        "  Members:",
        (.members_with_roles // [] | if length == 0 then "    (no members)" else .[] | "    - \(.user_id // "unknown") (\(.role // "user"))" end),
        "  Keys:",
        (.keys // [] | if length == 0 then "    (no keys)" else .[] | "    - \(.key_alias // .key_name // "unnamed") | $\(.spend // 0) spent | limit: $\(.max_budget // "unlimited")" end),
        ""
    '
}

# ==================== HEALTH & INFO ====================

health() {
    echo -e "${BLUE}Checking LiteLLM health...${NC}"
    api_call GET "/health" | jq '.'
}

models() {
    echo -e "${BLUE}Available models...${NC}"
    api_call GET "/models" | jq -r '.data[]?.id' | sort
}

# ==================== MAIN ====================

show_help() {
    cat << EOF
LiteLLM Admin CLI

Usage: $0 <command> <subcommand> [options]

Note: Team commands accept either team_id (UUID) or team_alias (name).

Commands:
  team list                           List all teams
  team info <team>                    Show team details
  team create <alias> [budget] [models]   Create a new team
  team update <team> <field> <value>  Update team field
  team delete <team>                  Delete a team
  team members <team>                 List team members

  key list [team]                     List keys (optionally filter by team)
  key info <key>                      Show key details
  key create <team> [alias] [budget] [models]   Create a key
  key update <key> <field> <value>    Update key field
  key delete <key>                    Delete a key
  key move <key> <new_team>           Move key to different team

  user list                           List all users
  user info <user_id>                 Show user details
  user create <email> [team]          Create a user
  user add-to-team <user_id> <team> [role]   Add user to team
  user remove-from-team <user_id> <team>     Remove user from team

  audit spend [start_date] [end_date]   Spend report for date range
  audit team-spend <team>               Spend report for a team
  audit all-teams                       Spend summary for all teams
  audit full                            Full audit (teams, members, keys)
  audit models                          Model usage summary

  health                              Check LiteLLM health
  models                              List available models

Environment Variables:
  LITELLM_API_BASE     Base URL of LiteLLM instance
  LITELLM_MASTER_KEY   Master API key for admin operations
  LITELLM_INSECURE     Set to 1 to skip SSL verification

Examples:
  $0 team create "Engineering" 500 "gpt-4,claude-3-sonnet"
  $0 team info Engineering              # by alias
  $0 key create Engineering "dev-key" 100
  $0 key list Engineering
  $0 audit team-spend Engineering
  $0 audit full
  $0 audit all-teams
EOF
}

main() {
    check_deps
    load_config

    local command=$1
    local subcommand=$2
    shift 2 2>/dev/null || true

    case "$command" in
        team)
            case "$subcommand" in
                list) team_list ;;
                info) team_info "$@" ;;
                create) team_create "$@" ;;
                update) team_update "$@" ;;
                delete) team_delete "$@" ;;
                members) team_members "$@" ;;
                *) show_help; exit 1 ;;
            esac
            ;;
        key)
            case "$subcommand" in
                list) key_list "$@" ;;
                info) key_info "$@" ;;
                create) key_create "$@" ;;
                update) key_update "$@" ;;
                delete) key_delete "$@" ;;
                move) key_move "$@" ;;
                *) show_help; exit 1 ;;
            esac
            ;;
        user)
            case "$subcommand" in
                list) user_list ;;
                info) user_info "$@" ;;
                create) user_create "$@" ;;
                add-to-team) user_add_to_team "$@" ;;
                remove-from-team) user_remove_from_team "$@" ;;
                *) show_help; exit 1 ;;
            esac
            ;;
        audit)
            case "$subcommand" in
                spend) audit_spend "$@" ;;
                team-spend) audit_team_spend "$@" ;;
                all-teams) audit_all_teams ;;
                full) audit_full ;;
                models) audit_models ;;
                *) show_help; exit 1 ;;
            esac
            ;;
        health) health ;;
        models) models ;;
        help|--help|-h) show_help ;;
        *) show_help; exit 1 ;;
    esac
}

main "$@"
