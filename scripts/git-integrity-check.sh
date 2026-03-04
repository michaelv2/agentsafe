#!/usr/bin/env bash
# git-integrity-check.sh — Host-side integrity monitor for ~/projects
#
# Scans all git repos under ~/projects for unexpected uncommitted changes
# and posts to Slack if any are found. Designed for cron:
#
#   */15 * * * * ~/projects/agentsafe/scripts/git-integrity-check.sh
#
# Requires: SLACK_WEBHOOK_URL environment variable (or set below)
# Optional: INTEGRITY_PROJECTS_DIR to override default ~/projects

set -euo pipefail

PROJECTS_DIR="${INTEGRITY_PROJECTS_DIR:-$HOME/projects}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"

# Collect repos with unexpected changes
dirty_repos=""

for dir in "$PROJECTS_DIR"/*/; do
    [[ -d "$dir/.git" ]] || continue

    project="$(basename "$dir")"

    # Get short status (untracked + modified + staged)
    status="$(git -C "$dir" status --short 2>/dev/null)" || continue

    if [[ -n "$status" ]]; then
        # Count changes
        count="$(echo "$status" | wc -l | tr -d ' ')"
        dirty_repos+="• *${project}* — ${count} change(s)\n"
        dirty_repos+="$(echo "$status" | head -5 | sed 's/^/    /')\n"
        if [[ "$count" -gt 5 ]]; then
            dirty_repos+="    ... and $((count - 5)) more\n"
        fi
    fi
done

# Nothing to report
if [[ -z "$dirty_repos" ]]; then
    exit 0
fi

message=":warning: *AgentSafe Integrity Check*\nUncommitted changes detected in ~/projects:\n\n${dirty_repos}"

# Post to Slack if webhook is configured
if [[ -n "$SLACK_WEBHOOK" ]]; then
    payload="$(printf '{"text": "%s"}' "$message")"
    curl -sS -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK" >/dev/null 2>&1
else
    # No webhook — print to stdout (useful for manual runs / cron mail)
    printf '%b\n' "$message"
fi
