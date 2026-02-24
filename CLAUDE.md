# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentSafe is a hardened Docker sandbox for running Claude CLI agents locally on WSL2. It provides GPU passthrough (NVIDIA), network isolation via iptables, SSH remote access, and GitHub integration through a machine user PAT. The codebase is primarily Bash scripts and Docker/YAML configuration — there is no application source code, test suite, or build pipeline beyond the Docker image itself.

## Build & Run Commands

```bash
# One-time host setup (NVIDIA toolkit, directory creation, placeholder configs)
scripts/setup-host.sh

# Daily launch (pre-flight checks, auto-build if needed, docker compose up)
scripts/start.sh

# Build image manually
docker build -t agentsafe:latest .

# Interactive Claude CLI inside running container
scripts/claude.sh <args>

# Bash shell inside running container
scripts/shell.sh
```

There are no linting, testing, or CI commands — validation happens via pre-flight checks in `scripts/start.sh`.

## Architecture

```
WSL2 Host
└── Docker Container (agentsafe)
    ├── entrypoint.sh (root) → drops to non-root 'claude' user via gosu
    │   1. Fix volume ownership
    │   2. Copy OAuth seed → writable credentials (enables token refresh)
    │   3. Configure git (HTTPS PAT credential helper)
    │   4. Apply iptables egress rules (block RFC 1918, allow public internet + Ollama)
    │   5. Start sshd, then exec CMD as claude user
    │
    ├── Bind-mounted volumes (all secrets are read-only from host):
    │   /workspace (rw), credentials-seed (ro), git-credentials (ro),
    │   authorized_keys (ro), sshd_config (ro), settings.json (ro),
    │   statusline.sh (ro), .aiexclude (ro)
    │
    ├── Optional: Cortex memory (shared with host):
    │   /opt/cortex (ro) — claude-cortex-core runtime
    │   ~/.claude-cortex (rw) — shared SQLite memory DB
    │
    └── Security layers:
        cap_drop ALL + selective cap_add, non-root user,
        key-only SSH, .aiexclude blocks credential reads
```

**Key design decisions:**
- OAuth credentials are copied from a read-only seed to a writable path so the CLI can refresh tokens; refreshed tokens are lost on container restart (by design).
- GitHub uses HTTPS with a fine-grained PAT (not SSH keys) for per-repo permission scoping.
- Network egress blocks all RFC 1918/link-local ranges to prevent LAN lateral movement, but allows public internet (HTTPS, pip, GitHub) and a configurable Ollama host.
- `config/.aiexclude` prevents the Claude CLI from reading any secrets mounted into the container.

## File Roles

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: `node:22-slim`, installs Claude CLI, Python venv, sshd, iptables, tini |
| `docker-compose.yml` | Production config: GPU runtime, port mappings (2222→22, 8000-8099), volume mounts, env, capabilities |
| `entrypoint.sh` | Container init: credential setup, git config, iptables rules, sshd start, privilege drop |
| `scripts/setup-host.sh` | Host one-time setup: NVIDIA toolkit install, directory/placeholder creation |
| `scripts/start.sh` | Daily launcher: pre-flight config checks, auto-build, compose up, sshd readiness wait |
| `config/settings.json` | Claude CLI settings: tool permissions, deny rules for secrets, statusline, Cortex hooks, auto-update disabled |
| `config/statusline.sh` | Claude CLI statusline script (model, cwd, context bar, cost) |
| `config/.aiexclude` | Glob patterns preventing Claude from reading secrets |
| `config/sshd_config` | Hardened sshd: key-only auth, no root, no agent forwarding, local forwarding only |

## Important Conventions

- All secrets live under `config/` and are bind-mounted read-only. Never bake secrets into the Docker image.
- The container runs as non-root user `claude` (UID/GID 1001). Entrypoint runs as root only for setup, then drops privileges via `gosu`.
- iptables rules are applied in `entrypoint.sh` — any network policy changes go there.
- `config/settings.json` is mounted read-only into the container as the Claude CLI's user settings. It controls tool permissions (Read, Edit, Write, Glob, Grep, Bash), deny rules for secrets, statusline, Cortex hooks, and disables auto-updates (which can't work in the container since the CLI is installed as root at build time).
- Cortex memory integration is optional. It requires `claude-cortex-core` cloned and built on the host, with volumes mounting the runtime (ro) and `~/.claude-cortex` data directory (rw). The shared SQLite DB uses WAL mode; concurrent host+container writes may cause contention.
- The `docker-compose.example.yml` is the user-facing template; `docker-compose.yml` is the active config (gitignored).
