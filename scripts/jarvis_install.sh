#!/usr/bin/env bash
# jarvis_install - idempotent installer for jarvis_branch + jarvis_pr helpers
#
# Usage: bash <path>/jarvis_install.sh
#
# Adds the scripts directory to PATH via shell rc (zsh or bash).
# Idempotent: detects existing PATH entry and skips re-add.
#
# Exit codes:
#   0 - success (newly installed OR already configured)
#   1 - missing prerequisites
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARKER="# JARVIS helpers (jarvis-standards)"
readonly PATH_LINE="export PATH=\"$SCRIPT_DIR:\$PATH\""

detect_rc() {
  local sh
  sh=$(basename "${SHELL:-/bin/zsh}")
  case "$sh" in
    zsh) echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *) echo "$HOME/.zshrc" ;;
  esac
}

readonly RC_FILE=$(detect_rc)

echo "-> jarvis-standards scripts: $SCRIPT_DIR"
echo "-> Shell rc: $RC_FILE"
echo ""

# Verify helper commands exist + are executable
for cmd in jarvis_branch jarvis_pr; do
  if [ ! -x "$SCRIPT_DIR/$cmd" ]; then
    echo "ERROR: $SCRIPT_DIR/$cmd missing or not executable" >&2
    exit 1
  fi
done

# Create rc if missing
if [ ! -f "$RC_FILE" ]; then
  echo "-> $RC_FILE does not exist, creating..."
  touch "$RC_FILE"
fi

# Idempotent: skip if already added
if grep -qF "$SCRIPT_DIR" "$RC_FILE" 2>/dev/null; then
  echo "OK: $SCRIPT_DIR already in $RC_FILE - no changes"
  already_installed=1
else
  echo "-> Adding PATH entry to $RC_FILE..."
  {
    echo ""
    echo "$MARKER"
    echo "$PATH_LINE"
  } >> "$RC_FILE"
  echo "OK: PATH entry added"
  already_installed=0
fi

echo ""
echo "Helpers available:"
echo "  jarvis_branch -> $SCRIPT_DIR/jarvis_branch"
echo "  jarvis_pr     -> $SCRIPT_DIR/jarvis_pr"
echo ""
if [ "$already_installed" = "0" ]; then
  echo "Activate in current shell:"
  echo "    source $RC_FILE"
  echo ""
fi
echo "Verify (in a fresh shell):"
echo "    which jarvis_branch && which jarvis_pr"
