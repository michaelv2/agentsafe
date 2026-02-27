#!/bin/bash
set -e

CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"

# =============================================================================
# 1. Fix ownership and permissions on mounted volumes
# =============================================================================

# Workspace directory (bind-mounted from host, may arrive as root-owned)
chown ${CLAUDE_USER}:${CLAUDE_USER} /workspace

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
# 3. Seed Claude CLI state (disable auto-updates; can't work in container)
# =============================================================================

CLAUDE_JSON="${CLAUDE_HOME}/.claude/.claude.json"
if [ ! -f "${CLAUDE_JSON}" ]; then
    echo '{"autoUpdates":false}' > "${CLAUDE_JSON}"
else
    # Merge autoUpdates into existing file if not already set
    if ! grep -q '"autoUpdates"' "${CLAUDE_JSON}"; then
        tmp=$(jq '. + {"autoUpdates":false}' "${CLAUDE_JSON}") && echo "$tmp" > "${CLAUDE_JSON}"
    fi
fi
chown ${CLAUDE_USER}:${CLAUDE_USER} "${CLAUDE_JSON}"

# =============================================================================
# 4. Configure git for the machine user (HTTPS credential helper)
# =============================================================================

gosu ${CLAUDE_USER} git config --global credential.helper "store --file=${CLAUDE_HOME}/.git-credentials"
gosu ${CLAUDE_USER} git config --global user.name "${GIT_AUTHOR_NAME:-agentsafe-bot}"
gosu ${CLAUDE_USER} git config --global user.email "${GIT_AUTHOR_EMAIL:-agentsafe-bot@users.noreply.github.com}"

# Rewrite SSH GitHub URLs to HTTPS so the PAT credential helper is used,
# without modifying the actual remote (which is bind-mounted from the host).
gosu ${CLAUDE_USER} git config --global url."https://github.com/".insteadOf "git@github.com:"

# =============================================================================
# 5. Network egress rules — block LAN, allow internet + Ollama
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

    # Allow Ollama hosts if configured (comma-separated, e.g. "192.168.1.50,192.168.1.60:11434")
    # Also supports legacy single-host OLLAMA_HOST variable
    _OLLAMA_LIST="${OLLAMA_HOSTS:-${OLLAMA_HOST}}"
    if [ -n "${_OLLAMA_LIST}" ]; then
        IFS=',' read -ra _HOSTS <<< "${_OLLAMA_LIST}"
        for _ENTRY in "${_HOSTS[@]}"; do
            _ENTRY=$(echo "${_ENTRY}" | xargs)  # trim whitespace
            _IP="${_ENTRY%%:*}"
            _PORT="${_ENTRY##*:}"
            if [ "${_PORT}" = "${_IP}" ]; then
                _PORT=11434
            fi
            iptables -A OUTPUT -d "${_IP}" -p tcp --dport "${_PORT}" -j ACCEPT
        done
        # Export OLLAMA_HOST as the first entry for tools that expect a single host
        export OLLAMA_HOST="http://${_HOSTS[0]%%:*}:${_PORT}"
    fi

    # Block RFC 1918 private ranges (prevents lateral LAN movement)
    # These rules come AFTER the Ollama allow rule, so Ollama traffic is not blocked
    iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
    iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
    iptables -A OUTPUT -d 192.168.0.0/16 -j DROP

    # Block link-local (includes cloud metadata endpoint 169.254.169.254)
    iptables -A OUTPUT -d 169.254.0.0/16 -j DROP

    # Everything else (public internet) is allowed — required for:
    # Claude API, web research, pip, GitHub HTTPS
}

apply_network_rules_ipv6() {
    # Flush any existing OUTPUT rules
    ip6tables -F OUTPUT 2>/dev/null || true

    # Default: allow outbound
    ip6tables -P OUTPUT ACCEPT

    # Allow loopback
    ip6tables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Block IPv6 loopback address (::1) — traffic should use lo interface rule above,
    # but block the address explicitly to prevent non-lo routing tricks
    ip6tables -A OUTPUT -d ::1/128 -j DROP

    # Block IPv6 link-local (fe80::/10) — equivalent of 169.254/16
    ip6tables -A OUTPUT -d fe80::/10 -j DROP

    # Block unique local addresses (fc00::/7, RFC 4193) — IPv6 equivalent of RFC 1918
    ip6tables -A OUTPUT -d fc00::/7 -j DROP

    # Block IPv4-mapped IPv6 (::ffff:0:0/96) — prevents bypassing IPv4 rules
    # via addresses like ::ffff:10.0.0.1 or ::ffff:192.168.1.1
    ip6tables -A OUTPUT -d ::ffff:0:0/96 -j DROP
}

if command -v iptables &>/dev/null; then
    apply_network_rules
    echo "[agentsafe] IPv4 network egress rules applied"
else
    echo "[agentsafe] WARNING: iptables not available, skipping IPv4 network rules"
fi

if command -v ip6tables &>/dev/null; then
    apply_network_rules_ipv6
    echo "[agentsafe] IPv6 network egress rules applied"
else
    echo "[agentsafe] WARNING: ip6tables not available, skipping IPv6 network rules"
fi

# =============================================================================
# 6. Start SSH server
# =============================================================================

# Generate host keys if missing (first run)
ssh-keygen -A 2>/dev/null || true

echo "[agentsafe] Starting sshd"
/usr/sbin/sshd

# =============================================================================
# 7. Drop to non-root user and exec CMD
# =============================================================================

echo "[agentsafe] Ready — dropping to user '${CLAUDE_USER}'"
exec gosu ${CLAUDE_USER} "$@"
