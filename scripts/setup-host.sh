#!/bin/bash
# =============================================================================
# AgentSafe — One-time host setup (run in WSL2)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/config"

echo "=== AgentSafe Host Setup ==="
echo "Project directory: ${PROJECT_DIR}"
echo ""

# -------------------------------------------------------------------------
# 1. Install NVIDIA Container Toolkit (if not already present)
# -------------------------------------------------------------------------
install_nvidia_toolkit() {
    if command -v nvidia-ctk &>/dev/null; then
        echo "[OK] NVIDIA Container Toolkit already installed"
        return
    fi

    echo "[INSTALL] NVIDIA Container Toolkit..."

    # Add NVIDIA package repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit

    # Configure Docker to use the NVIDIA runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker 2>/dev/null || sudo service docker restart

    echo "[OK] NVIDIA Container Toolkit installed and configured"
}

# -------------------------------------------------------------------------
# 2. Verify Docker is running
# -------------------------------------------------------------------------
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "[ERROR] Docker is not installed. Install Docker Engine first."
        echo "  See: https://docs.docker.com/engine/install/ubuntu/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "[ERROR] Docker daemon is not running."
        echo "  Try: sudo service docker start"
        exit 1
    fi

    echo "[OK] Docker is running"
}

# -------------------------------------------------------------------------
# 3. Create directory structure
# -------------------------------------------------------------------------
create_dirs() {
    echo "[SETUP] Creating directory structure..."

    mkdir -p "${PROJECT_DIR}/workspace"
    mkdir -p "${CONFIG_DIR}"

    echo "[OK] Directories created"
}

# -------------------------------------------------------------------------
# 4. Create placeholder config files (if missing)
# -------------------------------------------------------------------------
create_placeholders() {
    # Claude OAuth credentials placeholder
    if [ ! -f "${CONFIG_DIR}/.credentials.json" ]; then
        echo '{}' > "${CONFIG_DIR}/.credentials.json"
        chmod 600 "${CONFIG_DIR}/.credentials.json"
        echo "[TODO] ${CONFIG_DIR}/.credentials.json created (placeholder)"
        echo "       Run 'claude /login' on host, then: cp ~/.claude/.credentials.json ${CONFIG_DIR}/.credentials.json"
    else
        echo "[OK] .credentials.json already exists"
    fi

    # GitHub machine user credentials placeholder
    if [ ! -f "${CONFIG_DIR}/git-credentials" ]; then
        cat > "${CONFIG_DIR}/git-credentials" <<'EOF'
# GitHub machine user credentials
# Format: https://<username>:<fine-grained-PAT>@github.com
# Example: https://agentsafe-bot:YOUR_FINE_GRAINED_PAT_HERE@github.com
EOF
        chmod 600 "${CONFIG_DIR}/git-credentials"
        echo "[TODO] ${CONFIG_DIR}/git-credentials created (placeholder)"
        echo "       Add your machine user PAT in the format shown in the file"
    else
        echo "[OK] git-credentials already exists"
    fi

    # Agent API keys placeholder
    if [ ! -f "${CONFIG_DIR}/.env" ]; then
        cat > "${CONFIG_DIR}/.env" <<'EOF'
# Agent API keys and secrets
# Format: KEY=value (no quotes, no spaces around =)
OPENAI_API_KEY=
# TAVILY_API_KEY=
EOF
        chmod 600 "${CONFIG_DIR}/.env"
        echo "[TODO] ${CONFIG_DIR}/.env created (placeholder)"
        echo "       Add any API keys the agent needs"
    else
        echo "[OK] .env already exists"
    fi

    # SSH authorized_keys placeholder
    if [ ! -f "${CONFIG_DIR}/authorized_keys" ]; then
        touch "${CONFIG_DIR}/authorized_keys"
        chmod 644 "${CONFIG_DIR}/authorized_keys"
        echo "[TODO] ${CONFIG_DIR}/authorized_keys created (empty)"
        echo "       Add your public key(s) for SSH access"
    else
        echo "[OK] authorized_keys already exists"
    fi
}

# -------------------------------------------------------------------------
# 5. Verify NVIDIA GPU is visible
# -------------------------------------------------------------------------
check_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        echo ""
        echo "[GPU] Detected:"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    else
        echo "[WARN] nvidia-smi not found — GPU may not be available in WSL2"
        echo "       Ensure NVIDIA drivers are installed on Windows"
    fi
}

# -------------------------------------------------------------------------
# Run all steps
# -------------------------------------------------------------------------
check_docker
install_nvidia_toolkit
create_dirs
create_placeholders
check_gpu

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Copy Claude credentials:   cp ~/.claude/.credentials.json ${CONFIG_DIR}/.credentials.json"
echo "  2. Add GitHub PAT to:         ${CONFIG_DIR}/git-credentials"
echo "  3. Add SSH public key to:     ${CONFIG_DIR}/authorized_keys"
echo "  4. Build the image:           docker build -t agentsafe ${PROJECT_DIR}"
echo "  5. Launch:                    docker compose -f ${PROJECT_DIR}/docker-compose.yml up -d"
echo ""
