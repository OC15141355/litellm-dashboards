#!/bin/bash
# Usage: ./offboard-user.sh <user_id>
# Deletes keys, removes from teams, deletes user account
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

ROLE=$(echo "$INFO" | jq -r '.user_info.user_role // "N/A"')
KEYS=$(echo "$INFO" | jq -r '.keys[]? | .token // empty')
KEY_COUNT=$([[ -n "$KEYS" ]] && echo "$KEYS" | wc -l | tr -d ' ' || echo 0)
TEAMS=$(echo "$INFO" | jq -r '.user_info.teams[]? // empty')
TEAM_COUNT=$([[ -n "$TEAMS" ]] && echo "$TEAMS" | wc -l | tr -d ' ' || echo 0)

echo "User:  $USER_ID ($EMAIL)"
echo "Role:  $ROLE"
echo "Keys:  $KEY_COUNT"
echo "$INFO" | jq -r '.keys[]? | "  - \(.key_alias // .key_name // "unnamed")"' 2>/dev/null
echo "Teams: $TEAM_COUNT"
echo ""

read -p "Type '$USER_ID' to confirm deletion: " CONFIRM
[[ "$CONFIRM" != "$USER_ID" ]] && echo "Aborted." && exit 0

echo ""
echo "[1/3] Deleting keys..."
for key in $KEYS; do
    alias=$(echo "$INFO" | jq -r ".keys[] | select(.token==\"$key\") | .key_alias // \"unnamed\"")
    api POST "/key/delete" "{\"keys\":[\"$key\"]}" >/dev/null 2>&1
    echo "  Deleted: $alias"
done

echo "[2/3] Removing from teams..."
for tid in $TEAMS; do
    api POST "/team/member_delete" "{\"team_id\":\"$tid\",\"user_id\":\"$USER_ID\"}" >/dev/null 2>&1
    echo "  Removed from: $tid"
done

echo "[3/3] Deleting user..."
api POST "/user/delete" "{\"user_ids\":[\"$USER_ID\"]}" >/dev/null 2>&1

echo ""
echo "Done. $USER_ID ($EMAIL) fully removed."
