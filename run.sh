#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# ── Defaults ────────────────────────────────────────────────────────
MODE="interactive"
ACTIVE_PROJECT=""
SESSION_NAME=""
PROFILE_NAME=""
SAVE_PROFILE=0
EXPORT_PATH=""
EXPORT_DEST=""
HEADLESS_PROMPT=""
DELETE_TARGET=""
DIND=false
EXTRA_ENV=()
EXTRA_VOLUMES=()
NO_FIREWALL=0
NO_LOG=0
NO_DEPS=0
NO_UPDATE=0
PIN_VERSION=0

PROJECTS_DIR="$SCRIPT_DIR/projects"

# ── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Epoxy — Claude Code Sandbox

Usage: ./run.sh <project> [OPTIONS] [prompt...]
       ./run.sh --list | --status | --delete <project>

Project Commands:
  <project>                 Resume/start a project (interactive)
  <project> "prompt"        Run headless against a project
  <project> --shell         Shell into a project container
  --list                    List all projects
  --delete <project>        Delete a project and its data
  --status                  Show projects, auth, volumes
  --continue                Resume most recently used project
  --build                   Build/rebuild the sandbox image

Options:
  --session NAME            Override session name
  --profile NAME            Load a named profile
  --profile NAME --save     Save current flags as a profile
  --dind                    Enable Docker-in-Docker
  --no-firewall             Disable egress firewall
  --no-log                  Disable terminal logging
  --no-deps                 Skip dependency auto-detection
  --no-update               Skip Claude Code update check
  --pin-version             Pin to installed version
  --export [path]           Export project files to host
  --export-to DEST          Export project files to specific path
  -h, --help                Show this help

Examples:
  ./setup.sh                            # Create a new project
  ./run.sh my-firmware                  # Resume a project
  ./run.sh my-firmware --shell          # Shell into project
  ./run.sh my-firmware "review main.c"  # Headless prompt
  ./run.sh --list                       # Show all projects
  ./run.sh --delete old-project         # Remove a project

EOF
    exit 0
}

# ── Legacy Migration ────────────────────────────────────────────────
migrate_legacy() {
    # Auto-migrate old single-project layout to projects/ structure
    if [ -d "$PROJECTS_DIR" ]; then
        return 0
    fi

    # Check if there's an old-style .env to migrate
    if [ ! -f "$SCRIPT_DIR/.env" ] && [ ! -f "$SCRIPT_DIR/docker-compose.override.yml" ]; then
        mkdir -p "$PROJECTS_DIR"
        return 0
    fi

    echo -e "${YELLOW}Migrating to multi-project layout...${NC}"

    # Read project name from old .env
    local name="default"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        name=$(grep -oP '^PROJECT_NAME=\K.+' "$SCRIPT_DIR/.env" 2>/dev/null || true)
        name=$(grep -oP '^SESSION_NAME=\K.+' "$SCRIPT_DIR/.env" 2>/dev/null || echo "${name:-default}")
    fi
    name="${name:-default}"

    local project_dir="$PROJECTS_DIR/$name"
    mkdir -p "$project_dir/cases" "$project_dir/snapshot"

    # Extract auth into shared .auth.env
    if [ -f "$SCRIPT_DIR/.env" ]; then
        grep -E '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=' "$SCRIPT_DIR/.env" \
            > "$PROJECTS_DIR/.auth.env" 2>/dev/null || true
        chmod 600 "$PROJECTS_DIR/.auth.env" 2>/dev/null || true

        # Generate project.env (non-auth lines)
        grep -vE '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|#|$)' "$SCRIPT_DIR/.env" \
            > "$project_dir/project.env" 2>/dev/null || true
    fi

    # Move docker-compose.override.yml
    if [ -f "$SCRIPT_DIR/docker-compose.override.yml" ]; then
        cp "$SCRIPT_DIR/docker-compose.override.yml" "$project_dir/compose.yml"
    fi

    # Move cases
    if [ -d "$SCRIPT_DIR/cases" ] && [ -n "$(ls -A "$SCRIPT_DIR/cases" 2>/dev/null)" ]; then
        cp -r "$SCRIPT_DIR/cases/"* "$project_dir/cases/" 2>/dev/null || true
    fi

    # Move project snapshot
    if [ -d "$SCRIPT_DIR/project-snapshot/$name" ]; then
        cp -r "$SCRIPT_DIR/project-snapshot/$name/"* "$project_dir/snapshot/" 2>/dev/null || true
    elif [ -d "$SCRIPT_DIR/project-snapshot" ] && [ -n "$(ls -A "$SCRIPT_DIR/project-snapshot" 2>/dev/null)" ]; then
        # Try first subdir
        local first_snap
        first_snap=$(ls -d "$SCRIPT_DIR/project-snapshot/"*/ 2>/dev/null | head -1)
        if [ -n "$first_snap" ]; then
            cp -r "$first_snap"* "$project_dir/snapshot/" 2>/dev/null || true
        fi
    fi

    # Create metadata
    cat > "$project_dir/metadata.json" <<MEOF
{
  "name": "$name",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_used": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "description": "Migrated from legacy layout"
}
MEOF

    echo -e "${GREEN}✓${NC} Migrated project: ${CYAN}$name${NC}"
    echo -e "  ${DIM}Config: $project_dir/${NC}"
}

# ── Project Management ──────────────────────────────────────────────
activate_project() {
    local name="$1"
    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir" ]; then
        echo -e "${RED}Project not found: $name${NC}"
        echo ""
        list_projects
        echo ""
        echo -e "Create a new project with: ${CYAN}./setup.sh${NC}"
        exit 1
    fi

    ACTIVE_PROJECT="$name"

    # Default session name to project name unless overridden
    if [ -z "$SESSION_NAME" ]; then
        SESSION_NAME="$name"
    fi

    # Merge auth + project config into transient .env
    {
        echo "# Epoxy — transient .env for project: $name"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$PROJECTS_DIR/.auth.env" 2>/dev/null || true
        echo ""
        cat "$project_dir/project.env" 2>/dev/null || true
    } > "$SCRIPT_DIR/.env"
    chmod 600 "$SCRIPT_DIR/.env"

    # Update last_used in metadata
    if [ -f "$project_dir/metadata.json" ] && command -v jq &>/dev/null; then
        local tmp
        tmp=$(jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_used = $t' "$project_dir/metadata.json" 2>/dev/null) || true
        if [ -n "$tmp" ]; then
            echo "$tmp" > "$project_dir/metadata.json"
        fi
    fi
}

list_projects() {
    if [ ! -d "$PROJECTS_DIR" ] || [ -z "$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
        echo -e "  ${DIM}No projects. Create one with: ./setup.sh${NC}"
        return
    fi

    printf "  ${BOLD}%-20s %-10s %-20s %s${NC}\n" "PROJECT" "MODE" "LAST USED" "SOURCE"
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        local name mode last_used source_path
        name=$(basename "$d")
        mode=""
        last_used=""
        source_path=""

        if [ -f "${d}metadata.json" ]; then
            mode=$(jq -r '.project_mode // ""' "${d}metadata.json" 2>/dev/null || true)
            last_used=$(jq -r '.last_used // ""' "${d}metadata.json" 2>/dev/null || true)
            source_path=$(jq -r '.project_path // ""' "${d}metadata.json" 2>/dev/null || true)

            # Human-friendly relative time
            if [ -n "$last_used" ] && [ "$last_used" != "null" ]; then
                local ts now diff
                ts=$(date -d "$last_used" +%s 2>/dev/null || echo "0")
                now=$(date +%s)
                diff=$((now - ts))
                if [ "$diff" -lt 60 ]; then
                    last_used="just now"
                elif [ "$diff" -lt 3600 ]; then
                    last_used="$((diff / 60))m ago"
                elif [ "$diff" -lt 86400 ]; then
                    last_used="$((diff / 3600))h ago"
                else
                    last_used="$((diff / 86400))d ago"
                fi
            fi
        fi

        printf "  ${CYAN}%-20s${NC} %-10s %-20s %s\n" \
            "$name" "${mode:-—}" "${last_used:-—}" "${source_path:-—}"
    done
}

delete_project() {
    local name="$1"
    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir" ]; then
        echo -e "${RED}Project not found: $name${NC}"
        exit 1
    fi

    # Show what will be deleted
    local size
    size=$(du -sh "$project_dir" 2>/dev/null | cut -f1)
    echo -e "  Project: ${CYAN}$name${NC}"
    echo -e "  Path:    $project_dir"
    echo -e "  Size:    $size"
    echo ""

    read -rp "  Delete this project? [y/N]: " confirm
    case "$confirm" in
        [yY]*)
            rm -rf "$project_dir"
            echo -e "${GREEN}✓${NC} Project deleted: $name"
            echo -e "  ${DIM}Auth volumes are shared and were not affected.${NC}"
            ;;
        *)
            echo "  Cancelled."
            ;;
    esac
}

# ── Profile System ──────────────────────────────────────────────────
load_profile() {
    local profile_file="$SCRIPT_DIR/profiles/${1}.conf"
    if [ ! -f "$profile_file" ]; then
        echo -e "${RED}Profile not found: $1${NC}"
        list_profiles
        exit 1
    fi

    echo -e "${CYAN}Loading profile: $1${NC}"
    while IFS='=' read -r key value; do
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            SESSION_NAME)     SESSION_NAME="$value" ;;
            DIND)             DIND="$value" ;;
            SKIP_FIREWALL)    [[ "$value" == "1" ]] && NO_FIREWALL=1 ;;
            SKIP_DEPS)        [[ "$value" == "1" ]] && NO_DEPS=1 ;;
            SKIP_UPDATE)      [[ "$value" == "1" ]] && NO_UPDATE=1 ;;
            PIN_VERSION)      [[ "$value" == "1" ]] && PIN_VERSION=1 ;;
            ENABLE_LOGGING)   [[ "$value" == "0" ]] && NO_LOG=1 ;;
            EXTRA_FW_DOMAINS) EXTRA_ENV+=("-e" "EXTRA_FW_DOMAINS=$value") ;;
            EXTRA_VOLUME)     EXTRA_VOLUMES+=("-v" "$value") ;;
            *)                EXTRA_ENV+=("-e" "${key}=${value}") ;;
        esac
    done < "$profile_file"
}

save_profile() {
    local profile_file="$SCRIPT_DIR/profiles/${1}.conf"
    cat > "$profile_file" <<EOF
# Profile: $1
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
DIND=${DIND}
SKIP_FIREWALL=${NO_FIREWALL}
SKIP_DEPS=${NO_DEPS}
SKIP_UPDATE=${NO_UPDATE}
PIN_VERSION=${PIN_VERSION}
ENABLE_LOGGING=$([[ "$NO_LOG" == "1" ]] && echo "0" || echo "1")
EOF
    echo -e "${GREEN}Profile saved: $profile_file${NC}"
}

list_profiles() {
    echo -e "${BOLD}Profiles:${NC}"
    for f in "$SCRIPT_DIR/profiles/"*.conf; do
        [ -f "$f" ] || continue
        local name desc
        name=$(basename "$f" .conf)
        desc=$(head -1 "$f" | sed 's/^# //')
        echo -e "  ${CYAN}$name${NC} — $desc"
    done
}

# ── Parse Args ──────────────────────────────────────────────────────
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --headless)     MODE="headless"; HEADLESS_PROMPT="${2:-}"; shift ;;
        --shell)        MODE="shell" ;;
        --build)        MODE="build" ;;
        --export)       MODE="export"; EXPORT_PATH="${2:-/workspace/project}"; [[ "${2:-}" != --* ]] && [[ -n "${2:-}" ]] && shift ;;
        --export-to)    MODE="export"; EXPORT_PATH="/workspace/project"; EXPORT_DEST="${2:?--export-to requires a path}"; shift ;;
        --down)         MODE="down" ;;
        --status)       MODE="status" ;;
        --list)         MODE="list" ;;
        --delete)       MODE="delete"; DELETE_TARGET="${2:?--delete requires a project name}"; shift ;;
        --continue)     MODE="continue" ;;
        --session)      SESSION_NAME="${2:?--session requires a name}"; shift ;;
        --profile)
            PROFILE_NAME="${2:?--profile requires a name}"; shift
            if [[ "${2:-}" == "--save" ]]; then SAVE_PROFILE=1; shift; fi
            ;;
        --profiles)     MODE="list-profiles" ;;
        --dind)         DIND=true ;;
        --no-firewall)  NO_FIREWALL=1 ;;
        --no-log)       NO_LOG=1 ;;
        --no-deps)      NO_DEPS=1 ;;
        --no-update)    NO_UPDATE=1 ;;
        --pin-version)  PIN_VERSION=1 ;;
        -h|--help)      usage ;;
        -*)             echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        *)              POSITIONAL+=("$1") ;;
    esac
    shift
done

# ── Load Profile ────────────────────────────────────────────────────
if [ -n "$PROFILE_NAME" ]; then
    if [ "$SAVE_PROFILE" -eq 1 ]; then
        save_profile "$PROFILE_NAME"
        exit 0
    fi
    load_profile "$PROFILE_NAME"
fi

# ── Resolve project from positional args ────────────────────────────
# First positional arg: if it matches a project dir, use it as project name.
# Remaining args (or all args if first isn't a project) become headless prompt.
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    FIRST="${POSITIONAL[0]}"
    if [ -d "$PROJECTS_DIR/$FIRST" ]; then
        ACTIVE_PROJECT="$FIRST"
        POSITIONAL=("${POSITIONAL[@]:1}")
        # Remaining positional args = headless prompt
        if [ "${#POSITIONAL[@]}" -gt 0 ]; then
            MODE="headless"
            HEADLESS_PROMPT="${POSITIONAL[*]}"
        fi
    else
        # Not a known project — treat all as headless prompt if we have a default project
        echo -e "${RED}Unknown project: $FIRST${NC}"
        echo ""
        list_projects
        echo ""
        echo -e "Create a new project with: ${CYAN}./setup.sh${NC}"
        exit 1
    fi
fi

# ── Auto-migrate legacy layout ──────────────────────────────────────
migrate_legacy

# ── Compose Helpers ─────────────────────────────────────────────────
compose_run() {
    local project_dir="$PROJECTS_DIR/$ACTIVE_PROJECT"
    local cmd=("docker" "compose"
        "-f" "$SCRIPT_DIR/docker-compose.yml"
        "-f" "$project_dir/compose.yml"
        "run" "--rm")

    # Environment overrides
    [[ "$NO_FIREWALL" == "1" ]] && cmd+=("-e" "SKIP_FIREWALL=1")
    [[ "$NO_LOG" == "1" ]] && cmd+=("-e" "ENABLE_LOGGING=0")
    [[ "$NO_DEPS" == "1" ]] && cmd+=("-e" "SKIP_DEPS=1")
    [[ "$NO_UPDATE" == "1" ]] && cmd+=("-e" "SKIP_UPDATE=1")
    [[ "$PIN_VERSION" == "1" ]] && cmd+=("-e" "PIN_VERSION=1")
    [[ -n "$SESSION_NAME" ]] && cmd+=("-e" "SESSION_NAME=$SESSION_NAME")
    [[ -n "$ACTIVE_PROJECT" ]] && cmd+=("-e" "PROJECT_NAME=$ACTIVE_PROJECT")

    # DinD
    [[ "$DIND" == "true" ]] && cmd+=("-v" "/var/run/docker.sock:/var/run/docker.sock")

    # Extra env and volumes from profile
    cmd+=("${EXTRA_ENV[@]}")
    cmd+=("${EXTRA_VOLUMES[@]}")

    cmd+=("sandbox")
    cmd+=("$@")

    "${cmd[@]}"
}

require_project() {
    if [ -z "$ACTIVE_PROJECT" ]; then
        echo -e "${RED}No project specified.${NC}"
        echo ""
        list_projects
        echo ""
        echo -e "Usage: ${CYAN}./run.sh <project>${NC}"
        echo -e "Create: ${CYAN}./setup.sh${NC}"
        exit 1
    fi
    activate_project "$ACTIVE_PROJECT"
}

# ── Dispatch ────────────────────────────────────────────────────────
case "$MODE" in
    interactive)
        require_project
        echo -e "${BOLD}${CYAN}[$ACTIVE_PROJECT]${NC} Starting interactive session"
        compose_run claude --dangerously-skip-permissions
        ;;

    headless)
        require_project
        if [ -z "$HEADLESS_PROMPT" ]; then
            echo -e "${RED}No prompt provided${NC}"
            exit 1
        fi
        echo -e "${BOLD}${CYAN}[$ACTIVE_PROJECT]${NC} Headless: $HEADLESS_PROMPT"
        compose_run claude --dangerously-skip-permissions -p "$HEADLESS_PROMPT"
        ;;

    shell)
        require_project
        echo -e "${BOLD}${CYAN}[$ACTIVE_PROJECT]${NC} Starting shell"
        compose_run bash
        ;;

    build)
        echo -e "${BOLD}${CYAN}Building sandbox image...${NC}"
        docker compose build
        echo -e "${GREEN}Build complete.${NC}"
        ;;

    export)
        require_project
        echo -e "${BOLD}${CYAN}[$ACTIVE_PROJECT]${NC} Exporting..."
        if [ -n "$EXPORT_DEST" ]; then
            EXPORT_DIR="$EXPORT_DEST"
        else
            EXPORT_DIR="$SCRIPT_DIR/exports/$(date +%Y%m%d_%H%M%S)"
        fi
        mkdir -p "$EXPORT_DIR"

        CONTAINER_ID=$(docker ps -aqf "name=claude-sandbox" | head -1)
        if [ -n "$CONTAINER_ID" ]; then
            docker cp "$CONTAINER_ID:${EXPORT_PATH:-/workspace/project}/." "$EXPORT_DIR/" 2>/dev/null && {
                FILE_COUNT=$(find "$EXPORT_DIR" -type f | wc -l)
                SIZE=$(du -sh "$EXPORT_DIR" | cut -f1)
                echo -e "${GREEN}Exported $FILE_COUNT files ($SIZE) to $EXPORT_DIR/${NC}"
                exit 0
            }
        fi

        docker compose \
            -f "$SCRIPT_DIR/docker-compose.yml" \
            -f "$PROJECTS_DIR/$ACTIVE_PROJECT/compose.yml" \
            run --rm --no-deps -T sandbox \
            tar cf - -C "$(dirname "${EXPORT_PATH:-/workspace/project}")" "$(basename "${EXPORT_PATH:-/workspace/project}")" \
            | tar xf - -C "$EXPORT_DIR/"

        FILE_COUNT=$(find "$EXPORT_DIR" -type f | wc -l)
        SIZE=$(du -sh "$EXPORT_DIR" | cut -f1)
        echo -e "${GREEN}Exported $FILE_COUNT files ($SIZE) to $EXPORT_DIR/${NC}"
        ;;

    down)
        echo -e "${YELLOW}Stopping sandbox...${NC}"
        docker compose down
        echo -e "${GREEN}Sandbox stopped.${NC}"
        ;;

    continue)
        # Find most recently used project
        if [ ! -d "$PROJECTS_DIR" ]; then
            echo -e "${RED}No projects found.${NC}"
            exit 1
        fi
        LATEST=""
        LATEST_TS=0
        for d in "$PROJECTS_DIR"/*/; do
            [ -d "$d" ] || continue
            if [ -f "${d}metadata.json" ]; then
                local_ts=$(jq -r '.last_used // ""' "${d}metadata.json" 2>/dev/null || true)
                if [ -n "$local_ts" ] && [ "$local_ts" != "null" ]; then
                    epoch=$(date -d "$local_ts" +%s 2>/dev/null || echo "0")
                    if [ "$epoch" -gt "$LATEST_TS" ]; then
                        LATEST_TS=$epoch
                        LATEST=$(basename "$d")
                    fi
                fi
            fi
        done
        if [ -z "$LATEST" ]; then
            echo -e "${RED}No projects with usage history.${NC}"
            exit 1
        fi
        ACTIVE_PROJECT="$LATEST"
        activate_project "$ACTIVE_PROJECT"
        echo -e "${BOLD}${CYAN}[$ACTIVE_PROJECT]${NC} Resuming..."
        compose_run claude --dangerously-skip-permissions
        ;;

    list)
        echo -e "${BOLD}${CYAN}Epoxy Projects${NC}"
        echo ""
        list_projects
        echo ""
        echo -e "  ${DIM}Resume: ./run.sh <project>${NC}"
        echo -e "  ${DIM}Create: ./setup.sh${NC}"
        ;;

    delete)
        delete_project "$DELETE_TARGET"
        ;;

    status)
        echo -e "${BOLD}${CYAN}Epoxy Status${NC}"
        echo ""

        # Projects
        echo -e "${BOLD}Projects:${NC}"
        list_projects
        echo ""

        # Auth
        echo -e "${BOLD}Authentication:${NC}"
        COMPOSE_PROJECT=$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        AUTH_VOLUME="${COMPOSE_PROJECT}_claude-sandbox-auth-config"
        if docker volume inspect "$AUTH_VOLUME" &>/dev/null 2>&1; then
            HAS_CREDS=$(docker run --rm -v "${AUTH_VOLUME}:/data" alpine sh -c \
                'test -f /data/.credentials.json && echo yes || echo no' 2>/dev/null || echo "no")
            if [ "$HAS_CREDS" = "yes" ]; then
                echo -e "  ${GREEN}✓${NC} Stored credentials (interactive login)"
            else
                echo -e "  ${DIM}Auth volume exists, no stored credentials${NC}"
            fi
        else
            echo -e "  ${DIM}No auth volume${NC}"
        fi
        if [ -f "$PROJECTS_DIR/.auth.env" ] && grep -qE '^ANTHROPIC_API_KEY=sk-' "$PROJECTS_DIR/.auth.env" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} API key configured"
        fi
        echo ""

        # Volumes
        echo -e "${BOLD}Docker Volumes:${NC}"
        docker volume ls --filter "name=${COMPOSE_PROJECT}_claude-sandbox" --format "  {{.Name}}" 2>/dev/null || echo "  None"
        echo ""

        # Profiles
        echo -e "${BOLD}Profiles:${NC}"
        for f in "$SCRIPT_DIR/profiles/"*.conf; do
            [ -f "$f" ] && echo "  $(basename "$f" .conf)"
        done
        echo ""

        # Logs
        echo -e "${BOLD}Recent Logs:${NC}"
        LOGS=$(ls -t "$SCRIPT_DIR/output/logs/"*.log 2>/dev/null | head -5)
        if [ -n "$LOGS" ]; then
            echo "$LOGS" | while read -r f; do
                echo "  $(basename "$f")"
            done
        else
            echo -e "  ${DIM}None${NC}"
        fi
        ;;

    list-profiles)
        list_profiles
        ;;
esac
