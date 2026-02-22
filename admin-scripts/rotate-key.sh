#!/bin/bash
# Usage: ./rotate-key.sh <user_id>
# Deletes all existing keys, generates a new one on the same team
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

USER_ID=$1
[[ -z "$USER_ID" ]] && echo "Usage: $0 <user_id>" && exit 1

INFO=$(api GET "/user/info?user_id=${USER_ID}")
EMAIL=$(echo "$INFO" | jq -r '.user_info.user_email // .user_email // empty')
[[ -z "$EMAIL" ]] && echo "User '$USER_ID' not found." && exit 1

KEYS=$(echo "$INFO" | jq -r '.keys[]? | .token // empty')
KEY_COUNT=$([[ -n "$KEYS" ]] && echo "$KEYS" | wc -l | tr -d ' ' || echo 0)
TEAM_ID=$(echo "$INFO" | jq -r '.keys[0]?.team_id // empty')
OLD_ALIAS=$(echo "$INFO" | jq -r '.keys[0]?.key_alias // empty')
KEY_ALIAS=${OLD_ALIAS:-"${USER_ID}-key"}

echo "User:  $USER_ID ($EMAIL)"
echo "Keys:  $KEY_COUNT"
echo "Team:  $TEAM_ID"
echo ""

[[ -z "$TEAM_ID" ]] && echo "No team-attributed key found. Can't rotate without a team." && exit 1

read -p "Rotate keys for $USER_ID? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

echo ""
echo "[1/2] Deleting old keys..."
for key in $KEYS; do
    alias=$(echo "$INFO" | jq -r ".keys[] | select(.token==\"$key\") | .key_alias // \"unnamed\"")
    api POST "/key/delete" "{\"keys\":[\"$key\"]}" >/dev/null 2>&1
    echo "  Deleted: $alias"
done

echo "[2/2] Generating new key: $KEY_ALIAS"
KEY=$(api POST "/key/generate" "{\"user_id\":\"$USER_ID\",\"team_id\":\"$TEAM_ID\",\"key_alias\":\"$KEY_ALIAS\"}" | jq -r '.key // empty')
[[ -z "$KEY" ]] && echo "Failed to generate key" && exit 1

echo ""
echo "Done! User: $USER_ID | Key: $KEY"
echo "Send the new API key securely. Old keys are now invalid."
