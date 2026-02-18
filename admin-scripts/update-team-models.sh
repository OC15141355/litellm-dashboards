#!/bin/bash
# Usage: ./update-team-models.sh <team>
# Shows available models, lets you pick which ones to assign to a team
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

TEAM_ID=$(resolve_team "$TEAM") || { echo "Team '$TEAM' not found"; exit 1; }

# Get current team models
CURRENT=$(api GET "/team/info?team_id=${TEAM_ID}" | jq -r '.team_info.models // .models // []')
echo "Team: $TEAM ($TEAM_ID)"
echo "Current models: $CURRENT"
echo ""

# Get available models
MODELS=$(api GET "/models" | jq -r '.data[].id' | sort)
echo "Available models:"
i=1
declare -a MODEL_LIST
while IFS= read -r model; do
    MODEL_LIST+=("$model")
    # Mark if currently assigned
    if echo "$CURRENT" | jq -e ". | index(\"$model\")" >/dev/null 2>&1; then
        echo "  $i) $model *"
    else
        echo "  $i) $model"
    fi
    ((i++))
done <<< "$MODELS"

echo ""
echo "  a) All models (no restriction)"
echo "  * = currently assigned"
echo ""
read -p "Enter model numbers (comma-separated) or 'a' for all: " SELECTION

if [[ "$SELECTION" == "a" ]]; then
    SELECTED_JSON="[]"
    echo ""
    echo "Setting team to: all models (no restriction)"
else
    SELECTED_JSON="["
    first=true
    IFS=',' read -ra PICKS <<< "$SELECTION"
    for pick in "${PICKS[@]}"; do
        pick=$(echo "$pick" | tr -d ' ')
        idx=$((pick - 1))
        if [[ $idx -ge 0 && $idx -lt ${#MODEL_LIST[@]} ]]; then
            $first || SELECTED_JSON+=","
            SELECTED_JSON+="\"${MODEL_LIST[$idx]}\""
            first=false
        else
            echo "Invalid selection: $pick"
            exit 1
        fi
    done
    SELECTED_JSON+="]"
    echo ""
    echo "Setting team to: $SELECTED_JSON"
fi

echo ""
read -p "Confirm? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0

RESULT=$(api POST "/team/update" "{\"team_id\":\"$TEAM_ID\",\"models\":$SELECTED_JSON}")

# Check for errors
ERROR=$(echo "$RESULT" | jq -r '.error // empty' 2>/dev/null)
if [[ -n "$ERROR" ]]; then
    echo "Error: $ERROR"
    echo ""
    echo "Full response:"
    echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
    exit 1
fi

echo "Done. Team '$TEAM' models updated."
echo ""
echo "Verify:"
api GET "/team/info?team_id=${TEAM_ID}" | jq '.team_info.models // .models'
