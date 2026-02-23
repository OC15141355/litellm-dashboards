#!/bin/bash
# Usage: ./rotate-key.sh <user_id>
# Lists keys, lets you pick which to rotate
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

KEY_COUNT=$(echo "$INFO" | jq '.keys | length')
[[ "$KEY_COUNT" -eq 0 ]] && echo "User '$USER_ID' has no keys." && exit 1

echo "User: $USER_ID ($EMAIL)"
echo ""
echo "Keys:"
i=1; declare -a TOKENS ALIASES TEAMS
while IFS= read -r line; do
    token=$(echo "$line" | jq -r '.token')
    alias=$(echo "$line" | jq -r '.key_alias // "unnamed"')
    team=$(echo "$line" | jq -r '.team_id // "no team"')
    TOKENS+=("$token"); ALIASES+=("$alias"); TEAMS+=("$team")
    echo "  $i) $alias  (team: $team)"
    ((i++))
done < <(echo "$INFO" | jq -c '.keys[]?')
echo "  a) All keys"
echo ""
read -p "Which key to rotate (number or 'a'): " SELECTION

declare -a TO_DELETE
if [[ "$SELECTION" == "a" ]]; then
    for idx in $(seq 0 $((${#TOKENS[@]}-1))); do
        TO_DELETE+=("$idx")
    done
    TEAM_ID="${TEAMS[0]}"
    KEY_ALIAS="${ALIASES[0]}"
else
    idx=$((SELECTION - 1))
    [[ $idx -lt 0 || $idx -ge ${#TOKENS[@]} ]] && echo "Invalid selection." && exit 1
    TO_DELETE+=("$idx")
    TEAM_ID="${TEAMS[$idx]}"
    KEY_ALIAS="${ALIASES[$idx]}"
fi

[[ -z "$TEAM_ID" || "$TEAM_ID" == "no team" ]] && echo "Selected key has no team. Can't rotate." && exit 1

read -p "Confirm rotation? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

echo ""
echo "[1/2] Deleting selected keys..."
for idx in "${TO_DELETE[@]}"; do
    api POST "/key/delete" "{\"keys\":[\"${TOKENS[$idx]}\"]}" >/dev/null 2>&1
    echo "  Deleted: ${ALIASES[$idx]}"
done

echo "[2/2] Generating new key: $KEY_ALIAS"
KEY=$(api POST "/key/generate" "{\"user_id\":\"$USER_ID\",\"team_id\":\"$TEAM_ID\",\"key_alias\":\"$KEY_ALIAS\"}" | jq -r '.key // empty')
[[ -z "$KEY" ]] && echo "Failed to generate key" && exit 1

echo ""
echo "Done! User: $USER_ID | Key: $KEY"
echo "Send the new API key securely. Old key(s) are now invalid."
