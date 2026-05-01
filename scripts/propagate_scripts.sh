#!/usr/bin/env bash
# propagate_scripts.sh
#
# Propagation engine for jarvis-standards templates.
# Reads propagate.config, applies @@VAR@@ substitutions, writes generated files
# to each consumer repo with a GENERATED header.
#
# Usage:
#   bash propagate_scripts.sh [--dry-run] [--initial] [--check] [--help]
#
# Safety:
#   - Refuses to run if jarvis-standards has uncommitted changes
#   - Default mode: overwrites only files with the GENERATED header
#   - --initial: one-time overwrite of hand-written files (for first rollout)
#   - --dry-run: show plan, write nothing
#   - --check: report drift (target file out of sync with template), no writes
#
# Schema (propagate.config):
#   template|target_repo|target_subpath|REPO_NAME|REPO_PATH|MAIN_BRANCH[|KEY=VALUE...]
#
#   Fields 1-6 are required. Fields 7+ are optional KEY=VALUE pairs that
#   become @@KEY@@ substitution variables in the template.
#
# Backward compatibility: rows without KEY=VALUE extras work exactly as before.
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
CHECK=false

print_help() {
    cat <<EOF
propagate_scripts.sh — jarvis-standards template propagation engine

Usage:
  propagate_scripts.sh                Run propagation (safe mode)
  propagate_scripts.sh --dry-run      Show plan, write nothing
  propagate_scripts.sh --initial      One-time overwrite of hand-written files
  propagate_scripts.sh --check        Report drift, no writes (CI / quarterly audit)
  propagate_scripts.sh --help         This message

Safe mode (default): only overwrites files with a GENERATED header.
Initial mode: overwrites any existing file — use once per consumer repo on first rollout.
Check mode: reports drift between expected and actual generated files.

Schema (propagate.config):
  template|target_repo|target_subpath|REPO_NAME|REPO_PATH|MAIN_BRANCH[|KEY=VALUE...]

Fields 1-6 are required. Fields 7+ are optional KEY=VALUE pairs that
become @@KEY@@ substitution variables in the template.

Config: $CONFIG_FILE
Templates: $TEMPLATES_DIR
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --initial) INITIAL=true ;;
        --check) CHECK=true ;;
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
elif [ "$CHECK" = "true" ]; then
    echo "  Mode:          ${C_YELLOW}CHECK${C_RESET} (report drift, no writes)"
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
DRIFT_DETECTED=0
ERRORS=0

# ---------- Helpers ----------

# Trim leading and trailing whitespace from a string.
# Bash 3.2 compatible.
trim() {
    local s="$1"
    # Leading whitespace
    s="${s#"${s%%[![:space:]]*}"}"
    # Trailing whitespace
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------- Core function ----------
propagate_one() {
    local template_name="$1"
    local target_repo="$2"
    local target_subpath="$3"
    local repo_name="$4"
    local repo_path="$5"
    local main_branch="$6"
    shift 6
    # Remaining args are KEY=VALUE extras
    local extras=("$@")

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
    if [ -f "$target_file" ] && [ "$CHECK" != "true" ]; then
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

    # Build sed expressions for substitution.
    # Required vars first, then extras.
    local sed_args=()
    sed_args+=(-e "s|@@REPO_NAME@@|$repo_name|g")
    sed_args+=(-e "s|@@REPO_PATH@@|$repo_path|g")
    sed_args+=(-e "s|@@MAIN_BRANCH@@|$main_branch|g")

    local kv key val
    for kv in "${extras[@]+"${extras[@]}"}"; do
        kv="$(trim "$kv")"
        if [ -z "$kv" ]; then
            continue
        fi
        case "$kv" in
            *=*) ;;
            *)
                echo "${C_YELLOW}WARN${C_RESET}   $target_repo: ignoring malformed extra (no '='): '$kv'" >&2
                continue
                ;;
        esac
        # Split on first '='
        key="${kv%%=*}"
        val="${kv#*=}"
        key="$(trim "$key")"
        # Don't trim val — it may legitimately contain trailing whitespace if quoted
        sed_args+=(-e "s|@@${key}@@|${val}|g")
    done

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
    ' "$template_file" | sed "${sed_args[@]}")

    local full_content="$gen_header
$body"

    if [ "$DRY_RUN" = "true" ]; then
        echo "${C_CYAN}PLAN${C_RESET}   $target_repo/$target_subpath  (from $template_name)"
        DRY_RUN_PLANNED=$((DRY_RUN_PLANNED + 1))
        return 0
    fi

    if [ "$CHECK" = "true" ]; then
        if [ ! -f "$target_file" ]; then
            echo "${C_YELLOW}DRIFT${C_RESET}  $target_repo/$target_subpath (target missing)"
            DRIFT_DETECTED=$((DRIFT_DETECTED + 1))
            return 0
        fi
        # Compare expected content (computed) vs actual file
        # Note: timestamps and source SHA in header will differ on every run,
        # so compare body only by stripping the GENERATED header from both.
        local actual_body
        actual_body="$(awk 'NR > 5' "$target_file" || true)"
        local expected_body
        expected_body="$(printf '%s\n' "$body")"
        if [ "$actual_body" = "$expected_body" ]; then
            echo "${C_GREEN}OK${C_RESET}     $target_repo/$target_subpath"
        else
            echo "${C_YELLOW}DRIFT${C_RESET}  $target_repo/$target_subpath (body differs from template)"
            DRIFT_DETECTED=$((DRIFT_DETECTED + 1))
        fi
        return 0
    fi

    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$full_content" > "$target_file"
    chmod +x "$target_file"
    echo "${C_GREEN}WROTE${C_RESET}  $target_repo/$target_subpath"
    WROTE=$((WROTE + 1))
}

# ---------- Main loop ----------
# Read whole line; split on '|' into positional array; validate min 6 fields;
# pass first 6 as named args + rest as extras.
while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blanks
    case "$line" in
        \#*|"") continue ;;
    esac

    # Split on '|' into array. Bash 3.2 compatible via read -a + IFS.
    OLD_IFS="$IFS"
    IFS='|'
    read -r -a parts <<< "$line"
    IFS="$OLD_IFS"

    if [ "${#parts[@]}" -lt 6 ]; then
        echo "${C_RED}ERROR: row needs at least 6 fields, got ${#parts[@]}: $line${C_RESET}" >&2
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Trim whitespace from required fields (matches existing behavior)
    template="$(trim "${parts[0]}")"
    target_repo="$(trim "${parts[1]}")"
    target_subpath="$(trim "${parts[2]}")"
    repo_name="$(trim "${parts[3]}")"
    repo_path="$(trim "${parts[4]}")"
    main_branch="$(trim "${parts[5]}")"

    # Collect extras (parts[6] and beyond) — trimmed inside propagate_one
    extras=()
    if [ "${#parts[@]}" -gt 6 ]; then
        local_i=6
        while [ "$local_i" -lt "${#parts[@]}" ]; do
            extras+=("${parts[$local_i]}")
            local_i=$((local_i + 1))
        done
    fi

    propagate_one "$template" "$target_repo" "$target_subpath" "$repo_name" "$repo_path" "$main_branch" "${extras[@]+"${extras[@]}"}" || true
done < "$CONFIG_FILE"

# ---------- Summary ----------
echo
echo "${C_CYAN}Summary${C_RESET}"
if [ "$DRY_RUN" = "true" ]; then
    echo "  Planned writes:    $DRY_RUN_PLANNED"
elif [ "$CHECK" = "true" ]; then
    echo "  Drift detected:    $DRIFT_DETECTED"
else
    echo "  Wrote:             $WROTE"
fi
echo "  Skipped (no repo): $SKIPPED_NO_REPO"
echo "  Skipped (handwrt): $SKIPPED_HANDWRITTEN"
echo "  Errors:            $ERRORS"

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi
if [ "$CHECK" = "true" ] && [ "$DRIFT_DETECTED" -gt 0 ]; then
    exit 2
fi
exit 0
