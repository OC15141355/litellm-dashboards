#!/bin/bash
# LiteLLM User Onboarding
# Creates a user with a clean, team-attributed key (no orphans)
#
# Usage: ./onboard-user.sh <user_id> <email> <role> <team> [key_alias]
#
# Environment:
#   LITELLM_API_BASE    Base URL of LiteLLM
#   LITELLM_MASTER_KEY  Master key for admin operations
#   LITELLM_INSECURE    Set to 1 to skip SSL verification

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load config
if [ -z "$LITELLM_API_BASE" ]; then
    echo -e "${YELLOW}LITELLM_API_BASE not set.${NC}"
    read -p "Enter LiteLLM API Base URL: " LITELLM_API_BASE
fi

if [ -z "$LITELLM_MASTER_KEY" ]; then
    echo -e "${YELLOW}LITELLM_MASTER_KEY not set.${NC}"
    read -sp "Enter Master Key: " LITELLM_MASTER_KEY
    echo
fi

LITELLM_API_BASE="${LITELLM_API_BASE%/}"

# API helper
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    local curl_opts="-s"

    if [ "${LITELLM_INSECURE:-0}" = "1" ]; then
        curl_opts="$curl_opts -k"
    fi

    if [ -n "$data" ]; then
        curl $curl_opts -X "$method" "${LITELLM_API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl $curl_opts -X "$method" "${LITELLM_API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
            -H "Content-Type: application/json"
    fi
}

# Resolve team alias to UUID
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

# Args
USER_ID=$1
USER_EMAIL=$2
USER_ROLE=$3
TEAM=$4
KEY_ALIAS=${5:-"${USER_ID}-key"}

if [ -z "$USER_ID" ] || [ -z "$USER_EMAIL" ] || [ -z "$USER_ROLE" ] || [ -z "$TEAM" ]; then
    cat << EOF
LiteLLM User Onboarding
========================

Usage: $0 <user_id> <email> <role> <team> [key_alias]

Workflow:
  1. Creates the user account
  2. Removes the auto-generated orphan key
  3. Adds user to the specified team
  4. Generates a proper team-attributed key

Roles:
  proxy_admin           Full admin — UI and API access
  proxy_admin_viewer    Read-only admin
  internal_user         API-only access (bypasses SSO 5-user limit)
  internal_user_viewer  Read-only API access

Examples:
  $0 jsmith john@company.com internal_user engineering
  $0 admin1 admin@company.com proxy_admin platform admin1-key

Environment:
  LITELLM_API_BASE     Base URL (e.g., https://litellm.example.com)
  LITELLM_MASTER_KEY   Master API key
  LITELLM_INSECURE     Set to 1 for self-signed certs
EOF
    exit 1
fi

# Validate role
case "$USER_ROLE" in
    proxy_admin|proxy_admin_viewer|internal_user|internal_user_viewer) ;;
    *)
        echo -e "${RED}Error: Invalid role '$USER_ROLE'${NC}"
        echo "Valid roles: proxy_admin, proxy_admin_viewer, internal_user, internal_user_viewer"
        exit 1
        ;;
esac

TEAM_ID=$(resolve_team "$TEAM") || exit 1

echo -e "${CYAN}=== Onboarding: $USER_ID ===${NC}"
echo ""

# Step 1: Create user
echo -e "${BLUE}[1/4] Creating user: $USER_ID ($USER_EMAIL) as $USER_ROLE${NC}"
create_result=$(api_call POST "/user/new" "{\"user_id\": \"${USER_ID}\", \"user_email\": \"${USER_EMAIL}\", \"user_role\": \"${USER_ROLE}\"}")

created_key=$(echo "$create_result" | jq -r '.key // empty')
if [ -z "$created_key" ]; then
    echo -e "${RED}Failed to create user. Response:${NC}"
    echo "$create_result" | jq '.'
    exit 1
fi
echo -e "  ${GREEN}User created.${NC}"

# Step 2: Delete orphan auto-key
echo -e "${BLUE}[2/4] Removing auto-generated orphan key${NC}"
api_call POST "/key/delete" "{\"keys\": [\"${created_key}\"]}" > /dev/null 2>&1
echo -e "  ${GREEN}Orphan key removed.${NC}"

# Step 3: Add to team
echo -e "${BLUE}[3/4] Adding to team: $TEAM${NC}"
api_call POST "/team/member_add" "{\"team_id\": \"${TEAM_ID}\", \"member\": {\"user_id\": \"${USER_ID}\", \"role\": \"user\"}}" > /dev/null 2>&1
echo -e "  ${GREEN}Added to team.${NC}"

# Step 4: Generate proper key
echo -e "${BLUE}[4/4] Generating team key: $KEY_ALIAS${NC}"
key_result=$(api_call POST "/key/generate" "{\"user_id\": \"${USER_ID}\", \"team_id\": \"${TEAM_ID}\", \"key_alias\": \"${KEY_ALIAS}\"}")

new_key=$(echo "$key_result" | jq -r '.key // empty')
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
echo -e "  User ID:    ${GREEN}$USER_ID${NC}"
echo -e "  Email:      $USER_EMAIL"
echo -e "  Role:       $USER_ROLE"
echo -e "  Team:       $TEAM"
echo -e "  Key Alias:  $KEY_ALIAS"
echo -e "  API Key:    ${GREEN}$new_key${NC}"
echo ""
echo -e "${YELLOW}Send the API key to the user securely. It cannot be retrieved later.${NC}"
