#!/usr/bin/env bash
# mount-project.sh — Add or remove rw mount overrides for projects in docker-compose.yml
#
# Usage:
#   ./scripts/mount-project.sh <project-name> [rw|ro]
#
# Examples:
#   ./scripts/mount-project.sh fintools rw    # Promote to writable
#   ./scripts/mount-project.sh fintools ro    # Demote back to read-only (base mount)
#   ./scripts/mount-project.sh fintools       # Show current status
#
# After changing mounts, the container is recreated via docker compose up -d.

set -euo pipefail

COMPOSE_FILE="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.yml"
PROJECTS_DIR="$HOME/projects"

usage() {
    echo "Usage: $0 <project-name> [rw|ro]"
    echo ""
    echo "  rw   — add rw mount override (project becomes writable in container)"
    echo "  ro   — remove rw override (falls back to base read-only mount)"
    echo "  omit — show current mount status for the project"
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT="$1"
ACTION="${2:-status}"

# Validate project exists on host
if [[ ! -d "$PROJECTS_DIR/$PROJECT" ]]; then
    echo "Error: project '$PROJECT' not found in $PROJECTS_DIR/"
    exit 1
fi

# The mount line we're looking for / adding
MOUNT_LINE="      - ~/projects/${PROJECT}:/workspace/projects/${PROJECT}"

# Check current state
is_rw() {
    grep -qF "$MOUNT_LINE" "$COMPOSE_FILE" 2>/dev/null
}

case "$ACTION" in
    status)
        if is_rw; then
            echo "$PROJECT: rw (explicit override)"
        else
            echo "$PROJECT: ro (base mount)"
        fi
        exit 0
        ;;
    rw)
        if is_rw; then
            echo "$PROJECT is already mounted rw"
            exit 0
        fi

        # Insert the new mount line after the "Use scripts/mount-project.sh" comment
        MARKER="# Use scripts/mount-project.sh to add/remove projects here"
        if grep -qF "$MARKER" "$COMPOSE_FILE"; then
            sed -i "/$MARKER/a\\$MOUNT_LINE" "$COMPOSE_FILE"
        else
            # Fallback: insert after last existing rw override mount
            # Find the last line matching the override pattern and insert after it
            LAST_OVERRIDE=$(grep -n '^\s*- ~/projects/[^:]*:/workspace/projects/' "$COMPOSE_FILE" | tail -1 | cut -d: -f1)
            if [[ -n "$LAST_OVERRIDE" ]]; then
                sed -i "${LAST_OVERRIDE}a\\$MOUNT_LINE" "$COMPOSE_FILE"
            else
                echo "Error: could not find insertion point in $COMPOSE_FILE"
                exit 1
            fi
        fi

        echo "Added rw override for $PROJECT"
        ;;
    ro)
        if ! is_rw; then
            echo "$PROJECT is already ro (no override to remove)"
            exit 0
        fi

        # Remove the mount line (escape special chars for sed)
        ESCAPED=$(printf '%s\n' "$MOUNT_LINE" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i "\|${ESCAPED}|d" "$COMPOSE_FILE"

        echo "Removed rw override for $PROJECT (now ro via base mount)"
        ;;
    *)
        usage
        ;;
esac

# Check for active shell sessions before restarting
CONTAINER="agentsafe"
if docker inspect "$CONTAINER" &>/dev/null; then
    # Collect active shells from both SSH and docker exec
    sessions="$(docker exec "$CONTAINER" ps -eo user,tty,comm --no-headers 2>/dev/null \
        | grep -E 'bash|sh|zsh' \
        | grep -v '^\s*root\s' \
        || true)"

    if [[ -n "$sessions" ]]; then
        count="$(echo "$sessions" | wc -l | tr -d ' ')"
        echo ""
        echo "Warning: $count active shell session(s) detected in $CONTAINER:"
        echo "$sessions" | sed 's/^/  /'
        echo ""
        read -rp "Recreating will kill all sessions. Continue? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted. Mount config was updated but container was NOT restarted."
            echo "Run 'docker compose up -d' manually when ready."
            exit 0
        fi
    fi
fi

# Recreate the container with updated mounts
echo "Recreating container..."
cd "$(dirname "$COMPOSE_FILE")"
docker compose up -d
echo "Done. Container recreated with updated mounts."
