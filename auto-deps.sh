#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${1:-/workspace/project}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "📦 No project directory found at $PROJECT_DIR"
    exit 0
fi

echo "📦 Scanning for project dependencies in $PROJECT_DIR..."

cd "$PROJECT_DIR"
FOUND=0

# Go
if [ -f "go.mod" ]; then
    FOUND=1
    echo "   → go.mod detected"
    go mod download 2>&1 | head -5 && echo "   ✓ Go dependencies downloaded" || echo "   ⚠ Go mod download failed"
fi

# Node.js
if [ -f "package.json" ]; then
    FOUND=1
    echo "   → package.json detected"
    if [ -f "package-lock.json" ]; then
        npm ci --ignore-scripts 2>&1 | tail -1 && echo "   ✓ npm ci complete" || echo "   ⚠ npm ci failed"
    elif [ -f "yarn.lock" ]; then
        yarn install --frozen-lockfile --ignore-scripts 2>&1 | tail -1 && echo "   ✓ yarn install complete" || echo "   ⚠ yarn install failed"
    else
        npm install --ignore-scripts 2>&1 | tail -1 && echo "   ✓ npm install complete" || echo "   ⚠ npm install failed"
    fi
fi

# Python requirements.txt
if [ -f "requirements.txt" ]; then
    FOUND=1
    echo "   → requirements.txt detected"
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv 2>/dev/null || true
    fi
    if [ -d ".venv" ]; then
        .venv/bin/pip install -r requirements.txt 2>&1 | tail -3 && echo "   ✓ pip install complete" || echo "   ⚠ pip install failed"
    else
        pip install -r requirements.txt --break-system-packages 2>&1 | tail -3 && echo "   ✓ pip install complete (system)" || echo "   ⚠ pip install failed"
    fi
fi

# Python pyproject.toml
if [ -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
    FOUND=1
    echo "   → pyproject.toml detected"
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv 2>/dev/null || true
    fi
    if [ -d ".venv" ]; then
        .venv/bin/pip install -e . 2>&1 | tail -3 && echo "   ✓ pip install -e . complete" || echo "   ⚠ pip install failed"
    else
        pip install -e . --break-system-packages 2>&1 | tail -3 && echo "   ✓ pip install -e . complete (system)" || echo "   ⚠ pip install failed"
    fi
fi

# Pipfile
if [ -f "Pipfile" ]; then
    FOUND=1
    echo "   → Pipfile detected"
    if command -v pipenv &>/dev/null; then
        pipenv install 2>&1 | tail -3 && echo "   ✓ pipenv install complete" || echo "   ⚠ pipenv install failed"
    else
        echo "   ⚠ pipenv not installed, skipping"
    fi
fi

# Rust
if [ -f "Cargo.toml" ]; then
    FOUND=1
    echo "   → Cargo.toml detected"
    if command -v cargo &>/dev/null; then
        cargo fetch 2>&1 | tail -3 && echo "   ✓ cargo fetch complete" || echo "   ⚠ cargo fetch failed"
    else
        echo "   ⚠ cargo not installed, skipping"
    fi
fi

if [ "$FOUND" -eq 0 ]; then
    echo "   No dependency files found"
fi
