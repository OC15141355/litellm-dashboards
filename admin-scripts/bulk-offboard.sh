#!/bin/bash
# Usage: ./bulk-offboard.sh <file>           — offboard users from file
#        ./bulk-offboard.sh --team <team>    — offboard all members of a team
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

resolve_team() {
    [[ "$1" =~ ^[0-9a-f-]{36}$ ]] && echo "$1" && return
    api GET "/team/list" | jq -r ".[] | select(.team_alias==\"$1\") | .team_id"
}

offboard_user() {
    local uid=$1
    local INFO=$(api GET "/user/info?user_id=${uid}")
    local EMAIL=$(echo "$INFO" | jq -r '.user_info.user_email // .user_email // empty')
    local KEYS=$(echo "$INFO" | jq -r '.keys[]? | .token // empty')
    local TEAMS=$(echo "$INFO" | jq -r '.user_info.teams[]? // empty')

    for key in $KEYS; do
        api POST "/key/delete" "{\"keys\":[\"$key\"]}" >/dev/null 2>&1
    done
    for tid in $TEAMS; do
        api POST "/team/member_delete" "{\"team_id\":\"$tid\",\"user_id\":\"$uid\"}" >/dev/null 2>&1
    done
    api POST "/user/delete" "{\"user_ids\":[\"$uid\"]}" >/dev/null 2>&1
    echo "OK:   $uid ($EMAIL) removed"
}

# --- Team mode ---
if [[ "$1" == "--team" ]]; then
    TEAM=$2
    [[ -z "$TEAM" ]] && echo "Usage: $0 --team <team>" && exit 1

    TEAM_ID=$(resolve_team "$TEAM")
    [[ -z "$TEAM_ID" ]] && echo "Team '$TEAM' not found." && exit 1

    TEAM_INFO=$(api GET "/team/info?team_id=${TEAM_ID}")
    TEAM_ALIAS=$(echo "$TEAM_INFO" | jq -r '.team_info.team_alias // .team_alias // "unnamed"')
    MEMBERS=$(echo "$TEAM_INFO" | jq -r '.team_info.members_with_roles[]? | select(.user_id != "default_user_id") | .user_id // empty')
    MEMBER_COUNT=$([[ -n "$MEMBERS" ]] && echo "$MEMBERS" | wc -l | tr -d ' ' || echo 0)

    echo "Team: $TEAM_ALIAS ($TEAM_ID)"
    echo "Members: $MEMBER_COUNT"
    echo "---"
    for uid in $MEMBERS; do
        INFO=$(api GET "/user/info?user_id=${uid}")
        EMAIL=$(echo "$INFO" | jq -r '.user_info.user_email // .user_email // empty')
        ROLE=$(echo "$INFO" | jq -r '.user_info.user_role // "N/A"')
        KEYS=$(echo "$INFO" | jq '.keys | length')
        echo "  $uid ($EMAIL) — $ROLE — $KEYS keys"
    done
    echo "---"
    echo ""

    DELETE_TEAM="n"
    read -p "Also delete the team itself? (y/n): " DELETE_TEAM
    echo ""
    read -p "Type 'confirm' to offboard all $MEMBER_COUNT members: " CONFIRM
    [[ "$CONFIRM" != "confirm" ]] && echo "Aborted." && exit 0

    echo ""
    OK=0
    for uid in $MEMBERS; do
        offboard_user "$uid"
        ((OK++))
    done

    if [[ "$DELETE_TEAM" == "y" ]]; then
        api POST "/team/delete" "{\"team_ids\":[\"$TEAM_ID\"]}" >/dev/null 2>&1
        echo ""
        echo "Team '$TEAM_ALIAS' deleted."
    fi

    echo ""
    echo "Done. $OK offboarded."
    exit 0
fi

# --- File mode ---
FILE=$1
[[ -z "$FILE" ]] && echo "Usage: $0 <file>  or  $0 --team <team>" && exit 1
[[ ! -f "$FILE" ]] && echo "File not found: $FILE" && exit 1

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
OK=0
for uid in "${USERS[@]}"; do
    offboard_user "$uid"
    ((OK++))
done

echo ""
echo "Done. $OK offboarded."
