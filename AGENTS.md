# Repository Guidelines

## Project Structure & Module Organization
This repository is a Docker-first sandbox for running coding agents.

- `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`: core container build/runtime logic.
- `scripts/`: host-side helpers (`setup-host.sh`, `start.sh`, `claude.sh`, `codex.sh`, `shell.sh`).
- `config/`: mounted runtime configuration (credentials seed files, SSH config, Claude settings).
- `workspace/`: bind-mounted working directory exposed inside the container at `/workspace`.
- `README.md` and `SPEC.md`: high-level usage plus detailed architecture/security notes.

## Build, Test, and Development Commands
Use these commands from the repo root:

```bash
bash scripts/setup-host.sh          # one-time host setup and placeholder config files
bash scripts/start.sh               # build (if needed) and launch agentsafe
docker compose up -d                # alternate launch path
docker compose down                 # stop container
bash scripts/shell.sh               # shell inside container as claude user
bash scripts/claude.sh --help       # run Claude CLI in container
bash scripts/codex.sh --help        # run Codex CLI in container
docker build -t agentsafe:latest .  # rebuild image explicitly
```

## Coding Style & Naming Conventions
- Languages here are primarily Bash, YAML, and Markdown.
- Bash scripts should use `#!/bin/bash` plus strict mode (`set -euo pipefail`) where practical.
- Match existing formatting: 4-space indentation in shell blocks, 2-space indentation in YAML.
- Keep script filenames in kebab-case (`setup-host.sh`) and environment variables in uppercase snake case (`OLLAMA_HOSTS`).
- Prefer clear section comments for operational scripts (preflight, network rules, launch, etc.).

## Testing Guidelines
There is no formal unit test suite yet; use fast validation plus runtime smoke checks:

```bash
bash -n entrypoint.sh scripts/*.sh
docker compose -f docker-compose.yml config >/dev/null
docker build -t agentsafe:latest .
docker exec agentsafe pgrep sshd
docker exec -u claude agentsafe codex --version
```

## Commit & Pull Request Guidelines
- Follow the existing commit style: imperative, sentence-case subjects (for example, `Add ...`, `Update ...`, `Rewrite ...`).
- Keep commits focused on one operational change area.
- PRs should include: purpose, security impact, and exact verification commands run.
- If runtime behavior changes, update both `docker-compose.yml` and `docker-compose.example.yml`, and sync docs (`README.md`/`SPEC.md`) in the same PR.

## Security & Configuration Tips
- Never commit live secrets in `config/.env`, `config/.credentials.json`, or `config/git-credentials`.
- Commit templates/placeholders only; keep local files permissioned (`600` where applicable).
- Preserve read-only mounts and `.aiexclude` protections when changing volume mappings.
