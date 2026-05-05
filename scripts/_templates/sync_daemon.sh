#!/usr/bin/env bash
# JARVIS sync daemon — TD-X27
#
# Polling sync daemon: long-lived loop that walks every JARVIS clone under
# $HOME, fetches remote refs read-only, and fast-forwards local main when it
# is strictly behind origin/main with a clean working tree and no local
# unpushed commits. Pull-based GitOps per ADR-0007.
#
# Operational properties:
#   - Fast: target <1s per cycle when caches are warm; cycles are bounded by
#     the configured interval (default 300s) regardless of repo count
#   - Offline-safe: a fetch failure logs the failure and moves on; never
#     exits non-zero on transient errors
#   - Deterministic: only fast-forwards. Never rebases. Never resolves
#     conflicts. Never touches a branch other than main.
#   - Read-only of the working tree: skips any repo with a dirty tree or
#     local commits ahead of origin
#
# Identity (env-driven, all optional):
#   SYNC_DAEMON_INTERVAL    seconds between cycles (default 300)
#   SYNC_DAEMON_REPO_GLOB   glob for repo discovery (default $HOME/jarvis-*)
#   SYNC_DAEMON_LOG         log file path (default $HOME/.jarvis/sync_daemon.log)
#   SYNC_DAEMON_FAIL_WARN   consecutive failures before WARN (default 3)
#
# Signals:
#   SIGTERM / SIGINT — set the shutdown flag; the daemon finishes the current
#   cycle (or wakes from sleep) and exits 0. Never exits non-zero on
#   transient errors; only on graceful shutdown.
#
# Source of truth: jarvis-standards/scripts/_templates/sync_daemon.sh.
# Phase 2 installs this on Sandbox + Air via install_sync_daemon.sh.

set -u

# --- defaults ----------------------------------------------------------------

INTERVAL="${SYNC_DAEMON_INTERVAL:-300}"
REPO_GLOB="${SYNC_DAEMON_REPO_GLOB:-${HOME}/jarvis-*}"
LOG="${SYNC_DAEMON_LOG:-${HOME}/.jarvis/sync_daemon.log}"
FAIL_WARN="${SYNC_DAEMON_FAIL_WARN:-3}"

mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true

# --- shutdown handling -------------------------------------------------------

shutdown=0
on_signal() {
  shutdown=1
}
trap on_signal TERM INT

# --- logging -----------------------------------------------------------------

# log <level> <repo> <action> [<detail>]
log() {
  local level="$1" repo="$2" action="$3" detail="${4:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "${detail}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "${ts}" "${level}" "${repo}" "${action}" "${detail}" >> "${LOG}" 2>/dev/null || true
  else
    printf '%s\t%s\t%s\t%s\n' "${ts}" "${level}" "${repo}" "${action}" >> "${LOG}" 2>/dev/null || true
  fi
}

# --- per-repo failure tracking ----------------------------------------------
# Plain associative array via parallel arrays so this works on bash 3.2 too.
fail_keys=()
fail_vals=()

fail_get() {
  local key="$1"
  local i
  for i in "${!fail_keys[@]}"; do
    if [ "${fail_keys[${i}]}" = "${key}" ]; then
      printf '%s' "${fail_vals[${i}]}"
      return 0
    fi
  done
  printf '0'
}

fail_set() {
  local key="$1" val="$2"
  local i
  for i in "${!fail_keys[@]}"; do
    if [ "${fail_keys[${i}]}" = "${key}" ]; then
      fail_vals[${i}]="${val}"
      return 0
    fi
  done
  fail_keys+=("${key}")
  fail_vals+=("${val}")
}

# --- core: sync one repo -----------------------------------------------------

sync_repo() {
  local repo="$1"
  local name
  name="$(basename "${repo}")"

  # Skip if not a git repo.
  if [ ! -d "${repo}/.git" ]; then
    return 0
  fi

  # Determine current branch (or detached).
  local current_branch
  current_branch="$(git -C "${repo}" symbolic-ref --short HEAD 2>/dev/null || echo '')"

  # Read-only fetch of remote refs. On failure, count and continue.
  if ! git -C "${repo}" fetch --quiet --prune origin 2>/dev/null; then
    local prev
    prev="$(fail_get "${name}")"
    local nxt=$(( prev + 1 ))
    fail_set "${name}" "${nxt}"
    if [ "${nxt}" -ge "${FAIL_WARN}" ]; then
      log WARN "${name}" fetch_failed "consecutive=${nxt}"
    else
      log INFO "${name}" fetch_failed "consecutive=${nxt}"
    fi
    return 0
  fi
  fail_set "${name}" 0

  # If we're not on main, fetch origin/main into the local main ref but
  # never touch the working tree. This keeps a non-main branch's local main
  # current for later merge-base / age checks without disturbing the
  # checkout. Failure here is non-fatal; it just means the local main won't
  # advance this cycle.
  if [ -n "${current_branch}" ] && [ "${current_branch}" != "main" ]; then
    if git -C "${repo}" fetch --quiet origin main:main 2>/dev/null; then
      log INFO "${name}" refs_only_fetch "branch=${current_branch}"
    else
      log INFO "${name}" refs_only_fetch_skipped "branch=${current_branch} (likely diverged or not fast-forwardable)"
    fi
    return 0
  fi

  # On main: fast-forward only when (a) clean tree and (b) ahead==0 and (c) behind>0.
  # Detached HEAD case (current_branch empty): skip fast-forward.
  if [ -z "${current_branch}" ]; then
    log INFO "${name}" detached_head_skip
    return 0
  fi

  # Working tree dirty?
  if [ -n "$(git -C "${repo}" status --porcelain 2>/dev/null)" ]; then
    log INFO "${name}" dirty_tree_skip
    return 0
  fi

  # Compute ahead/behind vs origin/main. Skip if the remote ref is missing.
  if ! git -C "${repo}" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    log INFO "${name}" no_origin_main_skip
    return 0
  fi

  local counts ahead behind
  counts="$(git -C "${repo}" rev-list --left-right --count HEAD...origin/main 2>/dev/null || echo '0	0')"
  ahead="$(printf '%s' "${counts}" | awk '{print $1}')"
  behind="$(printf '%s' "${counts}" | awk '{print $2}')"

  if [ "${ahead}" != "0" ]; then
    log INFO "${name}" ahead_skip "ahead=${ahead} behind=${behind}"
    return 0
  fi

  if [ "${behind}" = "0" ]; then
    log DEBUG "${name}" up_to_date
    return 0
  fi

  # Behind, clean, no local commits — fast-forward.
  if git -C "${repo}" merge --ff-only origin/main >/dev/null 2>&1; then
    log INFO "${name}" fast_forwarded "behind_was=${behind}"
  else
    log WARN "${name}" ff_failed "behind=${behind}"
  fi
}

# --- main loop ---------------------------------------------------------------

log INFO daemon startup "interval=${INTERVAL}s glob=${REPO_GLOB} log=${LOG}"

# Interruptible sleep: sleep in background, wait on it, so a signal during
# the sleep wakes the loop immediately instead of waiting INTERVAL seconds.
interruptible_sleep() {
  local secs="$1"
  sleep "${secs}" &
  local pid=$!
  wait "${pid}" 2>/dev/null || true
}

while [ "${shutdown}" -eq 0 ]; do
  # Bash glob: assign to array for safe iteration even when no matches.
  # shellcheck disable=SC2206
  repos=( ${REPO_GLOB} )

  for repo in "${repos[@]}"; do
    [ "${shutdown}" -eq 0 ] || break
    [ -e "${repo}" ] || continue
    sync_repo "${repo}"
  done

  [ "${shutdown}" -eq 0 ] || break
  interruptible_sleep "${INTERVAL}"
done

log INFO daemon shutdown
exit 0
