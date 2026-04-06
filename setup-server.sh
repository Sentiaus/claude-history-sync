#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Claude History Sync: Server Setup
# =============================================================================
# Run this FIRST on your Ubuntu/Linux home server.
# At the end it will print the exact command to run on every client device.
#
# Usage:
#   bash setup-server.sh
#
# Requirements:
#   - Ubuntu 20.04+ or Debian-based Linux
#   - sudo access
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[•]${RESET} $*"; }
ok()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"; }

# ── Guard: must be Linux ──────────────────────────────────────────────────────
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
  error "This script must run on Linux. Windows users: install WSL2 and run from there."
fi
if ! command -v apt &>/dev/null; then
  error "Only Debian/Ubuntu-based systems are supported (requires apt)."
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Claude History Sync — Server Setup (Step 1/2) ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Install dependencies ─────────────────────────────────────────────
step "Step 1: Installing dependencies"
info "Updating package list..."
sudo apt-get update -qq
sudo apt-get install -y openssh-server git
ok "openssh-server and git installed"

# ── Step 2: Ensure SSH daemon is running ──────────────────────────────────────
step "Step 2: Configuring SSH server"
sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || true
if sudo systemctl is-active --quiet ssh || sudo systemctl is-active --quiet sshd; then
  ok "SSH daemon is running"
else
  warn "SSH daemon may not be running. Try: sudo systemctl start ssh"
fi

# Harden SSH: disable password auth for the claude-git user specifically
# (handled via authorized_keys restrictions below — full password disable is
# left to the user to avoid locking them out)
warn "Reminder: for maximum security, consider setting 'PasswordAuthentication no'"
warn "in /etc/ssh/sshd_config once all your SSH keys are in place."

# ── Step 3: Create dedicated git user ─────────────────────────────────────────
step "Step 3: Creating dedicated 'claude-git' user"
GIT_USER="claude-git"
GIT_SHELL_PATH="$(command -v git-shell)"

if id "$GIT_USER" &>/dev/null; then
  ok "User '$GIT_USER' already exists — skipping creation"
else
  sudo useradd \
    --system \
    --create-home \
    --shell "$GIT_SHELL_PATH" \
    --comment "Claude history sync (restricted git-shell user)" \
    "$GIT_USER"
  ok "Created user '$GIT_USER' with shell: $GIT_SHELL_PATH"
fi

# Ensure git-shell is in /etc/shells (required for useradd --shell)
if ! grep -q "$GIT_SHELL_PATH" /etc/shells; then
  echo "$GIT_SHELL_PATH" | sudo tee -a /etc/shells > /dev/null
  ok "Added git-shell to /etc/shells"
fi

# ── Step 4: Create bare git repository ───────────────────────────────────────
step "Step 4: Initialising bare git repository"
REPO_PATH="/home/${GIT_USER}/claude-history.git"
if [ -d "$REPO_PATH" ]; then
  ok "Repository already exists at $REPO_PATH"
else
  sudo -u "$GIT_USER" git init --bare "$REPO_PATH"
  ok "Created bare repo at $REPO_PATH"
fi

# Ensure repo is owned by claude-git
sudo chown -R "${GIT_USER}:${GIT_USER}" "$REPO_PATH"
ok "Ownership set on $REPO_PATH"

# ── Step 5: Set up SSH directory for claude-git ───────────────────────────────
step "Step 5: Preparing SSH authorized_keys"
SSH_DIR="/home/${GIT_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
sudo mkdir -p "$SSH_DIR"
sudo touch "$AUTH_KEYS"
sudo chmod 700 "$SSH_DIR"
sudo chmod 600 "$AUTH_KEYS"
sudo chown -R "${GIT_USER}:${GIT_USER}" "$SSH_DIR"
ok "SSH directory ready at $SSH_DIR"

# Lock claude-git's password — key-only access, no password logins ever.
sudo passwd -l "$GIT_USER" &>/dev/null || true
ok "Password login disabled for '${GIT_USER}' (SSH key only)"

# ── Step 6: Tailscale (optional, for remote/internet access) ─────────────────
step "Step 6: Tailscale (optional — for access outside your home network)"
echo ""
echo "  Tailscale creates a private encrypted network between your devices."
echo "  Without it, you can only sync when on the same WiFi as this server."
echo ""
read -r -p "  Install Tailscale for remote access? [y/N] " INSTALL_TS </dev/tty
echo ""

TAILSCALE_IP=""
if [[ "${INSTALL_TS,,}" == "y" || "${INSTALL_TS,,}" == "yes" ]]; then
  if command -v tailscale &>/dev/null; then
    ok "Tailscale already installed"
  else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
  fi
  info "Starting Tailscale (a browser window may open for login)..."
  sudo tailscale up
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
  if [[ -n "$TAILSCALE_IP" ]]; then
    ok "Tailscale IP: $TAILSCALE_IP"
  else
    warn "Could not detect Tailscale IP. Run 'tailscale ip -4' after setup."
  fi
else
  info "Skipping Tailscale. You can re-run this script to add it later."
fi

# ── Step 7: Detect server IP ──────────────────────────────────────────────────
step "Step 7: Detecting server IP address"

if [[ -n "$TAILSCALE_IP" ]]; then
  SERVER_IP="$TAILSCALE_IP"
  IP_SOURCE="Tailscale (works everywhere)"
else
  # Get the primary non-loopback IPv4 address
  SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
  fi
  IP_SOURCE="Local network only (install Tailscale for internet access)"
  warn "Using local IP: $SERVER_IP — only reachable on the same WiFi/LAN."
  warn "If this IP is DHCP-assigned, set a static IP or DHCP reservation on your router"
  warn "so the address doesn't change."
fi

ok "Server address: $SERVER_IP (${IP_SOURCE})"

# ── Step 8: Print connection command for clients ──────────────────────────────
CONNECTION_STRING="${GIT_USER}@${SERVER_IP}"
REPO_URI="${CONNECTION_STRING}:${REPO_PATH}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   ✓ Server setup complete!                                       ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}║   Run this on every other device (Step 2/2):                     ║${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}║   ${CYAN}bash setup-client.sh \"${CONNECTION_STRING}\"${RESET}${BOLD}$(printf '%*s' $((29 - ${#CONNECTION_STRING})) '')║${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
