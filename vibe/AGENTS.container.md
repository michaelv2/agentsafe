
## In this container (AgentSafe)
- You're in a throwaway AgentSafe container. The user's projects are at `/workspace/projects` (on the host they're `/home/maqo/projects`, so translate that path in skills and docs). All are readable; only the ones the user named at launch are writable. To write to another project, ask the user to relaunch with it.
- Secrets are hidden on purpose: `.env` files, keys and credentials files are empty, and some folders (e.g. `agentsafe/config`, `agentsafe/data`) are empty. The user's home directory and the local network are out of reach too, except llm-server's Ollama for local subagents such as `coder`. Don't try to get around any of this.
- Python: the project's own `.venv` was built on the host and won't run here. Use this container's: `"$(agentsafe-venv)/bin/python"`, and install into it with `"$(agentsafe-venv)/bin/pip" install ...` (after the user approves, as above). It's kept between sessions.
- Git: commit, but don't push. There are no GitHub credentials here; the user reviews and pushes from the host.
- `~/.vibe/.env` holds your own API key. Never read or print it.
