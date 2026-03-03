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

TEAMS=$(api GET "/team/list")
TOTAL_SPEND=0

$CSV && echo "team,user_id,email,spend_usd,requests,prompt_tokens,completion_tokens,top_model"
$CSV || { echo "LiteLLM Spend Report"; echo "Period: $START to $END"; echo "========================================"; echo ""; }

process_team() {
    local tid="$1"
    local talias="$2"
    local tspend="$3"

    TEAM_INFO=$(api GET "/team/info?team_id=${tid}")
    MEMBERS=$(echo "$TEAM_INFO" | jq -r '.team_info.members_with_roles[]? | select(.user_id != "default_user_id") | .user_id')

    [[ -z "$MEMBERS" ]] && return

    $CSV || printf "=== Team: %s (\$%.2f) ===\n" "$talias" "$tspend"

    while IFS= read -r uid; do
        [[ -z "$uid" ]] && continue

        ACTIVITY=$(api GET "/user/daily/activity?start_date=${START}&end_date=${END}&user_id=${uid}")

        USER_SPEND=$(echo "$ACTIVITY" | jq '[.results[]?.metrics.spend // 0] | add // 0')
        USER_REQS=$(echo "$ACTIVITY" | jq '[.results[]?.metrics.successful_requests // 0] | add // 0')
        USER_PROMPT=$(echo "$ACTIVITY" | jq '[.results[]?.metrics.prompt_tokens // 0] | add // 0')
        USER_COMPLETION=$(echo "$ACTIVITY" | jq '[.results[]?.metrics.completion_tokens // 0] | add // 0')
        TOP_MODEL=$(echo "$ACTIVITY" | jq -r '[.results[].breakdown.models // {} | to_entries[] | {model: .key, spend: .value.metrics.spend}] | sort_by(-.spend) | .[0].model // "none"')

        USER_INFO=$(api GET "/user/info?user_id=${uid}")
        EMAIL=$(echo "$USER_INFO" | jq -r '.user_info.user_email // "no email"')

        if $CSV; then
            printf "%s,%s,%s,%.2f,%d,%d,%d,%s\n" \
                "$talias" "$uid" "$EMAIL" "$USER_SPEND" "$USER_REQS" "$USER_PROMPT" "$USER_COMPLETION" "$TOP_MODEL"
        else
            printf "  %-20s \$%8.2f  %6d reqs  %8d prompt  %8d completion  Top: %s\n" \
                "$uid" "$USER_SPEND" "$USER_REQS" "$USER_PROMPT" "$USER_COMPLETION" "$TOP_MODEL"
        fi
    done <<< "$MEMBERS"

    $CSV || echo ""
}

if [[ -n "$FILTER_TEAM" ]]; then
    TID=$(resolve_team "$FILTER_TEAM")
    [[ -z "$TID" ]] && echo "Team '$FILTER_TEAM' not found." && exit 1
    TALIAS=$(echo "$TEAMS" | jq -r ".[] | select(.team_id==\"$TID\") | .team_alias // \"unnamed\"")
    TSPEND=$(echo "$TEAMS" | jq -r ".[] | select(.team_id==\"$TID\") | .spend // 0")
    process_team "$TID" "$TALIAS" "$TSPEND"
else
    while IFS= read -r line; do
        TID=$(echo "$line" | jq -r '.team_id')
        TALIAS=$(echo "$line" | jq -r '.team_alias // "unnamed"')
        TSPEND=$(echo "$line" | jq -r '.spend // 0')
        process_team "$TID" "$TALIAS" "$TSPEND"
        TOTAL_SPEND=$(echo "$TOTAL_SPEND + $TSPEND" | bc 2>/dev/null || echo "$TOTAL_SPEND")
    done < <(echo "$TEAMS" | jq -c '.[]')

    $CSV || { echo "========================================"; printf "Total: \$%.2f\n" "$TOTAL_SPEND"; }
fi
