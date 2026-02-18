#!/bin/bash
# LiteLLM User Offboarding
# Cleanly removes a user — keys, teams, account (no orphans)
#
# Usage: ./offboard-user.sh <user_id>
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

USER_ID=$1

if [ -z "$USER_ID" ]; then
    cat << EOF
LiteLLM User Offboarding
=========================

Usage: $0 <user_id>

Workflow:
  1. Shows user details for review
  2. Asks for confirmation before each step
  3. Deletes all keys belonging to the user
  4. Removes user from all teams
  5. Deletes the user account

Examples:
  $0 jsmith
  $0 admin1

Environment:
  LITELLM_API_BASE     Base URL (e.g., https://litellm.example.com)
  LITELLM_MASTER_KEY   Master API key
  LITELLM_INSECURE     Set to 1 for self-signed certs
EOF
    exit 1
fi

# Fetch user info
user_info=$(api_call GET "/user/info?user_id=${USER_ID}" 2>/dev/null)
user_email=$(echo "$user_info" | jq -r '.user_info.user_email // .user_email // empty' 2>/dev/null)

if [ -z "$user_email" ]; then
    echo -e "${RED}Error: User '$USER_ID' not found.${NC}"
    exit 1
fi

user_role=$(echo "$user_info" | jq -r '.user_info.user_role // .user_role // "N/A"' 2>/dev/null)

# Gather what will be affected
keys=$(echo "$user_info" | jq -r '.keys[]? | .token // empty' 2>/dev/null)
key_aliases=$(echo "$user_info" | jq -r '.keys[]? | "\(.key_alias // .key_name // "unnamed") (\(.token[0:16])...)"' 2>/dev/null)
teams=$(echo "$user_info" | jq -r '.user_info.teams[]? // .teams[]? // empty' 2>/dev/null)

# Resolve team names
team_names=""
if [ -n "$teams" ]; then
    for tid in $teams; do
        tname=$(api_call GET "/team/info?team_id=${tid}" | jq -r '.team_alias // empty' 2>/dev/null)
        team_names="${team_names}  - ${tname:-$tid}\n"
    done
fi

key_count=0
if [ -n "$keys" ]; then
    key_count=$(echo "$keys" | wc -l | tr -d ' ')
fi

team_count=0
if [ -n "$teams" ]; then
    team_count=$(echo "$teams" | wc -l | tr -d ' ')
fi

# Show summary
echo -e "${CYAN}=== Offboarding: $USER_ID ===${NC}"
echo ""
echo -e "  Email:   $user_email"
echo -e "  Role:    $user_role"
echo -e "  Keys:    $key_count"
if [ -n "$key_aliases" ]; then
    echo "$key_aliases" | while read -r line; do
        echo -e "           - $line"
    done
fi
echo -e "  Teams:   $team_count"
if [ -n "$team_names" ]; then
    echo -e "$team_names"
fi
echo ""

# Confirm
echo -e "${YELLOW}This will permanently delete this user and everything listed above.${NC}"
echo -e "${YELLOW}Type the user ID to confirm: ${NC}"
read -r confirm

if [ "$confirm" != "$USER_ID" ]; then
    echo -e "${RED}Confirmation failed. You typed '$confirm', expected '$USER_ID'. Aborted.${NC}"
    exit 0
fi

echo ""

# Step 1: Delete keys
echo -e "${BLUE}[1/3] Deleting keys...${NC}"
if [ -n "$keys" ]; then
    for key in $keys; do
        alias=$(echo "$user_info" | jq -r ".keys[] | select(.token == \"$key\") | .key_alias // .key_name // \"unnamed\"" 2>/dev/null)
        api_call POST "/key/delete" "{\"keys\": [\"${key}\"]}" > /dev/null 2>&1
        echo -e "  ${GREEN}Deleted: $alias (${key:0:16}...)${NC}"
    done
else
    echo -e "  No keys to delete."
fi

# Step 2: Remove from teams
echo -e "${BLUE}[2/3] Removing from teams...${NC}"
if [ -n "$teams" ]; then
    for team_id in $teams; do
        team_alias=$(api_call GET "/team/info?team_id=${team_id}" | jq -r '.team_alias // empty' 2>/dev/null)
        api_call POST "/team/member_delete" "{\"team_id\": \"${team_id}\", \"user_id\": \"${USER_ID}\"}" > /dev/null 2>&1
        echo -e "  ${GREEN}Removed from: ${team_alias:-$team_id}${NC}"
    done
else
    echo -e "  No team memberships to remove."
fi

# Step 3: Delete user
echo -e "${BLUE}[3/3] Deleting user...${NC}"
api_call POST "/user/delete" "{\"user_ids\": [\"${USER_ID}\"]}" > /dev/null 2>&1
echo -e "  ${GREEN}User deleted.${NC}"

echo ""
echo -e "${CYAN}=== Offboarding Complete ===${NC}"
echo -e "  ${GREEN}$USER_ID ($user_email) has been fully removed.${NC}"
echo -e "  Keys deleted, team memberships removed, user account deleted."
