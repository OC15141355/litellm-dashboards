#!/bin/bash
# Usage: ./bulk-offboard.sh <csv_or_list>
# Accepts a file with one user_id per line, or a CSV (first column = user_id)
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

FILE=$1
[[ -z "$FILE" ]] && echo "Usage: $0 <file>" && echo "File: one user_id per line, or CSV (first column)" && exit 1
[[ ! -f "$FILE" ]] && echo "File not found: $FILE" && exit 1

# Preview
echo "Users to offboard:"
echo "---"
TOTAL=0; declare -a USERS
while IFS=',' read -r uid rest; do
    uid=$(echo "$uid" | tr -d '\r ')
    [[ "$uid" =~ ^#|^user_id|^$ ]] && continue
    INFO=$(api GET "/user/info?user_id=${uid}")
    EMAIL=$(echo "$INFO" | jq -r '.user_info.user_email // .user_email // empty')
    if [[ -z "$EMAIL" ]]; then
        echo "  $uid — NOT FOUND (will skip)"
    else
        ROLE=$(echo "$INFO" | jq -r '.user_info.user_role // "N/A"')
        KEYS=$(echo "$INFO" | jq '.keys | length')
        echo "  $uid ($EMAIL) — $ROLE — $KEYS keys"
        USERS+=("$uid")
    fi
    ((TOTAL++))
done < "$FILE"
echo "---"
echo "Found: ${#USERS[@]} of $TOTAL"
echo ""

[[ ${#USERS[@]} -eq 0 ]] && echo "No valid users to offboard." && exit 0

read -p "Type 'confirm' to offboard all ${#USERS[@]} users: " CONFIRM
[[ "$CONFIRM" != "confirm" ]] && echo "Aborted." && exit 0

echo ""
OK=0; FAIL=0
for uid in "${USERS[@]}"; do
    INFO=$(api GET "/user/info?user_id=${uid}")
    EMAIL=$(echo "$INFO" | jq -r '.user_info.user_email // .user_email // empty')
    KEYS=$(echo "$INFO" | jq -r '.keys[]? | .token // empty')
    TEAMS=$(echo "$INFO" | jq -r '.user_info.teams[]? // empty')

    # Delete keys
    for key in $KEYS; do
        api POST "/key/delete" "{\"keys\":[\"$key\"]}" >/dev/null 2>&1
    done

    # Remove from teams
    for tid in $TEAMS; do
        api POST "/team/member_delete" "{\"team_id\":\"$tid\",\"user_id\":\"$uid\"}" >/dev/null 2>&1
    done

    # Delete user
    RESULT=$(api POST "/user/delete" "{\"user_ids\":[\"$uid\"]}" 2>&1)
    echo "OK:   $uid ($EMAIL) removed"
    ((OK++))
done

echo ""
echo "Done. $OK offboarded."
