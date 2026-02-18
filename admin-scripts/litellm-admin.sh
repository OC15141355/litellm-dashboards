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
#   - LITELLM_INSECURE: Set to 1 to skip SSL verification (self-signed certs)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3

    local url="${LITELLM_API_BASE}${endpoint}"
    local curl_opts="-s"

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
    if [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$input"
        return
    fi
    local team_id=$(api_call GET "/team/list" | jq -r ".[] | select(.team_alias == \"$input\") | .team_id")
    if [ -z "$team_id" ]; then
        echo -e "${RED}Error: Team '$input' not found${NC}" >&2
        return 1
    fi
    echo "$team_id"
}

# Validate user role
validate_role() {
    local role=$1
    case "$role" in
        proxy_admin|proxy_admin_viewer|internal_user|internal_user_viewer) return 0 ;;
        *)
            echo -e "${RED}Error: Invalid role '$role'${NC}"
            echo "Valid roles: proxy_admin, proxy_admin_viewer, internal_user, internal_user_viewer"
            return 1
            ;;
    esac
}

# ==================== TEAM COMMANDS ====================

team_list() {
    echo -e "${BLUE}Listing all teams...${NC}"
    api_call GET "/team/list" | jq -r '.[] | "\(.team_id)\t\(.team_alias // "N/A")\t$\(.max_budget // "unlimited")\t\(.models // [] | length) models"' | \
        (echo -e "TEAM_ID\tALIAS\tBUDGET\tMODELS" && cat) | column -t -s $'\t'
}

team_info() {
    local input=$1
    if [ -z "$input" ]; then
        echo -e "${RED}Usage: $0 team info <team_id|team_alias>${NC}"
        exit 1
    fi

    local team_id=$(resolve_team "$input") || exit 1
    echo -e "${BLUE}Team details for: $input${NC}"
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
    api_call GET "/team/info?team_id=${team_id}" | jq -r '.members_with_roles[]? | "\(.user_id)\t\(.role)"' | \
        (echo -e "USER_ID\tROLE" && cat) | column -t -s $'\t'
}

# ==================== KEY COMMANDS ====================

key_list() {
    local input=$1

    echo -e "${BLUE}Listing keys...${NC}"
    if [ -n "$input" ]; then
        local team_id=$(resolve_team "$input") || exit 1
        api_call GET "/team/info?team_id=${team_id}" | jq -r '.keys[]? | "\(.token[0:20])...\t\(.key_alias // "N/A")\t\(.team_id // "N/A")\t$\(.max_budget // "unlimited")\t$\(.spend // 0)"' | \
            (echo -e "KEY\tALIAS\tTEAM\tBUDGET\tSPEND" && cat) | column -t -s $'\t'
    else
        api_call GET "/team/list" | jq -r '.[] | .team_alias as $team | .keys[]? | "\(.token[0:20])...\t\(.key_alias // "N/A")\t\($team // "N/A")\t$\(.max_budget // "unlimited")\t$\(.spend // 0)"' | \
            (echo -e "KEY\tALIAS\tTEAM\tBUDGET\tSPEND" && cat) | column -t -s $'\t'
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
    api_call GET "/user/list" | jq -r '.users[]? | "\(.user_id)\t\(.user_email // "N/A")\t\(.user_role // "N/A")\t\(.teams // [] | join(","))"' | \
        (echo -e "USER_ID\tEMAIL\tROLE\tTEAMS" && cat) | column -t -s $'\t'
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
    local user_id=$1
    local user_email=$2
    local user_role=$3

    if [ -z "$user_id" ] || [ -z "$user_email" ] || [ -z "$user_role" ]; then
        echo -e "${RED}Usage: $0 user create <user_id> <user_email> <role>${NC}"
        echo ""
        echo "Roles:"
        echo "  proxy_admin           Full admin access to LiteLLM UI and API"
        echo "  proxy_admin_viewer    Read-only admin access"
        echo "  internal_user         API access only (bypasses SSO user limit)"
        echo "  internal_user_viewer  Read-only API access"
        exit 1
    fi

    validate_role "$user_role" || exit 1

    local payload="{\"user_id\": \"${user_id}\", \"user_email\": \"${user_email}\", \"user_role\": \"${user_role}\"}"

    echo -e "${BLUE}Creating user: $user_id ($user_email) as $user_role${NC}"
    api_call POST "/user/new" "$payload" | jq '.'
}

# Full onboarding: create user → clean auto-key → add to team → generate proper key
user_onboard() {
    local user_id=$1
    local user_email=$2
    local user_role=$3
    local team=$4
    local key_alias=$5

    if [ -z "$user_id" ] || [ -z "$user_email" ] || [ -z "$user_role" ] || [ -z "$team" ]; then
        echo -e "${RED}Usage: $0 user onboard <user_id> <user_email> <role> <team> [key_alias]${NC}"
        echo ""
        echo "Full onboarding workflow:"
        echo "  1. Creates the user account"
        echo "  2. Removes the auto-generated orphan key"
        echo "  3. Adds user to the specified team"
        echo "  4. Generates a proper team-attributed key"
        echo ""
        echo "Roles: proxy_admin, proxy_admin_viewer, internal_user, internal_user_viewer"
        echo ""
        echo "Examples:"
        echo "  $0 user onboard jsmith john@company.com internal_user engineering"
        echo "  $0 user onboard jsmith john@company.com proxy_admin engineering jsmith-key"
        exit 1
    fi

    validate_role "$user_role" || exit 1

    # Default key alias to user_id
    if [ -z "$key_alias" ]; then
        key_alias="${user_id}-key"
    fi

    local team_id=$(resolve_team "$team") || exit 1

    echo -e "${CYAN}=== Onboarding: $user_id ===${NC}"
    echo ""

    # Step 1: Create user
    echo -e "${BLUE}[1/4] Creating user: $user_id ($user_email) as $user_role${NC}"
    local create_result=$(api_call POST "/user/new" "{\"user_id\": \"${user_id}\", \"user_email\": \"${user_email}\", \"user_role\": \"${user_role}\"}")

    local created_key=$(echo "$create_result" | jq -r '.key // empty')
    if [ -z "$created_key" ]; then
        echo -e "${RED}Failed to create user. Response:${NC}"
        echo "$create_result" | jq '.'
        exit 1
    fi
    echo -e "  ${GREEN}User created.${NC}"

    # Step 2: Delete the auto-generated orphan key
    echo -e "${BLUE}[2/4] Removing auto-generated orphan key${NC}"
    api_call POST "/key/delete" "{\"keys\": [\"${created_key}\"]}" > /dev/null 2>&1
    echo -e "  ${GREEN}Orphan key removed.${NC}"

    # Step 3: Add to team
    echo -e "${BLUE}[3/4] Adding to team: $team${NC}"
    api_call POST "/team/member_add" "{\"team_id\": \"${team_id}\", \"member\": {\"user_id\": \"${user_id}\", \"role\": \"user\"}}" > /dev/null 2>&1
    echo -e "  ${GREEN}Added to team.${NC}"

    # Step 4: Generate proper key with team attribution
    echo -e "${BLUE}[4/4] Generating team key: $key_alias${NC}"
    local key_result=$(api_call POST "/key/generate" "{\"user_id\": \"${user_id}\", \"team_id\": \"${team_id}\", \"key_alias\": \"${key_alias}\"}")

    local new_key=$(echo "$key_result" | jq -r '.key // empty')
    if [ -n "$new_key" ]; then
        echo -e "  ${GREEN}Key generated.${NC}"
    else
        echo -e "  ${RED}Failed to generate key. Response:${NC}"
        echo "$key_result" | jq '.'
        exit 1
    fi

    # Summary
    echo ""
    echo -e "${CYAN}=== Onboarding Complete ===${NC}"
    echo -e "  User ID:    ${GREEN}$user_id${NC}"
    echo -e "  Email:      $user_email"
    echo -e "  Role:       $user_role"
    echo -e "  Team:       $team"
    echo -e "  Key Alias:  $key_alias"
    echo -e "  API Key:    ${GREEN}$new_key${NC}"
    echo ""
    echo -e "${YELLOW}Send the API key to the user securely. It cannot be retrieved later.${NC}"
}

# Full offboarding: delete keys → remove from teams → delete user
user_offboard() {
    local user_id=$1
    if [ -z "$user_id" ]; then
        echo -e "${RED}Usage: $0 user offboard <user_id>${NC}"
        echo ""
        echo "Full offboarding workflow:"
        echo "  1. Deletes all keys belonging to the user"
        echo "  2. Removes user from all teams"
        echo "  3. Deletes the user account"
        exit 1
    fi

    # Verify user exists
    local user_info=$(api_call GET "/user/info?user_id=${user_id}" 2>/dev/null)
    local user_email=$(echo "$user_info" | jq -r '.user_email // empty' 2>/dev/null)

    if [ -z "$user_email" ]; then
        echo -e "${RED}Error: User '$user_id' not found.${NC}"
        exit 1
    fi

    echo -e "${CYAN}=== Offboarding: $user_id ($user_email) ===${NC}"
    echo ""
    echo -e "${YELLOW}This will permanently delete the user and all associated keys. Continue? (y/N)${NC}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    # Step 1: Find and delete all keys
    echo -e "${BLUE}[1/3] Deleting keys...${NC}"
    local keys=$(api_call GET "/key/list?user_id=${user_id}" | jq -r '.[] | .token // empty' 2>/dev/null)

    if [ -n "$keys" ]; then
        local key_count=$(echo "$keys" | wc -l | tr -d ' ')
        echo -e "  Found $key_count key(s)"
        for key in $keys; do
            api_call POST "/key/delete" "{\"keys\": [\"${key}\"]}" > /dev/null 2>&1
            echo -e "  ${GREEN}Deleted: ${key:0:20}...${NC}"
        done
    else
        echo -e "  No keys found."
    fi

    # Step 2: Remove from all teams
    echo -e "${BLUE}[2/3] Removing from teams...${NC}"
    local teams=$(echo "$user_info" | jq -r '.teams[]? // empty' 2>/dev/null)

    if [ -n "$teams" ]; then
        for team_id in $teams; do
            local team_alias=$(api_call GET "/team/info?team_id=${team_id}" | jq -r '.team_alias // empty' 2>/dev/null)
            api_call POST "/team/member_delete" "{\"team_id\": \"${team_id}\", \"user_id\": \"${user_id}\"}" > /dev/null 2>&1
            echo -e "  ${GREEN}Removed from: ${team_alias:-$team_id}${NC}"
        done
    else
        echo -e "  No team memberships found."
    fi

    # Step 3: Delete user
    echo -e "${BLUE}[3/3] Deleting user...${NC}"
    api_call POST "/user/delete" "{\"user_ids\": [\"${user_id}\"]}" > /dev/null 2>&1
    echo -e "  ${GREEN}User deleted.${NC}"

    echo ""
    echo -e "${CYAN}=== Offboarding Complete ===${NC}"
    echo -e "  ${GREEN}$user_id ($user_email) has been fully removed.${NC}"
    echo -e "  Keys deleted, team memberships removed, user account deleted."
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
    cat << 'EOF'
LiteLLM Admin CLI
=================

Usage: litellm-admin.sh <command> <subcommand> [options]

TEAM MANAGEMENT
  team list                                    List all teams
  team info <team>                             Show team details
  team create <alias> [budget] [models]        Create a new team
  team update <team> <field> <value>           Update team (fields: team_alias, max_budget, models)
  team delete <team>                           Delete a team
  team members <team>                          List team members

KEY MANAGEMENT
  key list [team]                              List keys (optionally filter by team)
  key info <key>                               Show key details
  key create <team> [alias] [budget] [models]  Create a key
  key update <key> <field> <value>             Update key (fields: key_alias, max_budget, models)
  key delete <key>                             Delete a key
  key move <key> <new_team>                    Move key to a different team

USER MANAGEMENT
  user list                                    List all users
  user info <user_id>                          Show user details
  user create <user_id> <email> <role>         Create a user
  user add-to-team <user_id> <team> [role]     Add user to team (roles: user, admin)
  user remove-from-team <user_id> <team>       Remove user from team

USER LIFECYCLE (RECOMMENDED)
  user onboard <user_id> <email> <role> <team> [key_alias]
    Full onboarding workflow:
      1. Creates user account
      2. Removes auto-generated orphan key
      3. Adds user to team
      4. Generates a proper team-attributed key
      5. Outputs the key for you to share securely

  user offboard <user_id>
    Full offboarding workflow:
      1. Deletes all keys belonging to the user
      2. Removes user from all teams
      3. Deletes the user account

ROLES
  proxy_admin            Full admin — UI and API access
  proxy_admin_viewer     Read-only admin
  internal_user          API-only access (bypasses SSO 5-user limit)
  internal_user_viewer   Read-only API access

AUDITING
  audit spend [start] [end]                    Spend report for date range (default: last 30 days)
  audit team-spend <team>                      Spend report for a team
  audit all-teams                              Spend summary across all teams
  audit full                                   Full audit (teams, members, keys, spend)
  audit models                                 Model usage summary

SYSTEM
  health                                       Check LiteLLM health
  models                                       List available models

ENVIRONMENT VARIABLES
  LITELLM_API_BASE     Base URL (e.g., https://litellm.example.com)
  LITELLM_MASTER_KEY   Master API key for admin operations
  LITELLM_INSECURE     Set to 1 to skip SSL verification

EXAMPLES
  # Onboard a new developer
  litellm-admin.sh user onboard jsmith john@company.com internal_user engineering

  # Onboard an admin with custom key alias
  litellm-admin.sh user onboard admin1 admin@company.com proxy_admin platform admin1-key

  # Offboard a departing user (clean removal)
  litellm-admin.sh user offboard jsmith

  # Create a team with budget and model access
  litellm-admin.sh team create "Engineering" 500 "claude-sonnet,claude-opus"

  # Generate a shared team key
  litellm-admin.sh key create engineering "ci-cd-key" 100

  # Check spend across all teams
  litellm-admin.sh audit all-teams

  # Full audit report
  litellm-admin.sh audit full

NOTE
  Team arguments accept either team_id (UUID) or team_alias (name).
  Use 'user onboard' and 'user offboard' instead of manual create/delete
  to avoid orphaned keys in the database.
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
                onboard) user_onboard "$@" ;;
                offboard) user_offboard "$@" ;;
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
