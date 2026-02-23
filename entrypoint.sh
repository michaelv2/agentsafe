#!/bin/bash
set -e

CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"

# =============================================================================
# 1. Fix ownership and permissions on mounted volumes
# =============================================================================

# .ssh directory and authorized_keys
chown ${CLAUDE_USER}:${CLAUDE_USER} "${CLAUDE_HOME}/.ssh"
chmod 700 "${CLAUDE_HOME}/.ssh"
# authorized_keys is mounted read-only; ownership fix is best-effort
chown ${CLAUDE_USER}:${CLAUDE_USER} "${CLAUDE_HOME}/.ssh/authorized_keys" 2>/dev/null || true

# .claude directory
chown ${CLAUDE_USER}:${CLAUDE_USER} "${CLAUDE_HOME}/.claude"
chmod 700 "${CLAUDE_HOME}/.claude"

# =============================================================================
# 2. Copy OAuth credentials to a writable location for token refresh
# =============================================================================

CRED_SEED="${CLAUDE_HOME}/.claude/.credentials-seed.json"
CRED_LIVE="${CLAUDE_HOME}/.claude/.credentials.json"

if [ -f "${CRED_SEED}" ]; then
    cp "${CRED_SEED}" "${CRED_LIVE}"
    chown ${CLAUDE_USER}:${CLAUDE_USER} "${CRED_LIVE}"
    chmod 600 "${CRED_LIVE}"
    echo "[agentsafe] OAuth credentials seeded (writable copy for token refresh)"
else
    echo "[agentsafe] WARNING: No credentials seed found at ${CRED_SEED}"
fi

# =============================================================================
# 3. Configure git for the machine user (HTTPS credential helper)
# =============================================================================

gosu ${CLAUDE_USER} git config --global credential.helper "store --file=${CLAUDE_HOME}/.git-credentials"
gosu ${CLAUDE_USER} git config --global user.name "${GIT_AUTHOR_NAME:-agentsafe-bot}"
gosu ${CLAUDE_USER} git config --global user.email "${GIT_AUTHOR_EMAIL:-agentsafe-bot@users.noreply.github.com}"

# =============================================================================
# 4. Network egress rules — block LAN, allow internet + Ollama
# =============================================================================

apply_network_rules() {
    # Flush any existing OUTPUT rules
    iptables -F OUTPUT 2>/dev/null || true

    # Default: allow outbound (we selectively block LAN ranges below)
    iptables -P OUTPUT ACCEPT

    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow Ollama host if configured (strip port if present, e.g. "192.168.1.50:11434" → "192.168.1.50")
    if [ -n "${OLLAMA_HOST}" ]; then
        OLLAMA_IP="${OLLAMA_HOST%%:*}"
        OLLAMA_PORT="${OLLAMA_HOST##*:}"
        # Default to 11434 if no port specified
        if [ "${OLLAMA_PORT}" = "${OLLAMA_IP}" ]; then
            OLLAMA_PORT=11434
        fi
        iptables -A OUTPUT -d "${OLLAMA_IP}" -p tcp --dport "${OLLAMA_PORT}" -j ACCEPT
    fi

    # Block RFC 1918 private ranges (prevents lateral LAN movement)
    # These rules come AFTER the Ollama allow rule, so Ollama traffic is not blocked
    iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
    iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
    iptables -A OUTPUT -d 192.168.0.0/16 -j DROP

    # Block link-local
    iptables -A OUTPUT -d 169.254.0.0/16 -j DROP

    # Everything else (public internet) is allowed — required for:
    # Claude API, web research, pip, GitHub HTTPS
}

if command -v iptables &>/dev/null; then
    apply_network_rules
    echo "[agentsafe] Network egress rules applied"
else
    echo "[agentsafe] WARNING: iptables not available, skipping network rules"
fi

# =============================================================================
# 5. Start SSH server
# =============================================================================

# Generate host keys if missing (first run)
ssh-keygen -A 2>/dev/null || true

echo "[agentsafe] Starting sshd"
/usr/sbin/sshd

# =============================================================================
# 6. Drop to non-root user and exec CMD
# =============================================================================

echo "[agentsafe] Ready — dropping to user '${CLAUDE_USER}'"
exec gosu ${CLAUDE_USER} "$@"
