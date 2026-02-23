#!/bin/bash
# =============================================================================
# AgentSafe — Launch the sandbox
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== AgentSafe Start ==="

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

# Check required config files exist and are non-empty
check_file() {
    local file="$1"
    local desc="$2"
    if [ ! -f "${file}" ] || [ ! -s "${file}" ]; then
        echo "[ERROR] ${desc} is missing or empty: ${file}"
        echo "        Run scripts/setup-host.sh first"
        exit 1
    fi
}

check_file "${PROJECT_DIR}/config/.credentials.json" "Claude OAuth credentials"
check_file "${PROJECT_DIR}/config/git-credentials"   "GitHub machine user credentials"
check_file "${PROJECT_DIR}/config/authorized_keys"    "SSH authorized keys"

# -------------------------------------------------------------------------
# Build image if needed
# -------------------------------------------------------------------------
if ! docker image inspect agentsafe:latest &>/dev/null; then
    echo "[BUILD] Image not found, building..."
    docker build -t agentsafe:latest "${PROJECT_DIR}"
fi

# -------------------------------------------------------------------------
# Launch
# -------------------------------------------------------------------------
echo "[START] Launching agentsafe container..."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d

# Wait for SSH to be ready
echo "[WAIT] Waiting for SSH..."
for i in $(seq 1 30); do
    if docker exec agentsafe pgrep sshd &>/dev/null; then
        break
    fi
    sleep 1
done

# -------------------------------------------------------------------------
# Connection info
# -------------------------------------------------------------------------
WSL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "=== AgentSafe Running ==="
echo ""
echo "  SSH from this machine:  ssh -p 2222 claude@localhost"
echo "  SSH from LAN:           ssh -p 2222 claude@${WSL_IP}"
echo "  Container shell:        docker exec -it -u claude agentsafe bash"
echo "  Logs:                   docker compose -f ${PROJECT_DIR}/docker-compose.yml logs -f"
echo "  Stop:                   docker compose -f ${PROJECT_DIR}/docker-compose.yml down"
echo ""
echo "  Web app ports 8000-8099 are forwarded to the host."
echo ""
