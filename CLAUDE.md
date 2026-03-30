# Epoxy — Secure Claude Code Sandbox

You are running inside a secure Docker container (Debian Bookworm).

## GSD Workflow

This sandbox uses **GSD (Get Shit Done)** as its development workflow system. GSD commands are pre-installed globally and available in every session via `/gsd:*` slash commands.

### Core workflow

| Command | Purpose |
|---------|---------|
| `/gsd:new-project` | Initialize: questions, research, requirements, roadmap |
| `/gsd:discuss-phase [N]` | Capture implementation decisions before planning |
| `/gsd:plan-phase [N]` | Research, create plans, verify them |
| `/gsd:execute-phase [N]` | Execute plans in parallel waves |
| `/gsd:verify-work [N]` | Manual acceptance testing |
| `/gsd:ship [N]` | Create PR from completed work |
| `/gsd:quick` | Ad-hoc tasks without full planning |
| `/gsd:next` | Auto-detect next workflow step |
| `/gsd:help` | Show all available commands |

### Principles

- **Spec-driven**: PROJECT.md, REQUIREMENTS.md, ROADMAP.md, STATE.md keep context organized
- **Context engineering**: Specs are sized to avoid context window degradation
- **Wave execution**: Independent tasks run in parallel, dependent tasks wait
- **Atomic commits**: Each task gets its own commit with a clear message

Use GSD commands for all non-trivial work. For quick one-off fixes, `/gsd:quick` is fine.

## Environment

- **User**: `claude` with passwordless sudo
- **Shell**: bash
- **Node.js**: 22.x
- **Python**: 3.x (use `python3 -m venv .venv` for isolation)
- **Go**: 1.23.x
- **Docker CLI**: Available if host socket is mounted (check `docker info`)

## Workspace Layout

```
/workspace/
├── input/      <- Host files (READ-ONLY)
├── output/     <- Deliverables (persisted to host)
│   └── logs/   <- Session logs
├── cases/      <- Session data (persisted)
│   └── sessions/
├── project/    <- Project source code
└── temp/       <- Scratch space (tmpfs, 2GB max, wiped on restart)
```

**Read-only**: `/workspace/input/` — never attempt to write here.
**Persisted**: `/workspace/output/` and `/workspace/cases/` survive container restarts.
**Ephemeral**: `/workspace/temp/` is tmpfs — fast but lost on restart.

## Exporting Work

Write all deliverables to `/workspace/output/`. To package for export:

```bash
tar czf /workspace/output/deliverable.tar.gz -C /workspace/project .
```

From the host, use `run.sh --export` or `run.sh --export-to /path/on/host` to copy project files out.

## Available Tools

### Development
- `git`, `node`, `npm`, `python3`, `pip`, `go`
- `rg` (ripgrep), `fd` (fd-find), `jq`, `tree`, `tmux`, `vim`

### Network
- `curl`, `wget`, `dig`, `socat`

## Preferred Stacks

- **Server-rendered web**: Go + chi + Templ + HTMX + Tailwind + SQLite
- **Mobile / SPA**: React + Vite + Supabase + Capacitor
- **CLI tools**: Go

## Constraints

- **No GUI** — terminal only, no X11/Wayland
- **Egress firewall** — only allowlisted domains are reachable (Anthropic API, npm, GitHub, PyPI, Go proxy, Debian repos). If you need an external resource, tell the user to add it to `EXTRA_FW_DOMAINS`.
- **Container is ephemeral** — only `/workspace/output/`, `/workspace/cases/`, and auth volumes persist
- **Temp is tmpfs** — 2GB max, wiped on restart
- **Input is read-only** — copy to project or temp before modifying
