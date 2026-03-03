#!/bin/bash
# Usage: ./spend-report.sh [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--team <team>] [--csv]
# Generates a cost attribution report per team and per user
set -e

[[ -z "$LITELLM_API_BASE" ]] && read -p "LiteLLM URL: " LITELLM_API_BASE
[[ -z "$LITELLM_MASTER_KEY" ]] && read -sp "Master Key: " LITELLM_MASTER_KEY && echo
LITELLM_API_BASE="${LITELLM_API_BASE%/}"

api() { curl -sk -X "$1" "${LITELLM_API_BASE}$2" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" ${3:+-d "$3"}; }

resolve_team() {
    [[ "$1" =~ ^[0-9a-f-]{36}$ ]] && echo "$1" && return
    api GET "/team/list" | jq -r ".[] | select(.team_alias==\"$1\") | .team_id"
}

# Defaults: current month
START=$(date -u +"%Y-%m-01")
END=$(date -u +"%Y-%m-%d")
FILTER_TEAM=""
CSV=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START="$2"; shift 2 ;;
        --end) END="$2"; shift 2 ;;
        --team) FILTER_TEAM="$2"; shift 2 ;;
        --csv) CSV=true; shift ;;
        *) echo "Usage: $0 [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--team <team>] [--csv]"; exit 1 ;;
    esac
done

# Fetch all raw spend logs for the period
LOGS=$(api GET "/spend/logs?start_date=${START}&end_date=${END}&summarize=false")

# Get team list for aliases
TEAMS=$(api GET "/team/list")

$CSV && echo "team,user_id,email,spend_usd,requests,prompt_tokens,completion_tokens,top_model"
$CSV || { echo "LiteLLM Spend Report"; echo "Period: $START to $END"; echo "========================================"; echo ""; }

TOTAL_SPEND=0

process_team() {
    local tid="$1"
    local talias="$2"

    # Filter logs for this team and aggregate per user
    TEAM_LOGS=$(echo "$LOGS" | jq -c "[.[] | select(.team_id==\"$tid\")]")
    TEAM_SPEND=$(echo "$TEAM_LOGS" | jq '[.[].spend // 0] | add // 0')
    USERS=$(echo "$TEAM_LOGS" | jq -r '[.[].user // empty] | unique | .[] | select(. != "" and . != "default_user_id")')

    [[ -z "$USERS" ]] && return

    $CSV || printf "=== Team: %s (\$%.2f) ===\n" "$talias" "$TEAM_SPEND"

    while IFS= read -r uid; do
        [[ -z "$uid" ]] && continue

        USER_SPEND=$(echo "$TEAM_LOGS" | jq "[.[] | select(.user==\"$uid\") | .spend // 0] | add // 0")
        USER_REQS=$(echo "$TEAM_LOGS" | jq "[.[] | select(.user==\"$uid\")] | length")
        USER_PROMPT=$(echo "$TEAM_LOGS" | jq "[.[] | select(.user==\"$uid\") | .prompt_tokens // 0] | add // 0")
        USER_COMPLETION=$(echo "$TEAM_LOGS" | jq "[.[] | select(.user==\"$uid\") | .completion_tokens // 0] | add // 0")
        TOP_MODEL=$(echo "$TEAM_LOGS" | jq -r "[.[] | select(.user==\"$uid\")] | group_by(.model) | map({model: .[0].model, spend: (map(.spend) | add)}) | sort_by(-.spend) | .[0].model // \"none\"")

        # Get email from user info
        EMAIL=$(api GET "/user/info?user_id=${uid}" | jq -r '.user_info.user_email // "no email"')

        if $CSV; then
            printf "%s,%s,%s,%.2f,%d,%d,%d,%s\n" \
                "$talias" "$uid" "$EMAIL" "$USER_SPEND" "$USER_REQS" "$USER_PROMPT" "$USER_COMPLETION" "$TOP_MODEL"
        else
            printf "  %-20s %-30s \$%8.2f  %6d reqs  %8d prompt  %8d completion  Top: %s\n" \
                "$uid" "$EMAIL" "$USER_SPEND" "$USER_REQS" "$USER_PROMPT" "$USER_COMPLETION" "$TOP_MODEL"
        fi
    done <<< "$USERS"

    $CSV || echo ""
    TOTAL_SPEND=$(echo "$TOTAL_SPEND + $TEAM_SPEND" | bc 2>/dev/null || echo "$TOTAL_SPEND")
}

if [[ -n "$FILTER_TEAM" ]]; then
    TID=$(resolve_team "$FILTER_TEAM")
    [[ -z "$TID" ]] && echo "Team '$FILTER_TEAM' not found." && exit 1
    TALIAS=$(echo "$TEAMS" | jq -r ".[] | select(.team_id==\"$TID\") | .team_alias // \"unnamed\"")
    process_team "$TID" "$TALIAS"
else
    while IFS= read -r line; do
        TID=$(echo "$line" | jq -r '.team_id')
        TALIAS=$(echo "$line" | jq -r '.team_alias // "unnamed"')
        process_team "$TID" "$TALIAS"
    done < <(echo "$TEAMS" | jq -c '.[]')

    $CSV || { echo "========================================"; printf "Total: \$%.2f\n" "$TOTAL_SPEND"; }
fi
