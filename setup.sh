#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECTS_DIR="$SCRIPT_DIR/projects"
DOCKER_DIR="$SCRIPT_DIR/docker"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# ── CLI Flags ───────────────────────────────────────────────────────
LAUNCH_MODE="interactive"
HEADLESS_PROMPT=""
NO_LAUNCH=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --headless)  LAUNCH_MODE="headless"; HEADLESS_PROMPT="${2:?--headless requires a prompt}"; shift ;;
        --shell)     LAUNCH_MODE="shell" ;;
        --no-launch) NO_LAUNCH=1 ;;
        -h|--help)
            cat <<'EOF'
Epoxy — New Project Wizard

Usage: ./setup.sh [OPTIONS]

Creates a new named project with its own config, volumes, and session data.
Each project is stored in projects/<name>/ and does not affect other projects.

Options:
  --headless "prompt"   After setup, run Claude headlessly with this prompt
  --shell               After setup, drop into bash instead of Claude
  --no-launch           Generate config only, don't build or launch
  -h, --help            Show this help
EOF
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
    shift
done

# ── Helpers ─────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          Epoxy — New Project                        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━ $1 ━━━${NC}"
    echo ""
}

print_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()  { echo -e "  ${RED}✗${NC} $1"; }
print_info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

prompt_yn() {
    local prompt="$1" default="${2:-y}"
    local yn_hint
    if [ "$default" = "y" ]; then yn_hint="[Y/n]"; else yn_hint="[y/N]"; fi
    while true; do
        read -rp "  $prompt $yn_hint: " answer
        answer=${answer:-$default}
        case "$answer" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
        esac
    done
}

prompt_choice() {
    local prompt="$1"; shift
    local options=("$@")
    for i in "${!options[@]}"; do
        echo -e "    ${CYAN}$((i+1)))${NC} ${options[$i]}"
    done
    while true; do
        read -rp "  $prompt [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            CHOICE=$((choice - 1))
            return 0
        fi
        echo -e "  ${RED}Invalid choice${NC}"
    done
}

# ── State variables ─────────────────────────────────────────────────
DEVICES=()
DEVICE_SELECTIONS=()
AUTH_METHOD=""
API_KEY=""
OAUTH_TOKEN=""
PROJECT_NAME=""
PROJECT_MODE=""
PROJECT_PATH=""
PROJECT_REPO=""
PROJECT_DESC=""
MEM_LIMIT="8g"
GPU_ENABLED=0
GPU_COUNT=""
EXTRA_DOMAINS=()
FIREWALL_MODE="strict"
OVERRIDE_DEVICES=()
OVERRIDE_VOLUMES=()

print_header

# ═══════════════════════════════════════════════════════════════════
# Step 1: Pre-flight checks
# ═══════════════════════════════════════════════════════════════════
print_section "1/7 Pre-flight Checks"

if ! command -v docker &>/dev/null; then
    print_err "Docker not found. Please install Docker first."
    exit 1
fi
print_ok "Docker CLI found"

if docker compose version &>/dev/null; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    print_ok "Docker Compose v${COMPOSE_VERSION}"
else
    print_err "Docker Compose not found."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    print_err "Docker daemon not running. Start it and try again."
    exit 1
fi
print_ok "Docker daemon running"

print_info "Platform: $(uname -s) ($(uname -m))"

# Show existing projects
mkdir -p "$PROJECTS_DIR"
EXISTING=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [ "$EXISTING" -gt 0 ]; then
    print_info "Existing projects: $EXISTING"
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] && echo -e "    ${DIM}$(basename "$d")${NC}"
    done
fi

# ═══════════════════════════════════════════════════════════════════
# Step 2: Project Name & Source
# ═══════════════════════════════════════════════════════════════════
print_section "2/7 Project Name & Source"

while true; do
    read -rp "  Project name: " PROJECT_NAME
    if [ -z "$PROJECT_NAME" ]; then
        print_warn "Name required"
        continue
    fi
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')

    if [ -d "$PROJECTS_DIR/$PROJECT_NAME" ]; then
        print_warn "Project '$PROJECT_NAME' already exists"
        if prompt_yn "Overwrite existing project?" "n"; then
            break
        fi
    else
        break
    fi
done
print_ok "Project: $PROJECT_NAME"

read -rp "  Description (optional): " PROJECT_DESC

echo ""
echo "  Project source:"
prompt_choice "Select" \
    "Mount a local directory" \
    "Clone a Git repo at container start" \
    "No project (empty workspace)"

case $CHOICE in
    0)  # Local directory
        read -rep "  Project path: " PROJECT_PATH
        PROJECT_PATH=$(eval echo "$PROJECT_PATH")

        if [ ! -d "$PROJECT_PATH" ]; then
            print_err "Directory not found: $PROJECT_PATH"
            PROJECT_PATH=""
        else
            FILE_COUNT=$(find "$PROJECT_PATH" -maxdepth 3 -type f 2>/dev/null | wc -l)
            DIR_SIZE=$(du -sh "$PROJECT_PATH" 2>/dev/null | cut -f1)
            print_info "$FILE_COUNT files, $DIR_SIZE total"

            echo ""
            echo "  Mount mode:"
            prompt_choice "Select" \
                "Copy (snapshot into container, safe)" \
                "Bind mount read-write (live, editable)" \
                "Bind mount read-only"
            case $CHOICE in
                0) PROJECT_MODE="copy";    print_ok "Project will be copied (snapshot)" ;;
                1) PROJECT_MODE="bind-rw"; print_ok "Project will be bind-mounted read-write" ;;
                2) PROJECT_MODE="bind-ro"; print_ok "Project will be bind-mounted read-only" ;;
            esac
        fi
        ;;
    1)  # Clone
        read -rp "  Git repo URL: " PROJECT_REPO
        if [ -n "$PROJECT_REPO" ]; then
            PROJECT_MODE="clone"
            print_ok "Will clone at startup: $PROJECT_REPO"
        else
            print_warn "No URL provided"
        fi
        ;;
    2)  # Empty
        PROJECT_MODE="empty"
        print_info "Empty workspace"
        ;;
esac

# ═══════════════════════════════════════════════════════════════════
# Step 3: Authentication (shared across all projects)
# ═══════════════════════════════════════════════════════════════════
print_section "3/7 Authentication (shared)"

EXISTING_AUTH=0

# Check shared auth file
if [ -f "$PROJECTS_DIR/.auth.env" ]; then
    if grep -qE '^ANTHROPIC_API_KEY=sk-' "$PROJECTS_DIR/.auth.env" 2>/dev/null; then
        print_ok "Existing API key found"
        EXISTING_AUTH=1
    elif grep -qE '^CLAUDE_CODE_OAUTH_TOKEN=.+' "$PROJECTS_DIR/.auth.env" 2>/dev/null; then
        print_ok "Existing OAuth token found"
        EXISTING_AUTH=1
    fi
fi

# Check Docker volume
COMPOSE_PROJECT=$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
AUTH_VOLUME="${COMPOSE_PROJECT}_claude-sandbox-auth-config"
if docker volume inspect "$AUTH_VOLUME" &>/dev/null 2>&1; then
    HAS_CREDS=$(docker run --rm -v "${AUTH_VOLUME}:/data" alpine sh -c \
        'test -f /data/.credentials.json && echo yes || echo no' 2>/dev/null || echo "no")
    if [ "$HAS_CREDS" = "yes" ]; then
        print_ok "Stored credentials in Docker volume (interactive login)"
        EXISTING_AUTH=1
    fi
fi

if [ "$EXISTING_AUTH" -eq 1 ]; then
    print_info "Auth is shared across all projects — no setup needed."
    AUTH_METHOD="existing"
    if prompt_yn "Reconfigure authentication anyway?" "n"; then
        AUTH_METHOD=""
    fi
fi

if [ -z "$AUTH_METHOD" ]; then
    echo "  Authentication method:"
    prompt_choice "Select" \
        "API key (paste now)" \
        "OAuth token" \
        "Interactive login (in container)" \
        "Skip (configure later)"
    case $CHOICE in
        0)
            AUTH_METHOD="api_key"
            read -rsp "  Paste API key: " API_KEY
            echo ""
            if [[ "$API_KEY" == sk-ant-* ]] || [[ "$API_KEY" == sk-* ]]; then
                print_ok "API key accepted"
            else
                print_warn "Key format unexpected (continuing anyway)"
            fi
            ;;
        1)
            AUTH_METHOD="oauth"
            read -rsp "  Paste OAuth token: " OAUTH_TOKEN
            echo ""
            print_ok "OAuth token accepted"
            ;;
        2)
            AUTH_METHOD="interactive"
            print_info "You'll log in when the container starts"
            ;;
        3)
            AUTH_METHOD="skip"
            print_warn "No auth — set later in projects/.auth.env"
            ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════
# Step 4: USB Devices
# ═══════════════════════════════════════════════════════════════════
print_section "4/7 USB Devices"

declare -A VENDOR_CATEGORY=(
    ["0403"]="🔌 Serial"   ["067b"]="🔌 Serial"   ["10c4"]="🔌 Serial"
    ["1a86"]="🔌 Serial"   ["2341"]="🔌 Serial"
    ["1366"]="🔧 Debug"    ["0483"]="🔧 Debug"
    ["0781"]="💾 Storage"  ["0951"]="💾 Storage"
)
declare -A VENDOR_SKIP=(["1d6b"]="1" ["0000"]="1")

USB_FOUND=0
if command -v lsusb &>/dev/null; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ Bus\ ([0-9]+)\ Device\ ([0-9]+):\ ID\ ([0-9a-f]+):([0-9a-f]+)\ (.+) ]]; then
            bus="${BASH_REMATCH[1]}"; dev="${BASH_REMATCH[2]}"
            vid="${BASH_REMATCH[3]}"; pid="${BASH_REMATCH[4]}"; desc="${BASH_REMATCH[5]}"
            [[ -n "${VENDOR_SKIP[$vid]:-}" ]] && continue
            category="${VENDOR_CATEGORY[$vid]:-🔧 Other}"
            DEVICES+=("${bus}|${dev}|${vid}|${pid}|${desc}|${category}")
            USB_FOUND=1
        fi
    done < <(lsusb 2>/dev/null || true)
fi

if [ "$USB_FOUND" -eq 1 ]; then
    echo "  Found ${#DEVICES[@]} USB device(s):"
    echo ""
    for i in "${!DEVICES[@]}"; do
        IFS='|' read -r bus dev vid pid desc category <<< "${DEVICES[$i]}"
        printf "    ${CYAN}%2d)${NC} %s  %s:%s  %s\n" "$((i+1))" "$category" "$vid" "$pid" "$desc"
    done
    echo ""

    prompt_choice "USB passthrough mode" \
        "Select specific devices" \
        "Pass ALL USB devices" \
        "Pass by category" \
        "No USB passthrough"

    case $CHOICE in
        0)
            read -rp "  Device numbers (space-separated): " -a selections
            for sel in "${selections[@]}"; do
                idx=$((sel - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DEVICES[@]}" ]; then
                    IFS='|' read -r bus dev vid pid desc category <<< "${DEVICES[$idx]}"
                    DEVICE_SELECTIONS+=("${DEVICES[$idx]}")
                    OVERRIDE_DEVICES+=("--device=/dev/bus/usb/${bus}/${dev}")
                    print_ok "Selected: $desc"
                fi
            done
            ;;
        1)
            OVERRIDE_VOLUMES+=("/dev/bus/usb:/dev/bus/usb")
            print_ok "All USB devices"
            ;;
        2)
            declare -A seen_cats
            UNIQUE_CATS=()
            for d in "${DEVICES[@]}"; do
                IFS='|' read -r _ _ _ _ _ cat <<< "$d"
                if [ -z "${seen_cats[$cat]:-}" ]; then
                    seen_cats[$cat]=1
                    UNIQUE_CATS+=("$cat")
                fi
            done
            echo ""
            for i in "${!UNIQUE_CATS[@]}"; do
                echo -e "    ${CYAN}$((i+1)))${NC} ${UNIQUE_CATS[$i]}"
            done
            read -rp "  Select categories (space-separated): " -a cat_sels
            for cs in "${cat_sels[@]}"; do
                cidx=$((cs - 1))
                [ "$cidx" -ge 0 ] && [ "$cidx" -lt "${#UNIQUE_CATS[@]}" ] || continue
                selected_cat="${UNIQUE_CATS[$cidx]}"
                for d in "${DEVICES[@]}"; do
                    IFS='|' read -r bus dev vid pid desc category <<< "$d"
                    if [ "$category" = "$selected_cat" ]; then
                        DEVICE_SELECTIONS+=("$d")
                        OVERRIDE_DEVICES+=("--device=/dev/bus/usb/${bus}/${dev}")
                    fi
                done
                print_ok "Category: $selected_cat"
            done
            ;;
        3)
            print_info "No USB passthrough"
            ;;
    esac
else
    print_info "No USB devices detected"
fi

# ═══════════════════════════════════════════════════════════════════
# Step 5: Resources & GPU
# ═══════════════════════════════════════════════════════════════════
print_section "5/7 Resources"

if command -v free &>/dev/null; then
    TOTAL_MEM=$(free -h | awk '/^Mem:/ { print $2 }')
    print_info "Host memory: $TOTAL_MEM"
fi

read -rp "  Container memory limit [8g]: " MEM_INPUT
MEM_LIMIT="${MEM_INPUT:-8g}"
print_ok "Memory: $MEM_LIMIT"

if command -v nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)
    if [ -n "$GPU_INFO" ]; then
        print_info "GPU: $GPU_INFO"
        if prompt_yn "Enable GPU passthrough?" "y"; then
            GPU_ENABLED=1
            prompt_choice "GPU allocation" "All GPUs" "Specific count"
            case $CHOICE in
                0) GPU_COUNT="all" ;;
                1) read -rp "  Number of GPUs: " GPU_COUNT; GPU_COUNT="${GPU_COUNT:-1}" ;;
            esac
            print_ok "GPU: $GPU_COUNT"
        fi
    fi
else
    print_info "No NVIDIA GPU detected"
fi

# ═══════════════════════════════════════════════════════════════════
# Step 6: Firewall
# ═══════════════════════════════════════════════════════════════════
print_section "6/7 Firewall"

echo "  Default allowlist:"
echo -e "    ${DIM}api.anthropic.com, registry.npmjs.org, github.com, pypi.org,${NC}"
echo -e "    ${DIM}deb.debian.org, proxy.golang.org (+ more)${NC}"
echo ""

if prompt_yn "Add extra allowed domains?" "n"; then
    echo "  Enter domains one per line (empty to finish):"
    while true; do
        read -rp "    Domain: " domain
        [[ -z "$domain" ]] && break
        EXTRA_DOMAINS+=("$domain")
    done
    [ "${#EXTRA_DOMAINS[@]}" -gt 0 ] && print_ok "Extra: ${EXTRA_DOMAINS[*]}"
fi

echo ""
prompt_choice "Firewall mode" \
    "Strict (allowlist only, recommended)" \
    "Permissive (disabled)"
case $CHOICE in
    0) FIREWALL_MODE="strict";    print_ok "Strict firewall" ;;
    1) FIREWALL_MODE="permissive"; print_warn "Firewall disabled" ;;
esac

# ═══════════════════════════════════════════════════════════════════
# Step 7: Generate Config & Launch
# ═══════════════════════════════════════════════════════════════════
print_section "7/7 Generate & Launch"

PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR/cases" "$PROJECT_DIR/snapshot"

# ── Shared auth ─────────────────────────────────────────────────────
case "$AUTH_METHOD" in
    api_key)
        echo "ANTHROPIC_API_KEY=$API_KEY" > "$PROJECTS_DIR/.auth.env"
        chmod 600 "$PROJECTS_DIR/.auth.env"
        ;;
    oauth)
        echo "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN" > "$PROJECTS_DIR/.auth.env"
        chmod 600 "$PROJECTS_DIR/.auth.env"
        ;;
    existing)
        # Keep existing .auth.env as-is
        ;;
    *)
        # Create empty if not exists
        touch "$PROJECTS_DIR/.auth.env"
        chmod 600 "$PROJECTS_DIR/.auth.env"
        ;;
esac
print_ok "Auth: $AUTH_METHOD"

# ── project.env ─────────────────────────────────────────────────────
{
    echo "# Project: $PROJECT_NAME"
    echo "PROJECT_NAME=$PROJECT_NAME"
    echo "SESSION_NAME=$PROJECT_NAME"
    if [ "$FIREWALL_MODE" = "permissive" ]; then
        echo "SKIP_FIREWALL=1"
    else
        echo "SKIP_FIREWALL=0"
    fi
    if [ "${#EXTRA_DOMAINS[@]}" -gt 0 ]; then
        echo "EXTRA_FW_DOMAINS=$(IFS=','; echo "${EXTRA_DOMAINS[*]}")"
    fi
    [ -n "$PROJECT_REPO" ] && echo "PROJECT_REPO=$PROJECT_REPO"
    echo "SKIP_UPDATE=0"
    echo "PIN_VERSION=0"
    echo "SKIP_DEPS=0"
    echo "ENABLE_LOGGING=1"
} > "$PROJECT_DIR/project.env"
print_ok "project.env"

# ── compose.yml (per-project override) ──────────────────────────────
{
    echo "# Project: $PROJECT_NAME"
    echo "# Paths are relative to docker/ (where the base docker-compose.yml lives)"
    echo "services:"
    echo "  sandbox:"

    # Devices
    if [ "${#OVERRIDE_DEVICES[@]}" -gt 0 ]; then
        echo "    devices:"
        for d in "${OVERRIDE_DEVICES[@]}"; do
            dev_path="${d#--device=}"
            echo "      - \"${dev_path}:${dev_path}\""
        done
    fi

    # Cgroup rules
    HAS_USB=0
    for d in "${OVERRIDE_DEVICES[@]:-}"; do
        [[ "$d" == *"/dev/bus/usb"* ]] && HAS_USB=1 && break
    done
    for v in "${OVERRIDE_VOLUMES[@]:-}"; do
        [[ "$v" == *"/dev/bus/usb"* ]] && HAS_USB=1 && break
    done
    [ "$HAS_USB" -eq 1 ] && echo "    device_cgroup_rules:" && echo "      - 'c 189:* rwm'"

    # Volumes (paths relative to docker/ where the base docker-compose.yml lives)
    echo "    volumes:"
    echo "      - ../input:/workspace/input:ro"
    echo "      - ../output:/workspace/output"
    echo "      - ../projects/${PROJECT_NAME}/cases:/workspace/cases"

    case "$PROJECT_MODE" in
        bind-rw) echo "      - ${PROJECT_PATH}:/workspace/project" ;;
        bind-ro) echo "      - ${PROJECT_PATH}:/workspace/project:ro" ;;
        copy)    echo "      - ../projects/${PROJECT_NAME}/snapshot:/workspace/project" ;;
        clone)   echo "      # Project cloned at startup into /workspace/project" ;;
        empty)   echo "      # Empty workspace" ;;
    esac

    for v in "${OVERRIDE_VOLUMES[@]:-}"; do
        [[ -n "$v" ]] && echo "      - $v"
    done

    # tmpfs
    echo "    tmpfs:"
    echo "      - /workspace/temp:size=2G,uid=1000,gid=1000"

    # Resources
    echo "    deploy:"
    echo "      resources:"
    echo "        limits:"
    echo "          memory: ${MEM_LIMIT}"
    if [ "$GPU_ENABLED" -eq 1 ]; then
        echo "        reservations:"
        echo "          devices:"
        echo "            - driver: nvidia"
        if [ "$GPU_COUNT" = "all" ]; then
            echo "              count: all"
        else
            echo "              count: ${GPU_COUNT}"
        fi
        echo "              capabilities: [gpu]"
    fi
} > "$PROJECT_DIR/compose.yml"
print_ok "compose.yml"

# ── metadata.json ───────────────────────────────────────────────────
cat > "$PROJECT_DIR/metadata.json" <<MEOF
{
  "name": "$PROJECT_NAME",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_used": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "description": "$PROJECT_DESC",
  "project_mode": "$PROJECT_MODE",
  "project_path": "$PROJECT_PATH",
  "project_repo": "$PROJECT_REPO"
}
MEOF
print_ok "metadata.json"

# ── Project snapshot ────────────────────────────────────────────────
if [ "$PROJECT_MODE" = "copy" ] && [ -n "$PROJECT_PATH" ]; then
    print_info "Copying project snapshot..."
    rsync -a --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='.venv' \
        --exclude='vendor' \
        --exclude='.DS_Store' \
        "$PROJECT_PATH/" "$PROJECT_DIR/snapshot/"
    SNAP_SIZE=$(du -sh "$PROJECT_DIR/snapshot" | cut -f1)
    print_ok "Snapshot: $SNAP_SIZE"
fi

# ── Transient .env (for docker compose) ─────────────────────────────
{
    echo "# Epoxy — transient .env for: $PROJECT_NAME"
    cat "$PROJECTS_DIR/.auth.env" 2>/dev/null || true
    echo ""
    cat "$PROJECT_DIR/project.env"
} > "$SCRIPT_DIR/.env"
chmod 600 "$SCRIPT_DIR/.env"

# Create shared dirs
mkdir -p input output output/logs exports

echo ""
echo -e "  ${BOLD}Summary:${NC}"
echo -e "    Project:  ${CYAN}$PROJECT_NAME${NC} ${PROJECT_DESC:+— $PROJECT_DESC}"
echo -e "    Source:   ${PROJECT_MODE:-none}${PROJECT_PATH:+ ($PROJECT_PATH)}${PROJECT_REPO:+ ($PROJECT_REPO)}"
echo -e "    Memory:   $MEM_LIMIT"
echo -e "    Firewall: $FIREWALL_MODE"
echo -e "    USB:      ${#OVERRIDE_DEVICES[@]} devices"
echo -e "    Config:   projects/$PROJECT_NAME/"
echo ""

if [ "$NO_LAUNCH" -eq 1 ]; then
    print_ok "Config saved (--no-launch)"
    echo ""
    echo "  To run: ./run.sh $PROJECT_NAME"
    exit 0
fi

if ! prompt_yn "Build and launch?" "y"; then
    print_info "Config saved. Run: ./run.sh $PROJECT_NAME"
    exit 0
fi

# Build
echo ""
print_info "Building sandbox image..."
docker compose -f "$DOCKER_DIR/docker-compose.yml" build
print_ok "Image built"

# Launch
echo ""
case "$LAUNCH_MODE" in
    interactive)
        print_ok "Launching: $PROJECT_NAME (interactive)"
        echo ""
        docker compose \
            -f "$DOCKER_DIR/docker-compose.yml" \
            -f "$PROJECT_DIR/compose.yml" \
            run --rm sandbox claude --dangerously-skip-permissions
        ;;
    headless)
        print_ok "Launching: $PROJECT_NAME (headless)"
        echo ""
        docker compose \
            -f "$DOCKER_DIR/docker-compose.yml" \
            -f "$PROJECT_DIR/compose.yml" \
            run --rm sandbox claude --dangerously-skip-permissions -p "$HEADLESS_PROMPT"
        ;;
    shell)
        print_ok "Launching: $PROJECT_NAME (shell)"
        echo ""
        docker compose \
            -f "$DOCKER_DIR/docker-compose.yml" \
            -f "$PROJECT_DIR/compose.yml" \
            run --rm sandbox bash
        ;;
esac

# ── Done ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Project created: ${CYAN}$PROJECT_NAME${NC}"
echo ""
echo "  Resume:  ./run.sh $PROJECT_NAME"
echo "  Shell:   ./run.sh $PROJECT_NAME --shell"
echo "  List:    ./run.sh --list"
echo "  Status:  ./run.sh --status"
echo ""
