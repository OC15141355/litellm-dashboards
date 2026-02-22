#!/bin/bash
# Usage: ./bulk-onboard.sh <csv_file>
# CSV format: user_id,email,role,team,key_alias(optional)
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

CSV=$1
[[ -z "$CSV" ]] && echo "Usage: $0 <csv_file>" && echo "CSV format: user_id,email,role,team,key_alias(optional)" && exit 1
[[ ! -f "$CSV" ]] && echo "File not found: $CSV" && exit 1

# Preview
echo "Users to onboard:"
echo "---"
TOTAL=0
while IFS=',' read -r uid email role team alias; do
    [[ "$uid" =~ ^#|^user_id|^$ ]] && continue
    echo "  $uid ($email) as $role → $team"
    ((TOTAL++))
done < "$CSV"
echo "---"
echo "Total: $TOTAL"
echo ""
read -p "Proceed? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

echo ""
OK=0; FAIL=0
while IFS=',' read -r uid email role team alias; do
    [[ "$uid" =~ ^#|^user_id|^$ ]] && continue
    alias=${alias:-"${uid}-key"}
    alias=$(echo "$alias" | tr -d '\r')

    TEAM_ID=$(resolve_team "$team")
    if [[ -z "$TEAM_ID" ]]; then
        echo "FAIL: $uid — team '$team' not found"
        ((FAIL++)); continue
    fi

    AUTOKEY=$(api POST "/user/new" "{\"user_id\":\"$uid\",\"user_email\":\"$email\",\"user_role\":\"$role\"}" | jq -r '.key // empty')
    if [[ -z "$AUTOKEY" ]]; then
        echo "FAIL: $uid — could not create user"
        ((FAIL++)); continue
    fi

    api POST "/key/delete" "{\"keys\":[\"$AUTOKEY\"]}" >/dev/null 2>&1
    api POST "/team/member_add" "{\"team_id\":\"$TEAM_ID\",\"member\":{\"user_id\":\"$uid\",\"role\":\"user\"}}" >/dev/null 2>&1

    KEY=$(api POST "/key/generate" "{\"user_id\":\"$uid\",\"team_id\":\"$TEAM_ID\",\"key_alias\":\"$alias\"}" | jq -r '.key // empty')
    if [[ -z "$KEY" ]]; then
        echo "FAIL: $uid — user created but key generation failed"
        ((FAIL++)); continue
    fi

    echo "OK:   $uid ($email) → $KEY"
    ((OK++))
done < "$CSV"

echo ""
echo "Done. $OK succeeded, $FAIL failed."
