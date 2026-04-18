#!/usr/bin/env bash
# TEMPLATE FILE — @@REPO_NAME@@ sync check
# Source of truth: jarvis-standards/scripts/_templates/check_sync.template.sh
# Propagated to:   @@REPO_PATH@@/scripts/check_sync.sh
#
# Pre-flight validator for Sandbox commit flow.
# Guards hostname, repo identity, origin remote, and HEAD vs origin/@@MAIN_BRANCH@@.
# Usage: check_sync.sh [--pre-commit]
#   --pre-commit  Skip dirty-tree check (commit script legitimately has dirty tree)

# check_sandbox_sync.sh — validate Sandbox @@REPO_NAME@@ state before a Claude Code session.
#
# DEBT-026 remediation. Runs on Sandbox (jarvis-forge) at the start of every Claude Code
# session. Read-only: makes no changes to the repo. Fast (< 5s). Exits 0 on clean sync,
# exits 1 with a loud banner on any drift, dirt, or network issue.
#
# Guarantees:
#   - Only runs on Sandbox (hostname contains jarvis-forge)
#   - Only runs from inside the @@REPO_NAME@@ repo
#   - Fails loudly on: uncommitted/untracked files, behind/ahead/diverged from origin/@@MAIN_BRANCH@@,
#     network failure, missing origin remote, not-a-repo
#
# Compatible with bash 3.2 (macOS default) and bash 5.x.

set -euo pipefail

# ---------- Argument parsing ----------
# Default: session-start mode (tree must be clean).
# --pre-commit: pre-commit mode (skip dirty-tree check; all other checks still run).
PRE_COMMIT=false
if [ "$#" -gt 0 ]; then
    case "$1" in
        --pre-commit)
            PRE_COMMIT=true
            ;;
        *)
            printf 'Usage: check_sandbox_sync.sh [--pre-commit]\n' >&2
            exit 1
            ;;
    esac
fi

# ---------- Color helpers (ANSI only if stdout is a TTY) ----------
if [ -t 1 ]; then
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_RESET=""
fi

BAR="============================================================"

# ---------- Failure banner ----------
# Usage: fail_banner "<issue>" "<details>" "<resolution>"
fail_banner() {
    local issue="$1"
    local details="$2"
    local resolution="$3"

    printf '%s%s%s\n' "$C_RED" "$BAR" "$C_RESET" >&2
    printf '%sSANDBOX DRIFT DETECTED — cannot start Claude Code session%s\n' "$C_RED" "$C_RESET" >&2
    printf '%s%s%s\n' "$C_RED" "$BAR" "$C_RESET" >&2
    printf '\n' >&2
    printf 'Issue: %s\n' "$issue" >&2
    printf '\n' >&2
    printf 'Details:\n' >&2
    # Indent each line of details by two spaces.
    printf '%s\n' "$details" | while IFS= read -r line; do
        printf '  %s\n' "$line" >&2
    done
    printf '\n' >&2
    printf 'To resolve:\n' >&2
    printf '%s\n' "$resolution" | while IFS= read -r line; do
        printf '  %s\n' "$line" >&2
    done
    printf '\n' >&2
    printf '%s%s%s\n' "$C_RED" "$BAR" "$C_RESET" >&2
    exit 1
}

# ---------- 1. Hostname guard (Sandbox only) ----------
HOSTNAME_RAW="$(hostname)"
case "$HOSTNAME_RAW" in
    *jarvis-forge*) ;;
    *)
        fail_banner \
            "not running on Sandbox (hostname: ${HOSTNAME_RAW})" \
            "This script must only run on Sandbox (hostname contains 'jarvis-forge')." \
            "SSH to Sandbox and run from there: ssh jarvissand@100.124.172.14"
        ;;
esac

# ---------- 2. Repo guard (must be inside @@REPO_NAME@@) ----------
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    fail_banner \
        "not inside a git repository" \
        "Current directory: $(pwd)" \
        "cd into @@REPO_PATH@@ and re-run this script"
fi

case "$REPO_ROOT" in
    */@@REPO_NAME@@) ;;
    *)
        fail_banner \
            "wrong repository (expected @@REPO_NAME@@, got $(basename "$REPO_ROOT"))" \
            "Repo root: $REPO_ROOT" \
            "cd into @@REPO_PATH@@ and re-run this script"
        ;;
esac

# ---------- 3. Origin remote guard ----------
if ! git remote get-url origin >/dev/null 2>&1; then
    fail_banner \
        "no origin remote configured" \
        "git remote -v returned no 'origin' entry" \
        "Add an origin remote: git remote add origin <url>"
fi

# ---------- 4. Working tree cleanliness ----------
# Skipped in --pre-commit mode: the commit flow is about to commit the pending changes,
# so uncommitted/untracked files are expected here. All other checks still apply.
if [ "$PRE_COMMIT" = "false" ]; then
    PORCELAIN="$(git status --porcelain)"
    if [ -n "$PORCELAIN" ]; then
        DIRTY_COUNT="$(printf '%s\n' "$PORCELAIN" | wc -l | tr -d ' ')"
        fail_banner \
            "${DIRTY_COUNT} uncommitted or untracked file(s) in working tree" \
            "$PORCELAIN" \
            "Commit or stash the changes, then push:
  git add -A && git commit -m 'msg' && git push
  (or: git stash)"
    fi
fi

# ---------- 5. Fetch origin/@@MAIN_BRANCH@@ ----------
if ! git fetch origin @@MAIN_BRANCH@@ --quiet 2>/dev/null; then
    fail_banner \
        "git fetch failed — cannot reach origin" \
        "origin URL: $(git remote get-url origin 2>/dev/null || echo unknown)" \
        "Check Tailscale/network connectivity to the origin host, then retry"
fi

# ---------- 6. Compare HEAD vs origin/@@MAIN_BRANCH@@ ----------
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/@@MAIN_BRANCH@@)"
SHORT_HEAD="$(git rev-parse --short HEAD)"

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
    if [ "$PRE_COMMIT" = "true" ]; then
        printf '%s✓ Sandbox ready for commit to @@MAIN_BRANCH@@ (branch: @@MAIN_BRANCH@@, synced with origin: %s)%s\n' \
            "$C_GREEN" "$SHORT_HEAD" "$C_RESET"
    else
        printf '%s✓ Sandbox @@REPO_NAME@@ in sync with origin/@@MAIN_BRANCH@@ (commit: %s)%s\n' \
            "$C_GREEN" "$SHORT_HEAD" "$C_RESET"
    fi
    exit 0
fi

# Determine relationship via merge-base.
MERGE_BASE="$(git merge-base HEAD origin/@@MAIN_BRANCH@@)"

if [ "$MERGE_BASE" = "$LOCAL_HEAD" ]; then
    # HEAD is ancestor of origin/@@MAIN_BRANCH@@ → behind.
    BEHIND_COUNT="$(git rev-list --count HEAD..origin/@@MAIN_BRANCH@@)"
    BEHIND_LIST="$(git log HEAD..origin/@@MAIN_BRANCH@@ --oneline)"
    fail_banner \
        "Sandbox is ${BEHIND_COUNT} commits behind origin/@@MAIN_BRANCH@@" \
        "Missing commits:
${BEHIND_LIST}" \
        "Run: git pull origin @@MAIN_BRANCH@@"
elif [ "$MERGE_BASE" = "$REMOTE_HEAD" ]; then
    # origin/@@MAIN_BRANCH@@ is ancestor of HEAD → ahead.
    AHEAD_COUNT="$(git rev-list --count origin/@@MAIN_BRANCH@@..HEAD)"
    AHEAD_LIST="$(git log origin/@@MAIN_BRANCH@@..HEAD --oneline)"
    fail_banner \
        "Sandbox has ${AHEAD_COUNT} local commits not pushed to origin/@@MAIN_BRANCH@@" \
        "Unpushed commits:
${AHEAD_LIST}" \
        "Push via the commit script on Air, or: git push origin @@MAIN_BRANCH@@"
else
    # Diverged — both sides have unique commits.
    BEHIND_COUNT="$(git rev-list --count HEAD..origin/@@MAIN_BRANCH@@)"
    AHEAD_COUNT="$(git rev-list --count origin/@@MAIN_BRANCH@@..HEAD)"
    BEHIND_LIST="$(git log HEAD..origin/@@MAIN_BRANCH@@ --oneline)"
    AHEAD_LIST="$(git log origin/@@MAIN_BRANCH@@..HEAD --oneline)"
    fail_banner \
        "Sandbox has diverged from origin/@@MAIN_BRANCH@@ (${AHEAD_COUNT} ahead, ${BEHIND_COUNT} behind)" \
        "Local-only commits:
${AHEAD_LIST}

Remote-only commits:
${BEHIND_LIST}" \
        "Reconcile manually on Air (do not resolve on Sandbox).
Typical path: inspect both sides, then rebase or reset Sandbox to origin/@@MAIN_BRANCH@@."
fi
