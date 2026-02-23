# AgentSafe: Secure Sandbox for Local Coding Agents

## Overview

A single **custom Docker container** running in WSL2 with NVIDIA GPU passthrough, accessed via SSH from external devices. The container runs Claude CLI as a non-root user with controlled network egress, volume-mounted workspace, and a GitHub machine user for code access.

```
┌─────────────────────────────────────────────────────┐
│  Windows 11 Host                                    │
│  ┌───────────────────────────────────────────────┐  │
│  │  WSL2 (Ubuntu)                                │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  Docker Container (agentsafe)           │  │  │
│  │  │                                         │  │  │
│  │  │   claude (non-root user)                │  │  │
│  │  │   ├── Claude CLI (OAuth)                │  │  │
│  │  │   ├── Python 3 + venv                   │  │  │
│  │  │   ├── git (machine user, HTTPS PAT)     │  │  │
│  │  │   └── sshd (port 2222)                  │  │  │
│  │  │                                         │  │  │
│  │  │   Volumes:                              │  │  │
│  │  │   ├── /workspace ← host bind mount      │  │  │
│  │  │   ├── /home/claude/.claude ← config     │  │  │
│  │  │   └── /home/claude/.ssh ← authorized_keys│ │  │
│  │  │                                         │  │  │
│  │  │   Network:                              │  │  │
│  │  │   ├── ✅ HTTPS outbound (443)           │  │  │
│  │  │   ├── ✅ Ollama LAN host (11434)        │  │  │
│  │  │   ├── ✅ SSH inbound (2222)             │  │  │
│  │  │   ├── ✅ Web app ports (8000-8099)      │  │  │
│  │  │   └── ❌ Everything else denied         │  │  │
│  │  │                                         │  │  │
│  │  │   GPU: NVIDIA runtime passthrough       │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │                                               │  │
│  │  /mnt/c ← NOT mounted into container          │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Component Breakdown

### 1. Custom Dockerfile

Multi-stage build borrowing patterns from [cabinlab/claude-code-sdk-docker](https://github.com/cabinlab/claude-code-sdk-docker).

- **Base:** `node:22-slim` (Debian). NVIDIA Container Toolkit handles GPU driver mounting at runtime, so no CUDA base image needed. Pre-built PyTorch wheels bundle their own CUDA runtime.
- Non-root `claude` user baked into image
- Tools: Python 3, pip, git, curl, openssh-server, common CLI utils
- Claude CLI installed globally via npm
- `.claude/` scaffolding: hooks dir, `.aiexclude`, settings
- Build deps (build-essential, etc.) stripped via multi-stage

### 2. docker-compose.yml

- NVIDIA runtime + GPU device reservation
- Volume mounts: workspace (read/write), Claude config, SSH authorized_keys, GitHub credentials
- Port mappings: `2222:22` (SSH), `8000-8099` (web apps)
- `cap_drop: ALL` with selective `cap_add` (see Security Hardening)
- `env_file` for agent API keys (`config/.env`)
- Restart policy: `unless-stopped`

### 3. Network Isolation

Custom Docker network with iptables rules applied in entrypoint:

- **Allow:** HTTPS outbound (ports 443, 80) for Claude API, web research, pip, GitHub
- **Allow:** Ollama LAN host IP on configurable port (default 11434, set via `OLLAMA_HOST` env var, supports `ip:port` format)
- **Allow:** SSH inbound on port 22 (container-internal, mapped to 2222 externally)
- **Block:** All other RFC 1918 LAN ranges (prevents lateral movement)
- `/mnt/c` is never in scope (not mounted)

### 4. GitHub Access via Machine User (HTTPS)

A dedicated GitHub account with a **fine-grained Personal Access Token (PAT)**:

- **Why HTTPS over SSH:** Fine-grained PATs can be scoped to specific repos AND specific permissions (e.g., `contents:write` only). An SSH key grants full access to whatever repos the machine user collaborates on — no per-permission scoping.
- Machine user is added as a collaborator on each repo the agent needs (minimum required role)
- PAT stored on host in `config/git-credentials` with `600` permissions
- Bind-mounted read-only into the container
- Git credential helper configured to read from the mounted file
- `.aiexclude` prevents Claude from reading the credentials file
- Distinct git identity (e.g., `agentsafe-bot <agentsafe-bot@users.noreply.github.com>`) for audit trail
- **Blast radius if compromised:** Only the repos and permissions granted to the PAT. Revoke the token without affecting any personal account.
- **Note:** GitHub fine-grained PATs can be set to expire (recommended: 1 year for a local sandbox with calendar reminder to rotate). "All repositories" scope is acceptable since the machine user account itself is the containment boundary.
- **Branch protection** on `main` is recommended to prevent direct merges without approval.

### 5. OAuth Token Handling (Claude Max)

- Run `claude /login` on host to authenticate, which writes `~/.claude/.credentials.json`
- Copy that file to `config/.credentials.json` with `600` permissions
- Bind-mounted **read-only** into the container at a staging path (`.credentials-seed.json`)
- Entrypoint copies the seed to a **writable** `.credentials.json` so Claude CLI can refresh short-lived access tokens using the refresh token
- Tokens are re-seeded from the host file on each container restart
- **Not** passed as an env var (avoids `docker inspect` exposure)

### 6. Environment Variables

- Agent API keys and secrets stored in `config/.env`
- Loaded via `env_file` in docker-compose.yml
- Added to `.aiexclude` to prevent Claude from reading the file
- Visible via `docker inspect` (acceptable for a local sandbox)

### 7. Security Hardening

- `cap_drop: ALL` with only required capabilities added back:
  - `CHOWN`, `FOWNER` — fix ownership on mounted volumes
  - `SETUID`, `SETGID` — gosu privilege drop
  - `SYS_CHROOT` — sshd privilege separation
  - `DAC_OVERRIDE` — sshd reading authorized_keys
  - `AUDIT_WRITE` — sshd audit logging for PTY sessions
  - `NET_ADMIN`, `NET_RAW` — iptables egress rules
- `no-new-privileges` is **not** used (incompatible with sshd setuid on child processes)
- No Docker socket mounted (agent cannot control Docker)
- `.aiexclude` patterns prevent Claude from reading credentials, SSH keys, `.env`, etc.
- Python packages installed via `venv` (never `--break-system-packages`)
- sshd: key-only auth, no root login, no password auth, `StrictModes no` (required for bind-mounted authorized_keys)
- PAM `pam_loginuid.so` set to `optional` (required for container PTY allocation)

## File Structure

```
agentsafe/
├── SPEC.md                 # This file
├── SANDBOX.md              # Original requirements
├── Dockerfile              # Multi-stage custom image
├── docker-compose.yml      # Orchestration + GPU + networking
├── entrypoint.sh           # Process setup, sshd, permissions
├── config/
│   ├── .aiexclude          # Prevent Claude from reading secrets
│   ├── .credentials.json   # Claude OAuth credentials (seed)
│   ├── .env                # Agent API keys and secrets
│   ├── authorized_keys     # SSH public keys for remote access
│   ├── git-credentials     # GitHub machine user PAT
│   ├── settings.json       # Claude CLI settings
│   └── sshd_config         # Hardened SSH server config
└── scripts/
    ├── claude.sh           # Shortcut: launch Claude CLI in container
    ├── setup-host.sh       # One-time: install NVIDIA toolkit, create dirs
    ├── shell.sh            # Shortcut: bash shell in container
    └── start.sh            # Daily: launch the sandbox
```

## Remaining Security Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **OAuth token in bind-mounted file** | Medium | File is `600`-permed and `.aiexclude`d, but root in container could read it. Non-root user + cap-drop reduce this. |
| **Agent can exfiltrate data via HTTPS** | Medium | Claude needs outbound HTTPS to function. Could add DNS-level filtering (e.g., Pi-hole) but adds complexity. |
| **GitHub PAT in bind-mounted file** | Medium | Same mitigations as OAuth token. Fine-grained scoping limits blast radius. Set token expiry to 90 days. |
| **GPU driver exploits** | Low | NVIDIA container runtime is a kernel-level interface. Keep drivers updated. |
| **Supply chain (npm/pip packages)** | Medium | Agent can `pip install` anything. Consider a curated allowlist or private PyPI mirror for high-security use. |
| **Container escape via kernel exploit** | Low | WSL2 kernel + Docker. Keep both updated. Seccomp + cap-drop reduce surface. |
| **Web research content injection** | Low | Agent processes untrusted web content. Claude's prompt injection resistance is the primary defense. |

## Setup Sequence

1. **Install NVIDIA Container Toolkit** in WSL2 (`scripts/setup-host.sh`)
2. **Create GitHub machine user** account, generate fine-grained PAT scoped to needed repos
3. **Build the Docker image:** `docker build -t agentsafe .`
4. **Run `claude /login`** on host, then copy `~/.claude/.credentials.json` to `config/.credentials.json`
5. **Save GitHub PAT** to `config/git-credentials`
6. **Generate SSH keypair** for remote access, place public key in `config/authorized_keys`
7. **Create workspace directory** on host
8. **`docker compose up -d`** to launch
9. **SSH in** from phone/laptop: `ssh -p 2222 claude@<wsl-ip>`

## References

- [cabinlab/claude-code-sdk-docker](https://github.com/cabinlab/claude-code-sdk-docker) — Multi-stage Dockerfile patterns, OAuth token handling
- [nezhar/claude-container](https://github.com/nezhar/claude-container) — API traffic logging, UID/GID mapping patterns
- [Patrick McCanna: Limiting agent access to secrets](https://patrickmccanna.net/a-better-way-to-limit-claude-code-and-other-coding-agents-access-to-secrets/)
- [Claude Code Docker Compose guide](https://www.claudedirectory.co/blog/claude-code-with-docker-compose-local-dev-environments)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [Composio secure agent setup](https://composio.dev/blog/secure-openclaw-moltbot-clawdbot-setup)
