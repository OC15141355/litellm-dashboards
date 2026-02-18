#!/bin/bash
# Usage: ./onboard-user.sh <user_id> <email> <role> <team> [key_alias]
# Roles: proxy_admin, proxy_admin_viewer, internal_user, internal_user_viewer
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

resolve_team() {
    [[ "$1" =~ ^[0-9a-f-]{36}$ ]] && echo "$1" && return
    api GET "/team/list" | jq -r ".[] | select(.team_alias==\"$1\") | .team_id"
}

USER_ID=$1; EMAIL=$2; ROLE=$3; TEAM=$4; KEY_ALIAS=${5:-"${1}-key"}

if [[ -z "$USER_ID" || -z "$EMAIL" || -z "$ROLE" || -z "$TEAM" ]]; then
    echo "Usage: $0 <user_id> <email> <role> <team> [key_alias]"
    echo "Roles: proxy_admin, proxy_admin_viewer, internal_user, internal_user_viewer"
    exit 1
fi

TEAM_ID=$(resolve_team "$TEAM") || { echo "Team '$TEAM' not found"; exit 1; }

echo "[1/4] Creating user: $USER_ID ($EMAIL) as $ROLE"
AUTOKEY=$(api POST "/user/new" "{\"user_id\":\"$USER_ID\",\"user_email\":\"$EMAIL\",\"user_role\":\"$ROLE\"}" | jq -r '.key // empty')
[[ -z "$AUTOKEY" ]] && echo "Failed to create user" && exit 1

echo "[2/4] Removing orphan key"
api POST "/key/delete" "{\"keys\":[\"$AUTOKEY\"]}" >/dev/null 2>&1

echo "[3/4] Adding to team: $TEAM"
api POST "/team/member_add" "{\"team_id\":\"$TEAM_ID\",\"member\":{\"user_id\":\"$USER_ID\",\"role\":\"user\"}}" >/dev/null 2>&1

echo "[4/4] Generating key: $KEY_ALIAS"
KEY=$(api POST "/key/generate" "{\"user_id\":\"$USER_ID\",\"team_id\":\"$TEAM_ID\",\"key_alias\":\"$KEY_ALIAS\"}" | jq -r '.key // empty')
[[ -z "$KEY" ]] && echo "Failed to generate key" && exit 1

echo ""
echo "Done! User: $USER_ID | Team: $TEAM | Key: $KEY"
echo "Send the API key securely. It cannot be retrieved later."
