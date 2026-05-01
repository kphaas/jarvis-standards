#!/usr/bin/env bash
# TEMPLATE FILE — @@REPO_NAME@@ commit script
# Source of truth: jarvis-standards/scripts/_templates/commit_core.template.sh
# Propagated to:   @@REPO_PATH@@/scripts/@@COMMIT_SCRIPT_NAME@@
#
# Unified commit script for JARVIS repos. Implements ADR-0005:
#   - Q1 coordination model — humans merge anywhere, agents always branch
#   - Q2 provenance — uniform git author + X-Machine and AI-* trailers
#   - Q3 branch namespace — feature/* humans, claude-code/* agents
#
# Trait switches (set by propagate.config):
#   @@HAS_BRANCH_SAFETY@@        — true: B-trait, enforce DEBT-027 + agent-must-branch
#   @@HAS_FANOUT@@               — true: F-trait, SSH-fan-out to @@FANOUT_NODES@@
#   @@HAS_UI_BUILD@@             — true: run npm build in ui/ before commit
#   @@HAS_SMOKE_CHECK@@          — true: run @@SMOKE_CHECK_CMD@@ as pre-commit health check
#   @@HAS_AUTO_BRANCH@@          — true: on main from non-Air, auto-branch to feature/<date>-<slug>
#   @@FANOUT_NODES@@             — space-separated list (e.g. "brain gateway endpoint")
#   @@SMOKE_CHECK_CMD@@          — path to smoke check script, relative to repo root
#   @@MERGE_HELPER_SCRIPT_NAME@@ — name of merge helper script (printed in instructions after auto-branch)
#   @@COMMIT_SCRIPT_NAME@@       — generated script name for self-reference
#
# Usage (human):
#   bash @@COMMIT_SCRIPT_NAME@@ "commit message"
#
# Usage (agent — Claude Code, forge):
#   JARVIS_AGENT=claude-code JARVIS_MODEL=claude-opus-4-7 \
#       bash @@COMMIT_SCRIPT_NAME@@ "commit message"
#
# Skip flags (F-trait only):
#   JARVIS_SKIP_BRAIN=1   bash @@COMMIT_SCRIPT_NAME@@ "msg"
#   JARVIS_SKIP_GATEWAY=1 bash @@COMMIT_SCRIPT_NAME@@ "msg"
#   etc.

set -uo pipefail

# ---------- Constants ----------
REPO_PATH="@@REPO_PATH@@"
REPO_NAME="@@REPO_NAME@@"
MAIN_BRANCH="@@MAIN_BRANCH@@"
COMMIT_SCRIPT_NAME="@@COMMIT_SCRIPT_NAME@@"
HAS_FANOUT="@@HAS_FANOUT@@"
HAS_BRANCH_SAFETY="@@HAS_BRANCH_SAFETY@@"
HAS_UI_BUILD="@@HAS_UI_BUILD@@"
HAS_SMOKE_CHECK="@@HAS_SMOKE_CHECK@@"
HAS_AUTO_BRANCH="@@HAS_AUTO_BRANCH@@"
FANOUT_NODES="@@FANOUT_NODES@@"
SMOKE_CHECK_CMD="@@SMOKE_CHECK_CMD@@"
MERGE_HELPER_SCRIPT_NAME="@@MERGE_HELPER_SCRIPT_NAME@@"

# ANSI colors
C_RED=$'\033[0;31m'
C_YELLOW=$'\033[1;33m'
C_GREEN=$'\033[0;32m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

START_TIME="$(date +%s)"

# ---------- Args ----------
COMMIT_MSG="${1:-}"
if [ -z "$COMMIT_MSG" ]; then
    echo "${C_RED}USAGE: $COMMIT_SCRIPT_NAME \"commit message\"${C_RESET}" >&2
    exit 1
fi

# ---------- Helpers ----------
step()  { echo "${C_BOLD}Step $1:${C_RESET} $2"; }
ok()    { echo "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo "  ${C_YELLOW}⚠${C_RESET} $1" >&2; }
fail()  { echo "  ${C_RED}✗${C_RESET} $1" >&2; }
die()   { fail "$1"; echo; echo "${C_RED}${C_BOLD}ABORTED${C_RESET}"; exit 1; }

# Sanitize commit message into a branch-name-safe slug.
# Lowercase, alphanumeric + hyphens only, max ~40 chars.
make_slug() {
    local msg="$1"
    local slug
    slug="$(echo "$msg" | head -c 60 | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | head -c 40)"
    slug="${slug%-}"
    if [ -z "$slug" ]; then
        slug="commit"
    fi
    echo "$slug"
}

# ---------- Detect machine ----------
detect_machine() {
    local hn
    hn="$(hostname -s 2>/dev/null || hostname)"
    case "$hn" in
        *air*|*Air*)              echo "air" ;;
        *brain*|*Brain*)          echo "brain" ;;
        *gateway*|*Gateway*)      echo "gateway" ;;
        *endpoint*|*Endpoint*)    echo "endpoint" ;;
        *sandbox*|*Sandbox*)      echo "sandbox" ;;
        *forge*|*Forge*)          echo "sandbox" ;;
        *)                        echo "unknown" ;;
    esac
}
MACHINE="$(detect_machine)"

# ---------- Detect agent context ----------
JARVIS_AGENT="${JARVIS_AGENT:-}"
JARVIS_MODEL="${JARVIS_MODEL:-}"
IS_AGENT=false
if [ -n "$JARVIS_AGENT" ]; then
    IS_AGENT=true
fi

NEED_AUTO_BRANCH=false

# ---------- Banner ----------
echo "${C_CYAN}${C_BOLD}$COMMIT_SCRIPT_NAME${C_RESET}  ($REPO_NAME on $MACHINE)"
echo "  Subject:    $COMMIT_MSG"
if [ "$IS_AGENT" = "true" ]; then
    echo "  Agent:      $JARVIS_AGENT${JARVIS_MODEL:+ ($JARVIS_MODEL)}"
fi
echo

cd "$REPO_PATH" || die "Cannot cd to $REPO_PATH"

# ---------- Step 1: Pre-flight ----------
step 1 "Pre-flight"

for envfile in "$HOME/jarvis/infra/env/.node_addresses" "$HOME/jarvis/.secrets" "$HOME/.secrets"; do
    if [ -f "$envfile" ]; then
        # shellcheck disable=SC1090
        . "$envfile" 2>/dev/null || warn "failed to source $envfile"
    fi
done

if [ "$MACHINE" = "unknown" ]; then
    die "Cannot determine machine identity from hostname: $(hostname -s)"
fi
ok "Machine: $MACHINE"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$HAS_BRANCH_SAFETY" = "true" ]; then
    if [ "$IS_AGENT" = "true" ] && [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ]; then
        die "Agent ($JARVIS_AGENT) cannot commit directly to $MAIN_BRANCH branch. Per ADR-0005 §4.3: use claude-code/<purpose>/<topic> branch."
    fi
    if [ "$IS_AGENT" = "false" ] && [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ] && [ "$MACHINE" != "air" ]; then
        if [ "$HAS_AUTO_BRANCH" = "true" ]; then
            NEED_AUTO_BRANCH=true
            ok "Branch-safety: on $MAIN_BRANCH from $MACHINE — will auto-branch in Step 5"
        else
            warn "Committing to $MAIN_BRANCH from $MACHINE (Q1 allows, but consider feature/* branch)"
            ok "Branch-safety: $CURRENT_BRANCH"
        fi
    else
        ok "Branch-safety: $CURRENT_BRANCH"
    fi
fi

if [ -x "$REPO_PATH/scripts/check_sync.sh" ]; then
    if "$REPO_PATH/scripts/check_sync.sh" --pre-commit >/dev/null 2>&1; then
        ok "Drift check: clean"
    else
        warn "Drift check reported issues — running with full output"
        "$REPO_PATH/scripts/check_sync.sh" --pre-commit || die "Drift check failed"
    fi
fi

echo

# ---------- Step 2: Smoke health check (optional) ----------
if [ "$HAS_SMOKE_CHECK" = "true" ] && [ -n "$SMOKE_CHECK_CMD" ]; then
    step 2 "Smoke health check"
    SMOKE_PATH="$REPO_PATH/$SMOKE_CHECK_CMD"
    if [ ! -x "$SMOKE_PATH" ]; then
        warn "Smoke check command not executable: $SMOKE_PATH — skipping"
    else
        if "$SMOKE_PATH" >/dev/null 2>&1; then
            ok "Smoke: passed"
        else
            echo "  ${C_RED}Smoke check failed — full output:${C_RESET}"
            "$SMOKE_PATH" || die "Smoke health check failed"
        fi
    fi
    echo
fi

# ---------- Step 3: Lint ----------
step 3 "Lint"

if [ -f "$REPO_PATH/scripts/_lib/ruff_detect.sh" ]; then
    # shellcheck disable=SC1091
    . "$REPO_PATH/scripts/_lib/ruff_detect.sh"
    if ! detect_ruff; then
        warn "ruff not found in venv or PATH — skipping lint"
    else
        if "$RUFF" check . >/dev/null 2>&1; then
            ok "ruff check: clean"
        else
            "$RUFF" check . || die "ruff check failed"
        fi
        if "$RUFF" format --check . >/dev/null 2>&1; then
            ok "ruff format: clean"
        else
            warn "ruff format would make changes:"
            "$RUFF" format --check . || die "ruff format check failed"
        fi
    fi
else
    warn "scripts/_lib/ruff_detect.sh missing — skipping lint (propagate it from jarvis-standards)"
fi

echo

# ---------- Step 4: UI build (optional) ----------
if [ "$HAS_UI_BUILD" = "true" ] && [ -d "$REPO_PATH/ui" ]; then
    step 4 "Build UI"
    cd "$REPO_PATH/ui" || die "Cannot cd to ui/"
    if npm run build >/dev/null 2>&1; then
        ok "UI build: succeeded"
    else
        echo "  ${C_RED}UI build failed — full output:${C_RESET}"
        npm run build || die "UI build failed"
    fi
    cd "$REPO_PATH" || die "Cannot return to repo path"
    echo
fi

# ---------- Step 5: Auto-branch (optional) ----------
AUTO_BRANCHED=false
AUTO_BRANCH_NAME=""
if [ "$NEED_AUTO_BRANCH" = "true" ]; then
    step 5 "Auto-branch"
    DATE_STR="$(date +%Y-%m-%d)"
    SLUG="$(make_slug "$COMMIT_MSG")"
    AUTO_BRANCH_NAME="feature/${DATE_STR}-${SLUG}"

    if git show-ref --verify --quiet "refs/heads/$AUTO_BRANCH_NAME"; then
        suffix_n=2
        while git show-ref --verify --quiet "refs/heads/${AUTO_BRANCH_NAME}-${suffix_n}"; do
            suffix_n=$((suffix_n + 1))
        done
        AUTO_BRANCH_NAME="${AUTO_BRANCH_NAME}-${suffix_n}"
    fi

    if git checkout -b "$AUTO_BRANCH_NAME"; then
        ok "Created branch: $AUTO_BRANCH_NAME"
        CURRENT_BRANCH="$AUTO_BRANCH_NAME"
        AUTO_BRANCHED=true
    else
        die "Failed to create branch $AUTO_BRANCH_NAME"
    fi
    echo
fi

# ---------- Step 6: Stage + commit ----------
step 6 "Stage + commit"

UNTRACKED="$(git status --porcelain | awk '/^\?\?/ { sub(/^\?\? */, ""); print }')"
if [ -n "$UNTRACKED" ]; then
    warn "Untracked files that will be staged:"
    echo "$UNTRACKED" | sed 's/^/    /'
    if [ -t 0 ]; then
        printf "  Continue? [y/N] "
        read -r reply
        case "$reply" in
            y|Y) ok "Proceeding" ;;
            *)   die "Aborted by user" ;;
        esac
    else
        warn "Non-TTY environment — proceeding without prompt (DEBT-043 known limitation)"
    fi
fi

git add -A

if git diff --cached --quiet; then
    warn "Nothing to commit"
    if [ "$AUTO_BRANCHED" = "true" ]; then
        git checkout "$MAIN_BRANCH"
        git branch -d "$AUTO_BRANCH_NAME" 2>/dev/null || true
        warn "Returned to $MAIN_BRANCH; deleted empty auto-branch"
    fi
    exit 0
fi

TRAILER_BLOCK="X-Machine: $MACHINE"
if [ "$IS_AGENT" = "true" ]; then
    TRAILER_BLOCK="$TRAILER_BLOCK
AI-Agent: $JARVIS_AGENT"
    if [ -n "$JARVIS_MODEL" ]; then
        TRAILER_BLOCK="$TRAILER_BLOCK
AI-Model: $JARVIS_MODEL"
    fi
fi

COMMIT_FULL_MSG="$(cat <<EOF
$COMMIT_MSG

$TRAILER_BLOCK
EOF
)"

git commit -m "$COMMIT_FULL_MSG" >/dev/null || die "git commit failed"
COMMIT_HASH="$(git rev-parse --short HEAD)"
ok "Committed: $COMMIT_HASH"

PARSED="$(git log -1 --format=%B | git interpret-trailers --parse 2>/dev/null || true)"
if echo "$PARSED" | grep -q "^X-Machine: $MACHINE"; then
    ok "Trailer parsed: X-Machine: $MACHINE"
    if [ "$IS_AGENT" = "true" ]; then
        if echo "$PARSED" | grep -q "^AI-Agent: $JARVIS_AGENT"; then
            ok "Trailer parsed: AI-Agent: $JARVIS_AGENT"
        else
            warn "AI-Agent trailer not parsed — check commit body manually"
        fi
    fi
else
    warn "X-Machine trailer parsing failed — manual check: git log -1 --format=%B | git interpret-trailers --parse"
fi

echo

# ---------- Step 7: Push ----------
step 7 "Push"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [ "$HAS_BRANCH_SAFETY" = "true" ] && [ "$IS_AGENT" = "true" ] && [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ]; then
    die "Internal: agent on $MAIN_BRANCH at push time — Step 1 should have caught this"
fi

git pull --rebase origin "$CURRENT_BRANCH" 2>/dev/null || true

if git push -u origin "$CURRENT_BRANCH" 2>&1 | tail -5; then
    ok "Pushed: $CURRENT_BRANCH"
else
    die "Push failed"
fi

if [ "$AUTO_BRANCHED" = "true" ]; then
    echo
    echo "${C_CYAN}  Auto-branched from $MAIN_BRANCH on $MACHINE.${C_RESET}"
    if [ -n "$MERGE_HELPER_SCRIPT_NAME" ]; then
        echo "${C_CYAN}  To merge from Air:${C_RESET} bash $REPO_PATH/scripts/$MERGE_HELPER_SCRIPT_NAME $CURRENT_BRANCH"
    fi
    echo "${C_CYAN}  Or open PR:${C_RESET} https://github.com/kphaas/$REPO_NAME/pull/new/$CURRENT_BRANCH"
elif [ "$IS_AGENT" = "true" ] && [ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]; then
    echo "  Open PR: https://github.com/kphaas/$REPO_NAME/pull/new/$CURRENT_BRANCH"
fi

if [ "$AUTO_BRANCHED" = "true" ]; then
    git checkout "$MAIN_BRANCH" >/dev/null 2>&1 || warn "Could not return to $MAIN_BRANCH"
    ok "Returned to $MAIN_BRANCH (auto-branch flow)"
fi

echo

# ---------- Step 8: Fan-out (F-trait only) ----------
if [ "$HAS_FANOUT" = "true" ] && [ -n "$FANOUT_NODES" ]; then
    step 8 "Fan-out to nodes ($FANOUT_NODES)"

    if [ "$AUTO_BRANCHED" = "true" ]; then
        warn "Skipping fan-out — auto-branched commit, not on $MAIN_BRANCH"
    else
        FANOUT_SUCCEEDED=""
        for node in $FANOUT_NODES; do
            if [ "$node" = "$MACHINE" ]; then
                warn "Skipping $node (current machine)"
                continue
            fi

            skip_var="JARVIS_SKIP_$(echo "$node" | tr '[:lower:]' '[:upper:]')"
            eval "skip_val=\"\${${skip_var}:-}\""
            if [ -n "$skip_val" ]; then
                warn "Skipping $node ($skip_var=$skip_val)"
                continue
            fi

            if ssh -o ServerAliveInterval=30 -o ConnectTimeout=10 \
                   -o StrictHostKeyChecking=no \
                   "$node" "cd $REPO_PATH && git pull origin $CURRENT_BRANCH" \
                   </dev/null 2>&1 | tail -3; then
                ok "$node: pulled"
                FANOUT_SUCCEEDED="$FANOUT_SUCCEEDED $node"
            else
                fail "$node: pull failed"
                echo "  ${C_RED}Fan-out halted. Already-pulled nodes:${C_RESET}$FANOUT_SUCCEEDED"
                echo "  ${C_RED}Manual recovery: pull this branch on remaining nodes, or rollback via git revert${C_RESET}"
                die "Fan-out halt-on-fail at $node"
            fi
        done

        ok "Fan-out complete:$FANOUT_SUCCEEDED"
    fi
    echo
fi

# ---------- Summary ----------
END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

echo "${C_CYAN}${C_BOLD}$COMMIT_SCRIPT_NAME — success${C_RESET}"
echo "  Hash:       $COMMIT_HASH"
echo "  Branch:     $CURRENT_BRANCH"
echo "  Machine:    $MACHINE"
if [ "$IS_AGENT" = "true" ]; then
    echo "  Agent:      $JARVIS_AGENT${JARVIS_MODEL:+ / $JARVIS_MODEL}"
fi
if [ "$AUTO_BRANCHED" = "true" ]; then
    echo "  Auto-branch: $AUTO_BRANCH_NAME (returned to $MAIN_BRANCH locally)"
fi
if [ "$HAS_FANOUT" = "true" ] && [ -n "$FANOUT_NODES" ] && [ "$AUTO_BRANCHED" != "true" ]; then
    echo "  Fan-out:    $FANOUT_NODES"
fi
echo "  Duration:   ${DURATION}s"

exit 0
