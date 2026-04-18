#!/usr/bin/env bash
# propagate_scripts.sh
#
# Propagation engine for jarvis-standards templates.
# Reads propagate.config, applies @@VAR@@ substitutions, writes generated files
# to each consumer repo with a GENERATED header.
#
# Usage:
#   bash propagate_scripts.sh [--dry-run] [--initial] [--help]
#
# Safety:
#   - Refuses to run if jarvis-standards has uncommitted changes
#   - Default mode: overwrites only files with the GENERATED header
#   - --initial: one-time overwrite of hand-written files (for first rollout)
#   - --dry-run: show plan, write nothing
#
# Exits non-zero on fatal errors. Missing consumer repos are warnings, not errors.

set -euo pipefail

# ---------- Constants ----------
STANDARDS_ROOT="$HOME/jarvis-standards"
TEMPLATES_DIR="$STANDARDS_ROOT/scripts/_templates"
CONFIG_FILE="$STANDARDS_ROOT/scripts/propagate.config"

# ANSI colors
C_RED=$'\033[0;31m'
C_YELLOW=$'\033[1;33m'
C_GREEN=$'\033[0;32m'
C_CYAN=$'\033[0;36m'
C_RESET=$'\033[0m'

# ---------- Flags ----------
DRY_RUN=false
INITIAL=false

print_help() {
    cat <<EOF
propagate_scripts.sh — jarvis-standards template propagation engine

Usage:
  propagate_scripts.sh                Run propagation (safe mode)
  propagate_scripts.sh --dry-run      Show plan, write nothing
  propagate_scripts.sh --initial      One-time overwrite of hand-written files
  propagate_scripts.sh --help         This message

Safe mode (default): only overwrites files with a GENERATED header.
Initial mode: overwrites any existing file — use once per consumer repo on first rollout.

Config: $CONFIG_FILE
Templates: $TEMPLATES_DIR
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --initial) INITIAL=true ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "${C_RED}Unknown flag: $arg${C_RESET}" >&2; print_help; exit 1 ;;
    esac
done

# ---------- Pre-flight ----------
if [ ! -d "$STANDARDS_ROOT" ]; then
    echo "${C_RED}FATAL: jarvis-standards not found at $STANDARDS_ROOT${C_RESET}" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "${C_RED}FATAL: config missing: $CONFIG_FILE${C_RESET}" >&2
    exit 1
fi

cd "$STANDARDS_ROOT"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "${C_RED}FATAL: jarvis-standards has uncommitted changes.${C_RESET}" >&2
    echo "Commit or stash template edits before propagating (prevents untested templates from shipping)." >&2
    exit 1
fi

SOURCE_SHA_SHORT="$(git rev-parse --short HEAD)"
GEN_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "${C_CYAN}propagate_scripts.sh${C_RESET}"
echo "  Source commit: $SOURCE_SHA_SHORT"
echo "  Timestamp:     $GEN_TIMESTAMP"
if [ "$DRY_RUN" = "true" ]; then
    echo "  Mode:          ${C_YELLOW}DRY-RUN${C_RESET} (no files will be written)"
elif [ "$INITIAL" = "true" ]; then
    echo "  Mode:          ${C_YELLOW}INITIAL${C_RESET} (will overwrite hand-written files)"
else
    echo "  Mode:          SAFE (only overwrites files with GENERATED header)"
fi
echo

# ---------- Counters ----------
WROTE=0
SKIPPED_NO_REPO=0
SKIPPED_HANDWRITTEN=0
DRY_RUN_PLANNED=0
ERRORS=0

# ---------- Core function ----------
propagate_one() {
    local template_name="$1"
    local target_repo="$2"
    local target_subpath="$3"
    local repo_name="$4"
    local repo_path="$5"
    local main_branch="$6"

    local template_file="$TEMPLATES_DIR/$template_name"
    local target_root="$HOME/$target_repo"
    local target_file="$target_root/$target_subpath"

    if [ ! -f "$template_file" ]; then
        echo "${C_RED}ERROR: template not found: $template_file${C_RESET}" >&2
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    if [ ! -d "$target_root" ]; then
        echo "${C_YELLOW}SKIP${C_RESET}   $target_repo (repo not present at $target_root)"
        SKIPPED_NO_REPO=$((SKIPPED_NO_REPO + 1))
        return 0
    fi

    # Safety check: if target exists without GENERATED header, require --initial
    if [ -f "$target_file" ]; then
        if ! head -10 "$target_file" | grep -q "^# GENERATED FROM jarvis-standards"; then
            if [ "$INITIAL" != "true" ]; then
                echo "${C_YELLOW}SKIP${C_RESET}   $target_repo/$target_subpath (hand-written; use --initial to overwrite)"
                SKIPPED_HANDWRITTEN=$((SKIPPED_HANDWRITTEN + 1))
                return 0
            fi
        fi
    fi

    # Build generated header
    local gen_header
    gen_header=$(cat <<EOF
#!/usr/bin/env bash
# GENERATED FROM jarvis-standards/scripts/_templates/$template_name
# Source commit: $SOURCE_SHA_SHORT
# Generated:     $GEN_TIMESTAMP
# DO NOT EDIT DIRECTLY — edit the template in jarvis-standards and re-propagate.
EOF
)

    # Process template body:
    #   1. Strip shebang line (we provide our own in header)
    #   2. Strip # TEMPLATE FILE multi-line header block (from marker to first blank line)
    #   3. Apply placeholder substitutions
    local body
    body=$(awk '
        NR == 1 && /^#!/ { next }
        /^# TEMPLATE FILE / { in_tmpl_hdr = 1; next }
        in_tmpl_hdr && /^$/ { in_tmpl_hdr = 0; next }
        in_tmpl_hdr { next }
        { print }
    ' "$template_file" | sed \
        -e "s|@@REPO_NAME@@|$repo_name|g" \
        -e "s|@@REPO_PATH@@|$repo_path|g" \
        -e "s|@@MAIN_BRANCH@@|$main_branch|g")

    local full_content="$gen_header
$body"

    if [ "$DRY_RUN" = "true" ]; then
        echo "${C_CYAN}PLAN${C_RESET}   $target_repo/$target_subpath  (from $template_name)"
        DRY_RUN_PLANNED=$((DRY_RUN_PLANNED + 1))
        return 0
    fi

    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$full_content" > "$target_file"
    chmod +x "$target_file"
    echo "${C_GREEN}WROTE${C_RESET}  $target_repo/$target_subpath"
    WROTE=$((WROTE + 1))
}

# ---------- Main loop ----------
while IFS='|' read -r template target_repo target_subpath repo_name repo_path main_branch; do
    # Skip comments
    case "$template" in
        \#*) continue ;;
        "") continue ;;
    esac

    # Trim whitespace (simple — matches bash 3.2)
    template="${template## }"; template="${template%% }"
    target_repo="${target_repo## }"; target_repo="${target_repo%% }"
    target_subpath="${target_subpath## }"; target_subpath="${target_subpath%% }"
    repo_name="${repo_name## }"; repo_name="${repo_name%% }"
    repo_path="${repo_path## }"; repo_path="${repo_path%% }"
    main_branch="${main_branch## }"; main_branch="${main_branch%% }"

    propagate_one "$template" "$target_repo" "$target_subpath" "$repo_name" "$repo_path" "$main_branch" || true
done < "$CONFIG_FILE"

# ---------- Summary ----------
echo
echo "${C_CYAN}Summary${C_RESET}"
if [ "$DRY_RUN" = "true" ]; then
    echo "  Planned:            $DRY_RUN_PLANNED"
else
    echo "  Written:            $WROTE"
fi
echo "  Skipped (no repo):  $SKIPPED_NO_REPO"
echo "  Skipped (hand-written, need --initial): $SKIPPED_HANDWRITTEN"
echo "  Errors:             $ERRORS"

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi
exit 0
