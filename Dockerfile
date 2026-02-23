# =============================================================================
# AgentSafe: Hardened Docker sandbox for local coding agents
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build — install Claude CLI and strip unnecessary platform binaries
# ---------------------------------------------------------------------------
FROM node:22-slim AS builder

RUN npm install -g @anthropic-ai/claude-code \
    && find /usr/local/lib/node_modules/@anthropic-ai/claude-code \
        -path "*/vendor/*" \( \
            -name "win32*" -o \
            -name "darwin*" -o \
            -name "*jetbrains*" \
        \) -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 2: Runtime — lean image with only what the agent needs
# ---------------------------------------------------------------------------
FROM node:22-slim

ARG CLAUDE_USER=claude
ARG CLAUDE_UID=1001
ARG CLAUDE_GID=1001

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
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# sshd requires this directory
RUN mkdir -p /var/run/sshd

# Fix PAM for container: pam_loginuid fails without CAP_AUDIT_WRITE
RUN sed -i 's/session\s*required\s*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd

# Copy Claude CLI from builder
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /usr/local/bin/claude /usr/local/bin/claude

# Create non-root user
RUN groupadd -g ${CLAUDE_GID} ${CLAUDE_USER} \
    && useradd -m -u ${CLAUDE_UID} -g ${CLAUDE_GID} -s /bin/bash ${CLAUDE_USER}

# Unlock account for sshd pubkey auth (! = locked, * = no password but not locked)
RUN sed -i 's/^claude:!:/claude:*:/' /etc/shadow

# Create directory structure
RUN mkdir -p /workspace \
        /home/${CLAUDE_USER}/.claude/commands \
        /home/${CLAUDE_USER}/.claude/hooks \
        /home/${CLAUDE_USER}/.ssh \
    && chown -R ${CLAUDE_USER}:${CLAUDE_USER} \
        /workspace \
        /home/${CLAUDE_USER}/.claude \
        /home/${CLAUDE_USER}/.ssh

# Set up a default Python venv so the agent never needs --break-system-packages
RUN python3 -m venv /home/${CLAUDE_USER}/.venv \
    && chown -R ${CLAUDE_USER}:${CLAUDE_USER} /home/${CLAUDE_USER}/.venv

# Add venv to PATH for all users
ENV PATH="/home/${CLAUDE_USER}/.venv/bin:${PATH}"
ENV VIRTUAL_ENV="/home/${CLAUDE_USER}/.venv"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

EXPOSE 22
EXPOSE 8000-8099

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["claude"]
