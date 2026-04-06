#!/usr/bin/env bash
# =============================================================================
# setup-client.sh — Claude History Sync: Client Setup
# =============================================================================
# Run this on every device where you use Claude Code.
# You need the connection string printed at the end of setup-server.sh.
#
# Usage:
#   bash setup-client.sh "claude-git@192.168.1.42"
#
# Requirements:
#   - Linux, macOS, or WSL2 (Windows users: run from WSL2, not PowerShell/CMD)
#   - The server must be reachable (same network, or Tailscale connected)
#   - You'll be prompted for the server's password ONCE to copy your SSH key
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

# ── Guard: must not be native Windows ────────────────────────────────────────
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
  echo ""
  error "This script must run on Linux, macOS, or WSL2.
  Windows users: open WSL2 and run this script from there.
  Install WSL2: https://learn.microsoft.com/en-us/windows/wsl/install"
fi

# ── Parse argument ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo ""
  echo -e "${RED}Usage:${RESET}  bash setup-client.sh \"claude-git@<server-ip>\""
  echo ""
  echo "  Get the connection string from the end of running setup-server.sh on your home server."
  exit 1
fi

SERVER_ADDRESS="$1"  # e.g. claude-git@192.168.1.42
REPO_URI="${SERVER_ADDRESS}:~/claude-history.git"
SSH_KEY="$HOME/.ssh/claude_history_ed25519"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Claude History Sync — Client Setup (Step 2/2) ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Server: ${CYAN}${SERVER_ADDRESS}${RESET}"
echo ""

# ── Step 1: Check dependencies ────────────────────────────────────────────────
step "Step 1: Checking dependencies"
MISSING=()
for cmd in git ssh ssh-keygen python3; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "Installing missing tools: ${MISSING[*]}"
  if command -v apt &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y git openssh-client python3
  elif command -v brew &>/dev/null; then
    brew install git python3
  else
    error "Cannot auto-install ${MISSING[*]}. Please install them manually and re-run."
  fi
fi

if ! command -v ssh-copy-id &>/dev/null; then
  # macOS doesn't ship ssh-copy-id; install via brew or use fallback
  if command -v brew &>/dev/null; then
    brew install ssh-copy-id 2>/dev/null || true
  fi
fi
ok "All dependencies present"

# ── Step 1b: Tailscale (optional — needed to reach server outside home network) ──
step "Step 1b: Tailscale (for remote access outside your home network)"
echo ""
echo "  If your server IP starts with 100.x.x.x, it's a Tailscale IP and"
echo "  you need Tailscale running on this machine to reach it."
echo ""
read -r -p "  Install/connect Tailscale on this device? [y/N] " INSTALL_TS </dev/tty
echo ""

if [[ "$INSTALL_TS" =~ ^[Yy]([Ee][Ss])?$ ]]; then
  if command -v tailscale &>/dev/null; then
    ok "Tailscale already installed"
  else
    if command -v apt &>/dev/null; then
      info "Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
    elif [[ "$OSTYPE" == "darwin"* ]]; then
      error "On macOS, install Tailscale from the App Store or via 'brew install tailscale', then re-run this script."
    else
      error "Install Tailscale from https://tailscale.com/download then re-run this script."
    fi
  fi
  info "Connecting to Tailscale (a browser login may open)..."
  sudo tailscale up
  ok "Tailscale connected"
else
  if [[ "$SERVER_HOST" =~ ^100\. ]]; then
    warn "Server IP $SERVER_HOST looks like a Tailscale address."
    warn "Connection will fail unless Tailscale is already running on this device."
  else
    ok "Skipping Tailscale (LAN IP — not needed on local network)"
  fi
fi

# ── Step 2: Detect .claude directory ─────────────────────────────────────────
step "Step 2: Locating Claude Code config directory"

detect_claude_dir() {
  # Native Linux/macOS
  if [[ -d "$HOME/.claude" ]]; then
    echo "$HOME/.claude"
    return
  fi

  # WSL: scan Windows drives for .claude
  if grep -qi microsoft /proc/version 2>/dev/null; then
    for drive in e c d; do
      # Check drive root first — handles E:\.claude junction (no Users/ needed)
      if [[ -d "/mnt/${drive}/.claude" ]]; then
        echo "/mnt/${drive}/.claude"
        return
      fi
      # Check user profile directories
      for user_dir in "/mnt/${drive}/Users"/*/; do
        if [[ -d "${user_dir}.claude" ]]; then
          echo "${user_dir}.claude"
          return
        fi
      done
    done
  fi

  # Not found — create it at default location
  mkdir -p "$HOME/.claude"
  echo "$HOME/.claude"
}

CLAUDE_DIR="$(detect_claude_dir)"
ok "Found .claude at: $CLAUDE_DIR"

# ── Step 3: Generate SSH key ──────────────────────────────────────────────────
step "Step 3: Setting up SSH key"
if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists at $SSH_KEY"
else
  ssh-keygen -t ed25519 -C "claude-history-sync@$(hostname)" -f "$SSH_KEY" -N ""
  ok "Generated new SSH key: $SSH_KEY"
fi

# Add SSH config entry for clean connection handling
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
SERVER_HOST="${SERVER_ADDRESS#*@}"   # strip user@ prefix
SERVER_USER="${SERVER_ADDRESS%%@*}"  # just the user part

if ! grep -q "Host claude-history-server" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" << EOF

# Added by claude-history-sync setup
Host claude-history-server
  HostName ${SERVER_HOST}
  User ${SERVER_USER}
  IdentityFile ${SSH_KEY}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  ok "Added SSH config alias 'claude-history-server'"
else
  ok "SSH config alias already present"
fi

# ── Step 4: Copy public key to server ─────────────────────────────────────────
step "Step 4: Copying SSH key to server"

if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
    "${SERVER_ADDRESS}" "true" 2>/dev/null; then
  ok "SSH key already accepted by server — skipping copy"
else
  echo ""
  echo -e "  The ${CYAN}claude-git${RESET} user on the server uses git-shell (no password login)."
  echo -e "  We'll add your key via your ${BOLD}main server account${RESET} using sudo."
  echo ""
  read -r -p "  Enter your main server username (your regular login): " MAIN_USER </dev/tty
  echo ""
  echo -e "  ${YELLOW}You'll be prompted for ${MAIN_USER}'s password — this is the ONLY time.${RESET}"
  echo ""

  MAIN_ADDRESS="${MAIN_USER}@${SERVER_HOST}"

  # Read sudo password from the terminal (works even in curl | bash)
  read -rs -p "  Enter sudo password for ${MAIN_USER} (input hidden): " SUDO_PASS </dev/tty
  echo ""
  echo ""

  # Step 1: upload the public key to a temp file the main user owns
  info "Uploading public key to server..."
  scp "${SSH_KEY}.pub" "${MAIN_ADDRESS}:/tmp/claude_sync_key.pub"

  # Step 2: use sudo -S (reads password from stdin) to install the key
  ssh "$MAIN_ADDRESS" "
    echo '${SUDO_PASS}' | sudo -S bash -c '
      cat /tmp/claude_sync_key.pub >> /home/claude-git/.ssh/authorized_keys &&
      chmod 600 /home/claude-git/.ssh/authorized_keys &&
      chown claude-git:claude-git /home/claude-git/.ssh/authorized_keys &&
      rm /tmp/claude_sync_key.pub
    ' 2>&1 | grep -v 'password\|sudo' || true
    rm -f /tmp/claude_sync_key.pub
  "
  unset SUDO_PASS

  ok "SSH key added to server"
fi

# ── Step 5: Test SSH connection ───────────────────────────────────────────────
step "Step 5: Testing SSH connection"
if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    "$SERVER_ADDRESS" "git-receive-pack --advertise-refs ~/claude-history.git" \
    &>/dev/null; then
  ok "SSH connection to server works"
else
  error "Cannot connect to $SERVER_ADDRESS. Ensure the server is reachable and setup-server.sh was run."
fi

# ── Step 6: Initialise git repo in .claude ────────────────────────────────────
step "Step 6: Setting up git repo in $CLAUDE_DIR"
cd "$CLAUDE_DIR"

# .gitignore
cat > .gitignore << 'GITIGNORE'
# Sensitive — never sync
.credentials.json

# Ephemeral / regenerable
cache/
downloads/
sessions/
backups/
*.backup.*

# Large plugin binaries (reinstalled automatically)
plugins/marketplaces/
GITIGNORE
ok "Created .gitignore"

# .gitattributes
cat > .gitattributes << 'GITATTRIBUTES'
* text=auto eol=lf
*.jsonl text eol=lf
GITATTRIBUTES
ok "Created .gitattributes"

# Init
if [[ ! -d ".git" ]]; then
  git init
  git branch -M main
  ok "Initialised git repo"
else
  ok "Git repo already initialised"
fi

# Remote
export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"

if git remote get-url origin &>/dev/null 2>&1; then
  ok "Remote 'origin' already set: $(git remote get-url origin)"
else
  git remote add origin "$REPO_URI"
  ok "Added remote: $REPO_URI"
fi

# ── Step 7: Initial commit and push ──────────────────────────────────────────
step "Step 7: Initial commit and push"
git add -A

if git diff --cached --quiet; then
  # Nothing staged after git add -A
  if git log --oneline -1 &>/dev/null 2>&1; then
    ok "Nothing new to commit — already seeded"
  else
    # Repo is empty (all files gitignored) — create an empty initial commit
    # so the branch exists on the remote
    info "No files to commit (all gitignored) — creating empty initial commit..."
    git -c user.email="claude-sync@$(hostname)" -c user.name="Claude Sync" \
      commit --allow-empty -m "init: seed from $(hostname) $(date +%Y-%m-%d)"
  fi
else
  git -c user.email="claude-sync@$(hostname)" -c user.name="Claude Sync" \
    commit -m "init: seed from $(hostname) $(date +%Y-%m-%d)"
fi

# Push — show real errors; if remote has commits from another device, rebase first
if ! git push -u origin main; then
  warn "Push rejected — pulling remote history first (another device may have pushed)..."
  git pull --rebase origin main
  git push -u origin main
fi
ok "Pushed to server"

# ── Step 8: Add Claude Code Stop hook ────────────────────────────────────────
step "Step 8: Configuring Claude Code auto-sync hook"

SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

# Create settings.json if it doesn't exist
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE"
fi

python3 - << PYTHON
import json, os, sys

settings_path = "${SETTINGS_FILE}"
claude_dir    = "${CLAUDE_DIR}"
ssh_key       = "${SSH_KEY}"

with open(settings_path) as f:
    s = json.load(f)

hook_cmd = (
    f'GIT_SSH_COMMAND="ssh -i {ssh_key} -o IdentitiesOnly=yes" '
    f'cd {claude_dir} && '
    'git add -A && '
    'git diff --cached --quiet || '
    'git -c user.email="claude-sync@\$(hostname)" '
    '-c user.name="Claude Sync" '
    'commit -m "session \$(date +%Y%m%d-%H%M%S)" && '
    'git push origin main 2>/dev/null || true'
)

s.setdefault("hooks", {}).setdefault("Stop", [])

# Check if hook already present
existing_cmds = [
    h.get("command", "")
    for entry in s["hooks"]["Stop"]
    for h in entry.get("hooks", [])
]
if hook_cmd in existing_cmds:
    print("  Hook already present — skipping")
    sys.exit(0)

s["hooks"]["Stop"].append({
    "hooks": [{
        "type": "command",
        "command": hook_cmd,
        "timeout": 30
    }]
})

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)

print("  Auto-sync hook added to settings.json")
PYTHON

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   ✓ Client setup complete!                                       ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}║   Every Claude Code session will now be automatically committed  ║${RESET}"
echo -e "${BOLD}║   and pushed to your home server when it ends.                   ║${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}║   History location:  ${CYAN}${CLAUDE_DIR}/projects/${RESET}${BOLD}$(printf '%*s' $((26 - ${#CLAUDE_DIR})) '')║${RESET}"
echo -e "${BOLD}║   Server remote:     ${CYAN}${REPO_URI}${RESET}${BOLD}$(printf '%*s' $((44 - ${#REPO_URI})) '')║${RESET}"
echo -e "${BOLD}║                                                                  ║${RESET}"
echo -e "${BOLD}║   To pull history on this machine:  git -C ${CYAN}~/.claude${RESET}${BOLD} pull          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
