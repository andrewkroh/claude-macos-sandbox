#!/bin/bash
# Bootstrap script for Ubuntu 24.04 VM to run Claude Code in a sandbox
# Usage: curl -sSL <url> | sudo bash
#        or: sudo bash bootstrap-ubuntu-24.04.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check Ubuntu version
if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
    log_warn "This script is designed for Ubuntu 24.04. Detected different version."
fi

log_info "Starting Ubuntu 24.04 bootstrap for Claude Code sandbox..."

# Update package lists and upgrade existing packages
log_info "Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install essential packages
log_info "Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    tmux \
    unzip \
    zip \
    jq \
    tree \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    openssh-server \
    bubblewrap \
    libseccomp2 \
    libseccomp-dev \
    socat \
    ipset \
    dnsutils

# Install Node.js (LTS version via NodeSource)
log_info "Installing Node.js LTS..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
else
    log_info "Node.js already installed: $(node --version)"
fi

# Install GitHub CLI
log_info "Installing GitHub CLI..."
if ! command -v gh &> /dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update
    apt-get install -y gh
else
    log_info "GitHub CLI already installed: $(gh --version | head -1)"
fi

# Install Go
GO_VERSION="go1.26.0"
case "$(uname -m)" in
    x86_64)  GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    *)       log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
log_info "Installing ${GO_VERSION} (${GO_ARCH})..."
if [[ -x /usr/local/go/bin/go ]] && /usr/local/go/bin/go version | grep -q "${GO_VERSION}"; then
    log_info "Go already installed: $(/usr/local/go/bin/go version)"
else
    GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/${GO_TARBALL}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
    rm -f "/tmp/${GO_TARBALL}"
    # Add Go to system-wide PATH
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
    log_info "Go installed: $(/usr/local/go/bin/go version)"
fi

# Install Claude Code (native installer, runs as ubuntu user)
log_info "Installing Claude Code..."
if sudo -u ubuntu bash -c 'command -v claude' &> /dev/null; then
    log_info "Claude Code already installed: $(sudo -u ubuntu claude --version 2>/dev/null || echo 'installed')"
else
    sudo -u ubuntu bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
fi

# Verify bubblewrap sandbox dependencies
log_info "Verifying sandbox dependencies..."
if command -v bwrap &> /dev/null; then
    log_info "bubblewrap installed: $(bwrap --version)"
else
    log_error "bubblewrap installation failed"
    exit 1
fi

# Create AppArmor profile for bubblewrap
# Ubuntu 24.04 sets kernel.apparmor_restrict_unprivileged_userns=1 which
# transitions any process creating a user namespace into the restrictive
# "unprivileged_userns" AppArmor profile. That profile denies capabilities
# (setpcap, net_admin) and blocks writing to /proc/<pid>/uid_map, which
# prevents bwrap from functioning. This named profile (like Chrome, flatpak,
# and buildah have) allows bwrap to run unconfined while granting userns
# permission.
log_info "Configuring AppArmor profile for bubblewrap..."
cat > /etc/apparmor.d/bwrap << 'APPARMOR_EOF'
# This profile allows everything and only exists to give the
# application a name instead of having the label "unconfined"

abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/bwrap>
}
APPARMOR_EOF
apparmor_parser -r /etc/apparmor.d/bwrap
log_info "AppArmor profile for bubblewrap loaded"

# Determine script directory for installing companion scripts
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install firewall and privilege-drop scripts
log_info "Installing firewall and privilege-drop scripts..."
chmod +x "${SCRIPTS_DIR}/firewall-up.sh" "${SCRIPTS_DIR}/firewall-down.sh" "${SCRIPTS_DIR}/claude-noprivs"
ln -sf "${SCRIPTS_DIR}/claude-noprivs" /usr/local/bin/claude-noprivs

# Setup ubuntu user SSH key
log_info "Setting up SSH key for ubuntu user..."
UBUNTU_HOME="/home/ubuntu"
SSH_DIR="${UBUNTU_HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

# Create ubuntu user if it doesn't exist
if ! id -u ubuntu &>/dev/null; then
    log_info "Creating ubuntu user..."
    useradd -m -s /bin/bash -G sudo ubuntu
fi

# Create .ssh directory
mkdir -p "${SSH_DIR}"

# Add the SSH public key
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDCtYAecjMDXHeX8QvV2nppOqrh5GvxG61GmB5v8JFKioIRf1zpjHcWE/VKgyhuWjb3Ywwu5xDapjLPlLAXEesUnxQuJ8lILDbweLxRFyp0z1vP9Y9PypYvfXv2mCgLsJIm/7ys0Xq+qlm6hUX/utAlVH4eUMYliAkAJxaVrt2mmmFMMMQIwhBmwnz7RRtDxli2TGLVNT5PO9KMzmTUYPTRn4AhB9QakBvX+TpOKpvsZ6MDN0oaw4loXt0GgrPhN2D4oQMK/m7s/K5z62HQmKDpd2TXToLu/y2PgoDXjRC9Dv9EK1jE9XJTKMCKrIYCzsTmS08LGBgH1yXK85To9/uEM7WUlxQToiFEEqBnC8Ha7sNcV0MUY60Xq5FXM9AXNX5nenCCWlhyW+FCJVGtnGzodMnjtNGoKs3MUbrpk1lVUz2LPtFdsCz5mj/ev3Y+Tk9dPEwzNrjuf0Yfuz3YjH1gMmvg+T+H/luBwq8avhQI2em5xr3TwXva6Ha2B7kN1uU/FzOmoBPjKBfArnNGNrUNHDhcfOdv/dCfw9ep4E6ksog5epiXCv05Ix3iD/7wxx6Vt6kcCY9BsKrMWUqZdZ0X15H3Nxb1j5oH2/+0fhE7n7TmIYwE2B+/ZX7w1rSfrRHEmf6T12Vo1SiSzMc2+/rrMQ0Af1zwn4N+KxotChxTWw== cardno:000607536908"

# Append key if not already present
if ! grep -q "cardno:000607536908" "${AUTHORIZED_KEYS}" 2>/dev/null; then
    echo "${SSH_KEY}" >> "${AUTHORIZED_KEYS}"
    log_info "SSH key added to ${AUTHORIZED_KEYS}"
else
    log_info "SSH key already present in ${AUTHORIZED_KEYS}"
fi

# Set correct permissions
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTHORIZED_KEYS}"
chown -R ubuntu:ubuntu "${SSH_DIR}"

# Configure SSH daemon for security
log_info "Configuring SSH daemon..."
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Restart SSH service
systemctl restart ssh

# Add ubuntu user to sudoers with NOPASSWD (optional, for sandbox convenience)
log_info "Configuring sudo access for ubuntu user..."
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu

# Create a workspace directory for Claude
log_info "Creating workspace directory..."
mkdir -p "${UBUNTU_HOME}/workspace"
chown ubuntu:ubuntu "${UBUNTU_HOME}/workspace"

# Install Ghostty terminfo (fixes "terminal is not fully functional" when SSHing from Ghostty)
log_info "Installing Ghostty terminfo..."
if ! infocmp xterm-ghostty &>/dev/null; then
    tic -x "${SCRIPTS_DIR}/xterm-ghostty.terminfo"
    log_info "Ghostty terminfo installed"
else
    log_info "Ghostty terminfo already installed"
fi

# Configure git for ubuntu user
log_info "Configuring git..."
sudo -u ubuntu git config --global init.defaultBranch main
sudo -u ubuntu git config --global push.default simple
sudo -u ubuntu git config --global user.email "id-github@andrewkroh.com"
sudo -u ubuntu git config --global user.name "Andrew Kroh"

# Set up bash aliases (overwrite on each run for idempotency)
log_info "Setting up bash aliases..."
ALIASES_FILE="${UBUNTU_HOME}/.bash_aliases_claude"
cat > "${ALIASES_FILE}" << 'EOF'
# Claude Code aliases (claude-noprivs is the safer default)
alias claude='claude-noprivs'
alias c='claude-noprivs'
alias workspace='cd ~/workspace'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline -10'
EOF
chown ubuntu:ubuntu "${ALIASES_FILE}"

# Source aliases file from .bashrc (idempotent)
if ! grep -q "source.*\.bash_aliases_claude" "${UBUNTU_HOME}/.bashrc" 2>/dev/null; then
    echo "" >> "${UBUNTU_HOME}/.bashrc"
    echo "# Load Claude setup aliases" >> "${UBUNTU_HOME}/.bashrc"
    echo "[ -f ~/.bash_aliases_claude ] && source ~/.bash_aliases_claude" >> "${UBUNTU_HOME}/.bashrc"
fi

# Configure Claude Code sandbox settings
log_info "Configuring Claude Code sandbox settings..."
CLAUDE_CONFIG_DIR="${UBUNTU_HOME}/.claude"
mkdir -p "${CLAUDE_CONFIG_DIR}"

# Install status line script
log_info "Installing status line script..."
cp "${SCRIPTS_DIR}/statusline.sh" "${CLAUDE_CONFIG_DIR}/statusline.sh"
chmod +x "${CLAUDE_CONFIG_DIR}/statusline.sh"

# Create settings file with sandbox enabled, seccomp isolation, and status line
cat > "${CLAUDE_CONFIG_DIR}/settings.json" << 'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "attribution": {
    "commit": "",
    "pr": ""
  },
  "sandbox": {
    "enabled": true,
    "strategy": "bubblewrap",
    "seccomp": {
      "enabled": true,
      "blockUnixSockets": true
    }
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
EOF
chown -R ubuntu:ubuntu "${CLAUDE_CONFIG_DIR}"
chmod 700 "${CLAUDE_CONFIG_DIR}"
chmod 600 "${CLAUDE_CONFIG_DIR}/settings.json"

# Configure Claude Code theme (preserve existing settings)
log_info "Configuring Claude Code theme..."
CLAUDE_PREFS="${UBUNTU_HOME}/.claude.json"
if [[ -f "${CLAUDE_PREFS}" ]]; then
    # Update existing file, preserving other keys
    jq '.theme = "dark-ansi"' "${CLAUDE_PREFS}" > "${CLAUDE_PREFS}.tmp" && mv "${CLAUDE_PREFS}.tmp" "${CLAUDE_PREFS}"
else
    # Create new file
    echo '{"theme": "dark-ansi"}' > "${CLAUDE_PREFS}"
fi
chown ubuntu:ubuntu "${CLAUDE_PREFS}"
chmod 600 "${CLAUDE_PREFS}"

# Clean up
log_info "Cleaning up..."
apt-get autoremove -y
apt-get clean

# Print summary
echo ""
echo "========================================"
log_info "Bootstrap complete!"
echo "========================================"
echo ""
echo "Installed software:"
echo "  - Node.js $(node --version)"
echo "  - npm $(npm --version)"
echo "  - Git $(git --version | cut -d' ' -f3)"
echo "  - GitHub CLI $(gh --version | head -1 | cut -d' ' -f3)"
echo "  - Claude Code $("${UBUNTU_HOME}/.local/bin/claude" --version 2>/dev/null || echo '(installed)')"
echo "  - Go $(/usr/local/go/bin/go version | cut -d' ' -f3)"
echo "  - Python $(python3 --version | cut -d' ' -f2)"
echo "  - bubblewrap $(bwrap --version) (sandbox)"
echo "  - libseccomp2 (seccomp filtering)"
echo ""
echo "SSH configuration:"
echo "  - SSH key-only authentication enabled"
echo "  - Root login disabled"
echo ""
echo "User setup:"
echo "  - User: ubuntu"
echo "  - SSH key installed in ${AUTHORIZED_KEYS}"
echo "  - Workspace directory: ${UBUNTU_HOME}/workspace"
echo "  - Passwordless sudo enabled"
echo ""
echo "Claude Code sandbox:"
echo "  - Sandbox enabled with bubblewrap"
echo "  - Seccomp filtering enabled"
echo "  - Unix sockets blocked"
echo "  - Config: ${CLAUDE_CONFIG_DIR}/settings.json"
echo ""
echo "Host firewall:"
echo "  - firewall-up.sh / firewall-down.sh installed"
echo "  - claude-noprivs wrapper: /usr/local/bin/claude-noprivs"
echo "  - Status line configured (shows FW and NNP status)"
echo ""
# Get the primary IP address
VM_IP=$(hostname -I | awk '{print $1}')

echo "Next steps:"
echo "  1. SSH into the VM: ssh ubuntu@${VM_IP}"
echo "  2. Authenticate Claude: claude auth"
echo "  3. Start with firewall:"
echo "     sudo ${SCRIPTS_DIR}/firewall-up.sh"
echo "     claude-noprivs"
echo "     # ... work ..."
echo "     sudo ${SCRIPTS_DIR}/firewall-down.sh"
echo ""
