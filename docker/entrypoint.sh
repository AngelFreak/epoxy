#!/usr/bin/env bash
set -euo pipefail

CLAUDE_JSON="/home/claude/.claude.json"
CLAUDE_JSON_PERSIST="/home/claude/.claude/.claude.json.persist"

# ── Restore .claude.json from volume ────────────────────────────────
# Claude Code stores config at ~/.claude.json (OUTSIDE the .claude/ dir).
# The volume only covers ~/.claude/, so .claude.json is lost when the
# container is removed (--rm). We persist a copy inside the volume and
# restore it on each boot.
if [ ! -f "$CLAUDE_JSON" ]; then
    if [ -f "$CLAUDE_JSON_PERSIST" ]; then
        cp "$CLAUDE_JSON_PERSIST" "$CLAUDE_JSON"
    elif ls /home/claude/.claude/backups/.claude.json.backup.* &>/dev/null 2>&1; then
        LATEST_BACKUP=$(ls -t /home/claude/.claude/backups/.claude.json.backup.* 2>/dev/null | head -1)
        [ -n "$LATEST_BACKUP" ] && cp "$LATEST_BACKUP" "$CLAUDE_JSON"
    else
        # Seed with minimal config to skip onboarding prompts
        echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_JSON"
    fi
fi

# Ensure onboarding is marked complete (even if restored from old backup)
if [ -f "$CLAUDE_JSON" ]; then
    if command -v jq &>/dev/null; then
        TMP=$(jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" 2>/dev/null) && \
            echo "$TMP" > "$CLAUDE_JSON" || true
    fi
fi

# ── Refresh config in auth volume ───────────────────────────────────
# The named volume overlays /home/claude/.claude, so image-baked files
# (settings, CLAUDE.md) go stale after rebuilds. Re-copy on every boot.
cp -f /usr/local/share/claude-sandbox/settings.local.json /home/claude/.claude/settings.local.json 2>/dev/null || true
cp -f /usr/local/share/claude-sandbox/CLAUDE.md /home/claude/.claude/CLAUDE.md 2>/dev/null || true

# Ensure settings.json exists with dangerous-mode acceptance
SETTINGS_JSON="/home/claude/.claude/settings.json"
if [ ! -f "$SETTINGS_JSON" ]; then
    echo '{"skipDangerousModePermissionPrompt":true}' > "$SETTINGS_JSON"
elif command -v jq &>/dev/null; then
    TMP=$(jq '.skipDangerousModePermissionPrompt = true' "$SETTINGS_JSON" 2>/dev/null) && \
        echo "$TMP" > "$SETTINGS_JSON" || true
fi

# ── GSD commands ──────────────────────────────────────────────────
# GSD is installed in the image but the auth volume overlays ~/.claude/,
# masking the installed commands. Re-install if missing.
if [ ! -d "/home/claude/.claude/commands/gsd" ] && [ ! -d "/home/claude/.claude/get-shit-done" ]; then
    npx get-shit-done-cc@latest --claude --global 2>/dev/null || true
fi

# ── Banner ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Epoxy — Claude Code Sandbox                ║"
if [ -n "${PROJECT_NAME:-}" ]; then
    printf "║  Project: %-41s ║\n" "$PROJECT_NAME"
fi
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Firewall ────────────────────────────────────────────────────────
if [ "${SKIP_FIREWALL:-0}" != "1" ]; then
    echo "🔒 Configuring egress firewall..."
    sudo init-firewall.sh && echo "   Firewall active" || echo "   ⚠ Firewall setup failed (continuing)"
else
    echo "⚠  Firewall disabled (SKIP_FIREWALL=1)"
fi

# ── Auto-update ─────────────────────────────────────────────────────
if [ "${PIN_VERSION:-0}" != "1" ] && [ "${SKIP_UPDATE:-0}" != "1" ]; then
    echo "🔄 Checking for Claude Code updates..."
    CURRENT=$(claude --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
    LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "unknown" ] && [ "$LATEST" != "unknown" ] && [ "$CURRENT" != "$LATEST" ]; then
        echo "   Updating: $CURRENT → $LATEST"
        sudo npm install -g @anthropic-ai/claude-code@"$LATEST" 2>/dev/null && \
            echo "   ✓ Updated to $LATEST" || echo "   ⚠ Update failed (using $CURRENT)"
    else
        echo "   ✓ Claude Code $CURRENT (up to date)"
    fi
else
    echo "📌 Version pinned or updates skipped"
fi

# ── Docker-in-Docker ───────────────────────────────────────────────
if [ -S /var/run/docker.sock ]; then
    echo ""
    echo "🐳 Docker-in-Docker: available"
    docker info --format '   Engine: {{.ServerVersion}}  OS: {{.OperatingSystem}}' 2>/dev/null || echo "   ⚠ Docker socket found but info unavailable"
fi

# ── Project ────────────────────────────────────────────────────────
PROJECT_DIR="/workspace/project"
mkdir -p "$PROJECT_DIR"
if [ -n "${PROJECT_NAME:-}" ]; then
    echo ""
    echo "📦 Project: ${PROJECT_NAME}"
fi
PROJECT_FILE_COUNT=$(find "$PROJECT_DIR" -maxdepth 1 -not -name '.' 2>/dev/null | wc -l || echo "0")
if [ -n "${PROJECT_REPO:-}" ] && [ "$PROJECT_FILE_COUNT" -eq 0 ]; then
    echo "   Cloning: $PROJECT_REPO"
    git clone "$PROJECT_REPO" "$PROJECT_DIR" 2>&1 | sed 's/^/   /'
    echo "   ✓ Clone complete"
elif [ -n "${PROJECT_REPO:-}" ] && [ "$PROJECT_FILE_COUNT" -gt 0 ]; then
    echo "   Project directory not empty, skipping clone"
fi

# ── Auto-deps ──────────────────────────────────────────────────────
if [ "${SKIP_DEPS:-0}" != "1" ]; then
    echo ""
    auto-deps.sh /workspace/project
fi

# ── Session ────────────────────────────────────────────────────────
if [ -n "${SESSION_NAME:-}" ]; then
    echo ""
    SESSION_DIR="/workspace/cases/sessions/${SESSION_NAME}"
    STATE_DIR="${SESSION_DIR}/state"
    mkdir -p "$STATE_DIR"

    if [ -f "${SESSION_DIR}/metadata.json" ]; then
        echo "📂 Resuming session: $SESSION_NAME"
    else
        echo "📂 New session: $SESSION_NAME"
        cat > "${SESSION_DIR}/metadata.json" <<METAEOF
{
  "session_name": "${SESSION_NAME}",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "container_id": "$(hostname)",
  "claude_version": "$(claude --version 2>/dev/null || echo unknown)"
}
METAEOF
    fi
    export CLAUDE_CONVERSATION_DIR="$STATE_DIR"
fi

# ── Auth check ─────────────────────────────────────────────────────
echo ""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "🔑 Auth: API key configured"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "🔑 Auth: OAuth token configured"
elif [ -f "/home/claude/.claude/.credentials.json" ] || \
     [ -f "/home/claude/.claude/credentials.json" ] || \
     [ -f "/home/claude/.config/claude/credentials.json" ] || \
     [ -f "/home/claude/.claude/auth.json" ]; then
    echo "🔑 Auth: Stored credentials found"
else
    echo "⚠  Auth: No credentials detected — run 'claude login' or set ANTHROPIC_API_KEY"
fi

# ── Project status ─────────────────────────────────────────────────
PROJECT_FILES=$(find /workspace/project -type f 2>/dev/null | wc -l || echo "0")
echo "📁 Project files: $PROJECT_FILES"

# ── Copy CLAUDE.md ─────────────────────────────────────────────────
cp -n /home/claude/.claude/CLAUDE.md /workspace/CLAUDE.md 2>/dev/null || true

# ── Workspace layout ──────────────────────────────────────────────
echo ""
echo "📋 Workspace layout:"
echo "   /workspace/input/    ← Host files (read-only)"
echo "   /workspace/output/   ← Deliverables (persisted)"
echo "   /workspace/cases/    ← Session data (persisted)"
echo "   /workspace/project/  ← Project code"
echo "   /workspace/temp/     ← Scratch space (tmpfs)"
echo ""
echo "────────────────────────────────────────────────────────"
echo ""

# ── Persist helper ─────────────────────────────────────────────────
# Save .claude.json back into the volume so it survives --rm.
# Called after Claude exits (cannot use EXIT trap with exec).
persist_claude_json() {
    cp "$CLAUDE_JSON" "$CLAUDE_JSON_PERSIST" 2>/dev/null || true
}

# ── Logging & launch ──────────────────────────────────────────────
LOG_ENABLED="${ENABLE_LOGGING:-1}"
SESSION_TAG="${SESSION_NAME:-default}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/workspace/output/logs/${SESSION_TAG}_${TIMESTAMP}.log"

if [ "$LOG_ENABLED" = "1" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "📝 Logging to: $LOG_FILE"
    echo ""

    if [ -t 0 ]; then
        CMD=""
        for arg in "$@"; do
            CMD="${CMD:+$CMD }$(printf '%q' "$arg")"
        done
        # Don't exec — stay alive so we can persist after exit
        script -efqc "$CMD" "$LOG_FILE"
        EXIT_CODE=$?
        persist_claude_json
        exit $EXIT_CODE
    else
        "$@" 2>&1 | tee "$LOG_FILE"
        EXIT_CODE=$?
        persist_claude_json
        exit $EXIT_CODE
    fi
else
    "$@"
    EXIT_CODE=$?
    persist_claude_json
    exit $EXIT_CODE
fi
