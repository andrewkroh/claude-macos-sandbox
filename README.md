# Claude Code Sandbox

A defense-in-depth sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
inside an isolated VM with multiple security layers.

## Security Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS Host                                                     │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Multipass VM  (Ubuntu 24.04, 4 CPU / 8 GB / 50 GB)      │  │
│  │                                                           │  │
│  │  ┌────────────────────────────────────────────────────┐   │  │
│  │  │  iptables / ipset Firewall                         │   │  │
│  │  │  Outbound allowlist: API, GitHub, npm, Go proxy    │   │  │
│  │  │  IPv6 fully blocked                                │   │  │
│  │  │                                                    │   │  │
│  │  │  ┌─────────────────────────────────────────────┐   │   │  │
│  │  │  │  Unprivileged User (ubuntu)                 │   │   │  │
│  │  │  │  SSH key-only auth (Yubikey)                │   │   │  │
│  │  │  │                                             │   │   │  │
│  │  │  │  ┌──────────────────────────────────────┐   │   │   │  │
│  │  │  │  │  setpriv --no-new-privs              │   │   │   │  │
│  │  │  │  │  Blocks sudo, setuid, cap escalation │   │   │   │  │
│  │  │  │  │                                      │   │   │   │  │
│  │  │  │  │  ┌───────────────────────────────┐   │   │   │   │  │
│  │  │  │  │  │  Claude Code                  │   │   │   │   │  │
│  │  │  │  │  │                               │   │   │   │   │  │
│  │  │  │  │  │  ┌────────────────────────┐   │   │   │   │   │  │
│  │  │  │  │  │  │  Bubblewrap Sandbox    │   │   │   │   │   │  │
│  │  │  │  │  │  │  ∙ User namespaces     │   │   │   │   │   │  │
│  │  │  │  │  │  │  ∙ Filesystem isolation│   │   │   │   │   │  │
│  │  │  │  │  │  │  ∙ Seccomp filters     │   │   │   │   │   │  │
│  │  │  │  │  │  │  ∙ Unix sockets blocked│   │   │   │   │   │  │
│  │  │  │  │  │  └────────────────────────┘   │   │   │   │   │  │
│  │  │  │  │  └───────────────────────────────┘   │   │   │   │  │
│  │  │  │  └──────────────────────────────────────┘   │   │   │  │
│  │  │  └─────────────────────────────────────────────┘   │   │  │
│  │  └────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 1. Multipass VM

The outermost layer is a [Multipass](https://multipass.run/) Ubuntu 24.04 VM that
provides hardware-level isolation from the macOS host via Hypervisor.framework.

- 4 CPUs, 8 GB RAM, 50 GB disk
- The host `~/code` directory is mounted read-write into the VM at `~/code`
- `start-cc-sandbox.sh` manages the VM lifecycle (create, start, resume)

### 2. Network Firewall (iptables + ipset)

All outbound traffic is **denied by default**. Only an explicit allowlist of
domains can be reached. IPv6 is fully blocked.

| Allowed Domain         | Purpose             |
|------------------------|---------------------|
| `api.anthropic.com`    | Claude API          |
| `sentry.io`           | Error reporting     |
| `statsig.anthropic.com`| Feature flags      |
| `statsig.com`         | Feature flags       |
| `registry.npmjs.org`  | npm packages        |
| `proxy.golang.org`    | Go module proxy     |
| `sum.golang.org`      | Go module checksums |
| `github.com`          | Git + web           |
| `api.github.com`      | GitHub API          |

GitHub CIDRs are fetched dynamically from the GitHub `/meta` API. DNS is locked
down to only the nameservers in `/etc/resolv.conf`. Local network access is
preserved for DHCP/ARP.

Scripts: `firewall-up.sh`, `firewall-down.sh`, `allowed-domains.conf`

### 3. Unprivileged User

Claude Code runs as the `ubuntu` user, not root.

- SSH access is key-only (backed by a Yubikey hardware token)
- Password authentication and root login are disabled
- Root login via SSH is disabled

### 4. No New Privileges (`setpriv`)

The `claude-noprivs` wrapper launches Claude Code with `setpriv --no-new-privs`,
setting the kernel's `PR_SET_NO_NEW_PRIVS` flag on the process tree. This
**permanently prevents** privilege escalation for the process and all children:

- `sudo` will not work
- setuid/setgid binaries cannot gain elevated permissions
- No new Linux capabilities can be acquired

The default shell aliases (`claude`, `c`) always use this wrapper.

### 5. Bubblewrap Sandbox

Claude Code's built-in sandbox uses [Bubblewrap](https://github.com/containers/bubblewrap)
to isolate subprocesses (shell commands) spawned by the agent.

- **User namespaces** isolate the filesystem view
- **Filesystem isolation** restricts access to host paths
- **Seccomp filters** restrict available system calls
- **Unix socket blocking** (`blockUnixSockets: true`) prevents IPC with host
  services (Docker, systemd, D-Bus)

An AppArmor profile is installed to allow bwrap to create user namespaces on
Ubuntu 24.04, which restricts unprivileged user namespaces by default.

## Status Line

A status line at the bottom of the Claude Code terminal provides real-time
visibility into the active security layers:

```
[Claude Opus 4.6] 45% | FW:ON | NNP
```

- **FW:ON/OFF** — whether the iptables firewall is active
- **NNP** — whether `NoNewPrivs` is set on the process

## Getting Started

```bash
# 1. Clone the repo
git clone https://github.com/<you>/claude-setup.git
cd claude-setup

# 2. Create your config from the template
cp sandbox.conf.example sandbox.conf

# 3. Edit sandbox.conf with your values (git identity, SSH key, etc.)
$EDITOR sandbox.conf

# 4. Launch the VM (creates, provisions, and prints SSH info)
./start-cc-sandbox.sh
```

## Quick Start

```bash
# Launch or resume the VM (from macOS host)
./start-cc-sandbox.sh

# SSH into the VM
ssh ubuntu@<vm-ip>

# Enable the firewall (path shown in bootstrap output)
sudo <scripts-dir>/firewall-up.sh

# Run Claude Code (alias applies --no-new-privs automatically)
c
```

## Backup & Restore

```bash
# Backup Claude Code config (~/.claude/ and ~/.claude.json)
claude-backup

# Restore from latest backup
claude-restore
```

## Files

| File                       | Purpose                                          |
|----------------------------|--------------------------------------------------|
| `sandbox.conf.example`    | Configuration template (copy to `sandbox.conf`)  |
| `lib.sh`                  | Shared config loader and log helpers             |
| `start-cc-sandbox.sh`     | Create/start the Multipass VM                    |
| `bootstrap-ubuntu-24.04.sh`| Provision the VM (packages, users, config)      |
| `firewall-up.sh`          | Enable the outbound allowlist firewall           |
| `firewall-down.sh`        | Disable the firewall                             |
| `allowed-domains.conf`    | Outbound domain allowlist                        |
| `claude-noprivs`          | Wrapper that sets `--no-new-privs`               |
| `statusline.sh`           | Status bar showing firewall and NNP state        |
| `backup-claude.sh`        | Backup `~/.claude/` config                       |
| `restore-claude.sh`       | Restore from backup                              |
