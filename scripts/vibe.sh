#!/usr/bin/env bash
# vibe.sh — run Mistral Vibe in a throwaway AgentSafe container.
#
# Usage: scripts/vibe.sh <project> [project...] [vibe options...]
#        scripts/vibe.sh <project> --setup     # first time: store a Vibe-only Mistral key
#        scripts/vibe.sh <project> --shell     # bash with the same mounts, to check what's visible
#        scripts/vibe.sh <project> [project...] -c   # continue the last session (e.g. after adding a project)
#
# Sessions outlive the container (they're saved in data/vibe), so to make another project writable
# mid-session, exit while Vibe is waiting for input and relaunch with the extra project and -c.
# Keep the same first project: -c continues the most recent session started in that folder.
# --resume without an ID picks from older sessions instead.
#
# Every project in ~/projects is readable at /workspace/projects. The ones you name are writable
# (each with .git/hooks and .git/config read-only, so nothing planted there runs when you use git
# on the host), and the session starts in the first. To write to another project, relaunch with it
# named. Secrets stay hidden: .env/.envrc files, keys and credentials files appear empty, and the folders
# listed in vibe/hide.txt (credentials, agent transcripts) appear as empty folders. Both lists are
# rebuilt at every launch. The container can commit but not push: review and push from the host.
#
# Each run starts a fresh container (the "vibe" service in docker-compose.yml) and removes it on
# exit, so nothing needs restarting and the main agentsafe container is left alone. The project
# mounts are added here rather than in docker-compose.yml so they never go in without the hiding.
#
# Each named project's .envrc is loaded into the session's environment, so the same file serves
# direnv on the host and Vibe here. Only its `export KEY=value` lines are loaded; other lines
# (source .venv/bin/activate, dotenv, PATH_add) are host-only and ignored. The file itself appears
# empty inside the container, but Vibe can see every loaded value with `env`.
#
# Vibe's state lives in data/vibe (config.toml, .env with the key, sessions). AGENTS.md there is
# rebuilt on every run from ~/.vibe/AGENTS.md plus vibe/AGENTS.container.md, so edit those instead.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$HOME/projects"
WS=/workspace/projects

PROJECTS=()
while [[ $# -gt 0 && "$1" != -* ]]; do
    if [[ "$1" == */* || "$1" == .* || ! -d "$ROOT/$1" ]]; then
        echo "Error: no project '$1' in ~/projects" >&2
        exit 1
    fi
    PROJECTS+=("$1")
    shift
done
if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    echo "Usage: $0 <project> [project...] [vibe options...]" >&2
    exit 1
fi

# Vibe's home: created private on first run, seeded with the container config
mkdir -p -m 700 data/vibe
mkdir -p data/venvs
[[ -f data/vibe/config.toml ]] || cp vibe/config.toml data/vibe/config.toml
{ cat "$HOME/.vibe/AGENTS.md" 2>/dev/null || true; cat vibe/AGENTS.container.md; } > data/vibe/AGENTS.md

# --shell: a bash shell with exactly the mounts and hiding a session gets, to see what it can see
CMD=(vibe --trust --add-dir "$WS")
if [[ "${1:-}" == "--shell" ]]; then
    shift
    CMD=(bash)
fi

if [[ "${CMD[0]}" == vibe && ! -f data/vibe/.env && " $* " != *" --setup "* ]]; then
    echo "No Mistral key for the container yet. Create a separate key for Vibe (with a spending"
    echo "limit if your plan allows), then run:  $0 ${PROJECTS[0]} --setup"
    exit 1
fi

# All projects read-only; the named ones writable on top
MOUNTS=(-v "$ROOT:$WS:ro")
for p in "${PROJECTS[@]}"; do
    MOUNTS+=(-v "$ROOT/$p:$WS/$p")
    for g in .git/hooks .git/config; do
        if [[ -e "$ROOT/$p/$g" ]]; then
            MOUNTS+=(-v "$ROOT/$p/$g:$WS/$p/$g:ro")
        fi
    done
done

# Paths listed in vibe/hide.txt show up empty: folders as empty folders, files as empty files
mkdir -p data/empty
chmod 555 data/empty
HIDDEN_DIRS=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then
        continue
    elif [[ -d "$ROOT/$line" ]]; then
        MOUNTS+=(-v "$PWD/data/empty:$WS/$line:ro")
        HIDDEN_DIRS+=("${line%/}/")
    elif [[ -f "$ROOT/$line" ]]; then
        MOUNTS+=(-v "/dev/null:$WS/$line:ro")
    fi
done < vibe/hide.txt

# Secret files show up empty, wherever they are (those in hidden folders are covered already)
HIDDEN=0
while IFS= read -r -d '' f; do
    rel="${f#"$ROOT/"}"
    for d in "${HIDDEN_DIRS[@]}"; do
        [[ "$rel" == "$d"* ]] && continue 2
    done
    MOUNTS+=(-v "/dev/null:$WS/$rel:ro")
    HIDDEN=$((HIDDEN + 1))
done < <(find "$ROOT" \
    \( -name node_modules -o -name .git -o -name __pycache__ -o -name .mypy_cache \
       -o -name '.venv*' -o -name venv -o -name '*-venv' \) -prune \
    -o -type f \( -name .env -o \( -name '.env.*' ! -name .env.example \) -o -name .envrc -o -name .netrc \
       -o -name '*.pem' -o -name '*.key' -o -name '*credentials*.json' -o -name git-credentials \
       -o -name .git-credentials -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' \) \
    -print0 2>/dev/null)
echo "[vibe.sh] writable: ${PROJECTS[*]}; all other projects read-only; $HIDDEN secret files hidden" >&2

# Each named project's .envrc as environment variables (later projects win on conflicts)
ENV_ARGS=()
for p in "${PROJECTS[@]}"; do
    f="$ROOT/$p/.envrc"
    [[ -f "$f" ]] || continue
    # Only the KEY=value lines, through a pipe (no temp file with the values) that stays open
    # across the exec below. Other lines (source, dotenv, layout, PATH_add) are host-only.
    exec {fd}< <(grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$f")
    ENV_ARGS+=(--env-from-file "/dev/fd/$fd")
    other=$(grep -cvE '^[[:space:]]*(#.*)?$|^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$f" || true)
    echo "[vibe.sh] env vars from $p/.envrc$([[ $other -gt 0 ]] && echo " (ignored $other host-only line(s))")" >&2
done

exec docker compose --profile vibe run --rm "${MOUNTS[@]}" "${ENV_ARGS[@]}" -w "$WS/${PROJECTS[0]}" \
    vibe "${CMD[@]}" "$@"
