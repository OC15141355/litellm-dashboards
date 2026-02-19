#!/bin/bash
# Usage: ./update-team-models.sh <team>
# Interactive model assignment for a team
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

resolve_team() {
    [[ "$1" =~ ^[0-9a-f-]{36}$ ]] && echo "$1" && return
    api GET "/team/list" | jq -r ".[] | select(.team_alias==\"$1\") | .team_id"
}

TEAM=$1
if [[ -z "$TEAM" ]]; then
    echo "Usage: $0 <team>"
    echo ""
    echo "Teams:"
    api GET "/team/list" | jq -r '.[] | "  \(.team_alias // "unnamed")\t\(.team_id)"'
    exit 1
fi

TEAM_ID=$(resolve_team "$TEAM")
[[ -z "$TEAM_ID" ]] && echo "Team '$TEAM' not found. Run with no args to list teams." && exit 1

CURRENT=$(api GET "/team/info?team_id=${TEAM_ID}" | jq -r '.team_info.models // .models // []')
echo "Team: $TEAM ($TEAM_ID)"
echo "Current models: $CURRENT"
echo ""

MODELS=$(api GET "/models" | jq -r '.data[].id' | sort)
echo "Available models:"
i=1; declare -a MODEL_LIST
while IFS= read -r model; do
    MODEL_LIST+=("$model")
    marker=""; echo "$CURRENT" | jq -e ". | index(\"$model\")" >/dev/null 2>&1 && marker=" *"
    echo "  $i) ${model}${marker}"
    ((i++))
done <<< "$MODELS"
echo "  a) All models (no restriction)"
echo "  * = currently assigned"
echo ""
read -p "Select (comma-separated or 'a'): " SELECTION

if [[ "$SELECTION" == "a" ]]; then
    SELECTED="[]"
else
    SELECTED="["; first=true
    IFS=',' read -ra PICKS <<< "$SELECTION"
    for p in "${PICKS[@]}"; do
        idx=$(($(echo "$p" | tr -d ' ') - 1))
        [[ $idx -lt 0 || $idx -ge ${#MODEL_LIST[@]} ]] && echo "Invalid: $p" && exit 1
        $first || SELECTED+=","; SELECTED+="\"${MODEL_LIST[$idx]}\""; first=false
    done
    SELECTED+="]"
fi

echo "Setting: $SELECTED"
read -p "Confirm? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

RESULT=$(api POST "/team/update" "{\"team_id\":\"$TEAM_ID\",\"models\":$SELECTED}")
ERROR=$(echo "$RESULT" | jq -r '.error // empty' 2>/dev/null)
[[ -n "$ERROR" ]] && echo "Error: $ERROR" && echo "$RESULT" | jq '.' 2>/dev/null && exit 1

echo "Done."
api GET "/team/info?team_id=${TEAM_ID}" | jq '.team_info.models // .models'
