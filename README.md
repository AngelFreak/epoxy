# Epoxy

Secure, sandboxed Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network isolation, multi-project management, and hardware passthrough.

## Why

Claude Code runs with full shell access. Epoxy wraps it in a locked-down container so you can let it work autonomously without worrying about what it touches on your host.

- **Egress firewall** -- iptables allowlist limits outbound traffic to Anthropic API, package registries, and GitHub. Everything else is dropped and logged.
- **Multi-project** -- Each project gets its own config, session data, and workspace. Switch between them instantly.
- **Profiles** -- Preconfigured modes (offline, code-review, SDR recon, phone extraction) that tune firewall, updates, and dependency behavior.
- **USB passthrough** -- Selective device forwarding for serial adapters, debug probes, and storage.
- **Persistent auth** -- API keys and OAuth tokens survive container restarts via Docker volumes.

## Quick Start

```bash
# Clone
git clone https://github.com/AngelFreak/epoxy.git
cd epoxy

# Run the setup wizard (builds image, configures auth, creates first project)
./setup.sh

# Resume a project later
./run.sh my-project
```

The setup wizard walks through:

1. Project name and source (local dir, git clone, or empty)
2. Authentication (API key, OAuth, or interactive login)
3. USB device passthrough
4. Resource limits and GPU
5. Firewall configuration

## Usage

```bash
# Interactive session
./run.sh my-project

# Headless (run a prompt and exit)
./run.sh my-project "review main.go for security issues"

# Shell into the container
./run.sh my-project --shell

# Resume most recent project
./run.sh --continue

# List all projects
./run.sh --list

# Project status, auth, volumes
./run.sh --status

# Export project files to host
./run.sh my-project --export
./run.sh my-project --export-to ~/Desktop/output

# Delete a project
./run.sh --delete old-project

# Rebuild the image
./run.sh --build
```

### Profiles

```bash
# Use a profile
./run.sh my-project --profile offline

# Override individual flags
./run.sh my-project --no-firewall --no-update --dind

# Save current flags as a new profile
./run.sh my-project --no-firewall --pin-version --profile my-profile --save

# List profiles
./run.sh --profiles
```

Built-in profiles:

| Profile | Description |
|---------|-------------|
| `offline` | Max isolation -- no updates, no deps, no network except Anthropic API |
| `code-review` | Docker-in-Docker enabled, all features on |
| `phone-extraction` | Pinned version, logging enabled |
| `sdr-recon` | Extra firewall domains for SDR software repos |

## Architecture

```
epoxy/
├── setup.sh              # Interactive project wizard
├── run.sh                # Multi-project CLI
├── Dockerfile            # Sandbox image (Debian Bookworm)
├── docker-compose.yml    # Base compose (auth volumes, security)
├── entrypoint.sh         # Boot: auth restore, firewall, updates, deps
├── init-firewall.sh      # iptables egress allowlist
├── auto-deps.sh          # Detects Go/Node/Python/Rust deps
├── claude-settings.json  # Claude Code permissions for sandbox
├── CLAUDE.md             # In-container instructions for Claude
├── profiles/             # Named config profiles
└── projects/             # Per-project config and data
    ├── .auth.env         # Shared auth (gitignored)
    └── <name>/
        ├── compose.yml   # Volume mounts, resources
        ├── project.env   # Project-specific env vars
        ├── cases/        # Session data (persisted)
        └── snapshot/     # Project file snapshot
```

### Container Layout

```
/workspace/
├── input/      # Host files (read-only)
├── output/     # Deliverables (persisted to host)
│   └── logs/   # Terminal session logs
├── cases/      # Session data (persisted)
├── project/    # Project source code
└── temp/       # Scratch space (tmpfs, 2GB, wiped on restart)
```

### What's in the Image

- **Node.js 22** (Debian Bookworm slim)
- **Go 1.23**
- **Python 3** with venv support
- **Docker CLI** (for Docker-in-Docker when socket is mounted)
- **Claude Code** (latest or pinned version)
- **Tools**: git, ripgrep, fd, jq, tree, tmux, vim, curl, wget, socat

### Egress Firewall

Default allowlist:

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API |
| `statsig.anthropic.com`, `sentry.io` | Claude Code telemetry |
| `registry.npmjs.org`, `registry.yarnpkg.com` | Node packages |
| `github.com`, `api.github.com`, `raw.githubusercontent.com` | Git operations |
| `pypi.org`, `files.pythonhosted.org` | Python packages |
| `proxy.golang.org`, `sum.golang.org` | Go modules |
| `deb.debian.org`, `security.debian.org` | System packages |

Add more with `EXTRA_FW_DOMAINS` in your project env or profile:

```bash
EXTRA_FW_DOMAINS=packages.sdrplay.com,downloads.ettus.com
```

### Security Model

- `no-new-privileges` -- prevents privilege escalation inside the container
- `NET_ADMIN` capability -- required for iptables firewall (only used by init script)
- `SYS_PTRACE` and `NET_RAW` dropped
- Non-root user (`claude`, UID 1000) with passwordless sudo
- Auth credentials stored in Docker named volumes, never in the image
- `--dangerously-skip-permissions` is used intentionally -- the container _is_ the sandbox

## Configuration

Copy and edit `.env.example` for manual setup, or let `setup.sh` handle it:

```bash
cp .env.example .env
```

Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | -- | API key from console.anthropic.com |
| `SKIP_FIREWALL` | `0` | Set `1` to disable egress firewall |
| `SKIP_UPDATE` | `0` | Skip Claude Code update check on boot |
| `PIN_VERSION` | `0` | Don't update Claude Code |
| `SKIP_DEPS` | `0` | Skip auto-dependency detection |
| `ENABLE_LOGGING` | `1` | Terminal session logging |
| `PROJECT_REPO` | -- | Git repo to clone on first start |
| `EXTRA_FW_DOMAINS` | -- | Additional allowed domains (comma-separated) |

## Requirements

- Docker with Compose v2
- Linux host (iptables firewall requires `NET_ADMIN`)
- ~2GB disk for the image

## License

MIT
