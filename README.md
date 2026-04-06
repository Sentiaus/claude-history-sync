# claude-history-sync

Self-host your Claude Code conversation history on a Linux home server. Every session is automatically versioned and pushed — access your full conversation history from any device.

## How it works

```
Client (any device)              Home server (Ubuntu/Linux)
  ~/.claude/  ──Stop hook──▶  ~/claude-history.git  ◀──pull──  other devices
```

A [Claude Code Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) fires at the end of every session and commits + pushes your `~/.claude` folder (conversations, settings, memory) to a bare git repository on your home server. Your credentials are never synced.

## Requirements

| Component | Requirement |
|---|---|
| Home server | Ubuntu/Debian Linux, sudo access |
| Client devices | Linux, macOS, or **WSL2** (Windows) |
| Network | LAN — or Tailscale for internet access |

> **Windows users:** This tool requires WSL2. Install it with `wsl --install` in PowerShell, then run the scripts from inside WSL2.

## Setup

### Step 1 — Home server

SSH into your home server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/claude-history-sync/main/setup-server.sh | bash
```

Or clone the repo and run locally:

```bash
git clone https://github.com/YOUR_USERNAME/claude-history-sync
bash claude-history-sync/setup-server.sh
```

At the end, the script prints a connection command like:

```
bash setup-client.sh "claude-git@192.168.1.42"
```

### Step 2 — Every client device

Run the command printed by Step 1:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/claude-history-sync/main/setup-client.sh | bash -s -- "claude-git@192.168.1.42"
```

That's it. Your next Claude session will auto-sync.

## What gets synced

| Synced | Not synced |
|---|---|
| `projects/` — all conversation transcripts | `.credentials.json` — OAuth tokens |
| `settings.json` — configuration | `cache/` — regenerable |
| `history.jsonl` — command history | `sessions/` — ephemeral PIDs |
| `file-history/`, `shell-snapshots/` | `backups/` — redundant with git |
| `plugins/known_marketplaces.json` | `plugins/marketplaces/` — large binaries |

## Security

- A dedicated `claude-git` user is created on the server with `git-shell` as its login shell. Even if an SSH key is stolen, the attacker can only push/pull git data — no shell access.
- SSH key pairs are used exclusively (no passwords after initial setup).
- The SSH key generated for this tool is stored separately (`~/.ssh/claude_history_ed25519`) so it doesn't interfere with your other SSH keys.
- `.credentials.json` is in `.gitignore` and will never be committed.

### For remote (internet) access

The `setup-server.sh` script will offer to install [Tailscale](https://tailscale.com) — a free encrypted overlay network. This is the recommended approach for accessing your server outside your home network without exposing SSH to the internet.

If you prefer manual port forwarding, ensure:
- You use a non-default SSH port
- Password authentication is disabled (`PasswordAuthentication no` in `/etc/ssh/sshd_config`)
- `fail2ban` or equivalent is installed

## Manual commands

```bash
# Pull latest history on a read-only device
git -C ~/.claude pull

# View conversation history
ls ~/.claude/projects/

# Check sync status
git -C ~/.claude status
git -C ~/.claude log --oneline -10
```

## License

MIT
