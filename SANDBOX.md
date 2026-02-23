## Project goal

Create a secure sandbox for local coding agents. The environment is WSL2 running on Windows 11.

The primary threat model is accidental leakage, but defending against actively malicious code / prompt-injection would be beneficial.

Current use cases include:

1) Code development and execution (e.g. for scheduled jobs, performing analysis on local hardware like GPUs)
2) Performing web research / obtaining data from the web for research & development, analyzed by code written in (1)

Future use cases:

1) Ability to communicate via a secure channel (e.g. Signal) in order to interact with the Claude CLI

## Environment requirements

- Python 3
- Claude / Codex CLI (w/ dependencies)

## Workflow requirements

- User has ability to connect to the agent CLI from other hosts via SSH.
- Allow agents to run system commands (e.g. ls, grep), bash scripts and Python code in the authorized folder(s).
- Provide user ease of authenticating subscription accounts (e.g. OAuth for Claude).
- Agent has access to internet for research, and some limited LAN resources (e.g. llm-server:11434 for local Ollama models).
- Agent has ability to utilize a local GPU.
- User has ability to open ports for serving project web apps locally.
- Agent has ability to install Python packages as needed from trusted sources (e.g. pip).
- User has read/write access to container files from outside Docker session (e.g. to access transcripts for audit purposes, or copy files for agent ingestion).
- Agent has the ability to commit code to GitHub without exposing the user's private SSH key.
- The agent will need access to multiple projects simultaneously.

## Candidate architecture

Solutions to choose between include:

- Hardened Docker container
- [Bubblewrap](https://wiki.archlinux.org/title/Bubblewrap)
- Run Claude as a restricted user in WSL (but folders like /mnt/c should not be accessible)

## Candidate Docker images

These should be evaluated by the security-audit agent. Are they trustworthy to use as they are?

- https://github.com/cabinlab/claude-code-sdk-docker
- https://github.com/nezhar/claude-container

## Deliverable

1) Recommend the simplest architecture that achieves the above constraints outlined in [workflow requirements](#workflow-requirements)
2) Identify any remaining security risks not addressed by the proposed architecture

## References

- https://patrickmccanna.net/a-better-way-to-limit-claude-code-and-other-coding-agents-access-to-secrets/
- https://www.claudedirectory.co/blog/claude-code-with-docker-compose-local-dev-environments
- https://code.claude.com/docs/en/settings
- https://composio.dev/blog/secure-openclaw-moltbot-clawdbot-setup