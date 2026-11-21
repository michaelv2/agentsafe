# =============================================================================
# AgentSafe: Hardened Docker sandbox for local coding agents
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build — install Claude CLI and strip unnecessary platform binaries
# ---------------------------------------------------------------------------
FROM node:22-slim AS builder

# Pinned, so a rebuild never upgrades them silently; bump deliberately (after an audit)
ARG CLAUDE_CODE_VERSION=2.1.96
ARG CODEX_VERSION=0.118.0
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
    && find /usr/local/lib/node_modules/@anthropic-ai/claude-code \
        -path "*/vendor/*" \( \
            -name "win32*" -o \
            -name "darwin*" -o \
            -name "*jetbrains*" \
        \) -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 2: Runtime — CUDA base with Node.js and system packages
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ARG CLAUDE_USER=claude
ARG CLAUDE_UID=1001
ARG CLAUDE_GID=1001

# Node.js 22 via NodeSource (replaces node:22-slim base)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        git \
        curl \
        jq \
        openssh-server \
        gosu \
        iptables \
        tini \
        strace \
        binutils \
        bind9-dnsutils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Mistral Vibe CLI (scripts/vibe.sh), in its own venv, every dependency pinned to the audited set
COPY vibe/constraints.txt /opt/vibe-constraints.txt
RUN /usr/bin/python3 -m venv /opt/vibe \
    && /opt/vibe/bin/pip install --no-cache-dir --only-binary=:all: \
        -c /opt/vibe-constraints.txt mistral-vibe \
    && ln -s /opt/vibe/bin/vibe /usr/local/bin/vibe

# Per-project container virtualenvs (host .venv folders point at the host's Python)
COPY scripts/agentsafe-venv /usr/local/bin/agentsafe-venv
RUN chmod 755 /usr/local/bin/agentsafe-venv

# sshd requires this directory
RUN mkdir -p /var/run/sshd

# Fix PAM for container: pam_loginuid fails without CAP_AUDIT_WRITE
RUN sed -i 's/session\s*required\s*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd

# Copy CLI packages from builder and create bin symlinks
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js /usr/local/bin/claude \
    && ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex

# Remove any existing user/group at the target UID/GID to avoid conflicts
RUN existing_user=$(getent passwd ${CLAUDE_UID} | cut -d: -f1) \
    && [ -n "$existing_user" ] && userdel -r "$existing_user" 2>/dev/null || true \
    && existing_group=$(getent group ${CLAUDE_GID} | cut -d: -f1) \
    && [ -n "$existing_group" ] && groupdel "$existing_group" 2>/dev/null || true

# Create non-root user
RUN groupadd -g ${CLAUDE_GID} ${CLAUDE_USER} \
    && useradd -m -u ${CLAUDE_UID} -g ${CLAUDE_GID} -s /bin/bash ${CLAUDE_USER}

# Unlock account for sshd pubkey auth (! = locked, * = no password but not locked)
RUN sed -i 's/^claude:!:/claude:*:/' /etc/shadow

# Create directory structure
RUN mkdir -p /workspace \
        /home/${CLAUDE_USER}/.claude/commands \
        /home/${CLAUDE_USER}/.claude/hooks \
        /home/${CLAUDE_USER}/.codex \
        /home/${CLAUDE_USER}/.ssh \
    && chown -R ${CLAUDE_USER}:${CLAUDE_USER} \
        /workspace \
        /home/${CLAUDE_USER}/.claude \
        /home/${CLAUDE_USER}/.codex \
        /home/${CLAUDE_USER}/.ssh

# Set up a default Python venv so the agent never needs --break-system-packages,
# with the audited, hash-pinned packages from default-venv.txt
COPY default-venv.txt /opt/default-venv.txt
RUN python3 -m venv /home/${CLAUDE_USER}/.venv \
    && /home/${CLAUDE_USER}/.venv/bin/pip install --no-cache-dir --require-hashes \
        --only-binary=:all: -r /opt/default-venv.txt \
    && chown -R ${CLAUDE_USER}:${CLAUDE_USER} /home/${CLAUDE_USER}/.venv

# Add venv to PATH for all users
ENV PATH="/home/${CLAUDE_USER}/.venv/bin:/usr/local/cuda/bin:${PATH}"
ENV VIRTUAL_ENV="/home/${CLAUDE_USER}/.venv"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

EXPOSE 22
EXPOSE 8000-8099

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["claude"]
