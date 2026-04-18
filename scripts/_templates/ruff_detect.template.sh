#!/usr/bin/env bash
# TEMPLATE FILE — @@REPO_NAME@@ ruff detection library
# Source of truth: jarvis-standards/scripts/_templates/ruff_detect.template.sh
# Propagated to:   @@REPO_PATH@@/scripts/_lib/ruff_detect.sh
#
# Provides detect_ruff(): resolves ruff binary path.
# Prefers venv (@@REPO_PATH@@/.venv/bin/ruff), falls back to PATH.
#
# Usage from commit script:
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib/ruff_detect.sh"
#   if ! detect_ruff; then
#       echo "ruff not found — install via @@REPO_PATH@@/.venv/bin/pip install ruff" >&2
#       exit 1
#   fi
#   "$RUFF" check api/ --select E,F,W
#
# Exports on success:
#   RUFF          — path to ruff binary
#   RUFF_SOURCE   — "venv" or "path"
#
# Returns 0 on success, 1 if ruff not found in either location.
# Does not exit — caller decides how to handle failure.

detect_ruff() {
    if [ -x "@@REPO_PATH@@/.venv/bin/ruff" ]; then
        RUFF="@@REPO_PATH@@/.venv/bin/ruff"
        RUFF_SOURCE="venv"
        return 0
    fi
    if command -v ruff >/dev/null 2>&1; then
        RUFF="ruff"
        RUFF_SOURCE="path"
        return 0
    fi
    return 1
}
