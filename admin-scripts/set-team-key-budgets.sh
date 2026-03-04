#!/bin/bash
# Usage: ./set-team-key-budgets.sh <team> <max_budget_usd> [budget_duration]
# Sets max_budget on all virtual keys within a team
# budget_duration defaults to "30d" (monthly reset)
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

resolve_team() {
    [[ "$1" =~ ^[0-9a-f-]{36}$ ]] && echo "$1" && return
    api GET "/team/list" | jq -r ".[] | select(.team_alias==\"$1\") | .team_id"
}

TEAM=$1; BUDGET=$2; DURATION=${3:-"30d"}

[[ -z "$TEAM" || -z "$BUDGET" ]] && echo "Usage: $0 <team> <max_budget_usd> [budget_duration]" && echo "Example: $0 engineering 100 30d" && exit 1

TEAM_ID=$(resolve_team "$TEAM")
[[ -z "$TEAM_ID" ]] && echo "Team '$TEAM' not found." && exit 1

TEAM_ALIAS=$(api GET "/team/list" | jq -r ".[] | select(.team_id==\"$TEAM_ID\") | .team_alias // \"unnamed\"")

# Get all keys for the team
TEAM_INFO=$(api GET "/team/info?team_id=$TEAM_ID")
KEYS=$(echo "$TEAM_INFO" | jq -c '[.keys[] | {token: .token, alias: .key_alias, user: .user_id, current_budget: .max_budget, current_spend: .spend}]')
KEY_COUNT=$(echo "$KEYS" | jq 'length')

[[ "$KEY_COUNT" -eq 0 ]] && echo "No keys found for team $TEAM_ALIAS." && exit 0

echo "Team: $TEAM_ALIAS ($TEAM_ID)"
echo "Keys: $KEY_COUNT"
echo "Setting: max_budget=\$$BUDGET, budget_duration=$DURATION"
echo ""
echo "Current keys:"
echo "$KEYS" | jq -r '.[] | "  \(.alias // "no-alias") (\(.user // "no-user")) — current budget: $\(.current_budget // 0), spent: $\(.current_spend // 0)"'
echo ""
read -p "Apply \$$BUDGET budget to all $KEY_COUNT keys? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

echo ""
UPDATED=0
while IFS= read -r key_token; do
    [[ -z "$key_token" ]] && continue
    ALIAS=$(echo "$KEYS" | jq -r ".[] | select(.token==\"$key_token\") | .alias // \"no-alias\"")

    RESULT=$(api POST "/key/update" "{\"key\":\"$key_token\",\"max_budget\":$BUDGET,\"budget_duration\":\"$DURATION\"}")
    ERR=$(echo "$RESULT" | jq -r '.error // empty' 2>/dev/null)

    if [[ -n "$ERR" ]]; then
        echo "FAIL: $ALIAS — $ERR"
    else
        echo "OK:   $ALIAS — \$$BUDGET / $DURATION"
        ((++UPDATED))
    fi
done < <(echo "$KEYS" | jq -r '.[].token')

echo ""
echo "Done. $UPDATED / $KEY_COUNT keys updated."
