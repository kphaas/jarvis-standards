#!/usr/bin/env bash
# Tests for the JARVIS sync daemon (TD-X27).
#
# Builds three fake clones in a temp directory, points the daemon at them
# via SYNC_DAEMON_REPO_GLOB + SYNC_DAEMON_INTERVAL=1, runs it for ~3
# cycles, then asserts on the log:
#
#   jarvis-fake-behind  — clean, behind origin/main → must fast-forward
#   jarvis-fake-dirty   — dirty tree, behind        → must SKIP (dirty_tree_skip)
#   jarvis-fake-ahead   — clean, ahead of origin    → must SKIP (ahead_skip)
#
# Exits 1 on any assertion failure.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
daemon="${repo_root}/scripts/_templates/sync_daemon.sh"

[ -x "${daemon}" ] || chmod +x "${daemon}"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'pkill -P $$ 2>/dev/null || true; rm -rf "${scratch}"' EXIT

# Isolate HOME so any default log paths land in scratch, not the real home.
export HOME="${scratch}/home"
mkdir -p "${HOME}"

repos_dir="${scratch}/repos"
mkdir -p "${repos_dir}"

# build_pair NAME → creates remote.git + clone with one initial commit on main.
# Uses -c init.defaultBranch=main so the bare and the clone agree on the
# branch name regardless of the host git's defaultBranch setting.
build_pair() {
  local name="$1"
  local remote="${repos_dir}/${name}.git"
  local clone="${repos_dir}/${name}"

  git -c init.defaultBranch=main init -q --bare "${remote}"

  git -c init.defaultBranch=main init -q "${clone}"
  git -C "${clone}" config user.email t@t
  git -C "${clone}" config user.name t
  git -C "${clone}" config commit.gpgsign false
  printf 'initial\n' > "${clone}/file"
  git -C "${clone}" add file
  git -C "${clone}" commit -q -m initial
  git -C "${clone}" remote add origin "${remote}"
  git -C "${clone}" push -q -u origin main
}

# advance_remote NAME → creates a new commit on the remote that the clone
# does not yet have, simulating a peer pushing while we're idle.
advance_remote() {
  local name="$1"
  local remote="${repos_dir}/${name}.git"
  local helper="${repos_dir}/${name}.helper"

  git clone -q "${remote}" "${helper}"
  git -C "${helper}" config user.email t@t
  git -C "${helper}" config user.name t
  git -C "${helper}" config commit.gpgsign false
  git -C "${helper}" checkout -q main
  printf 'remote-update\n' >> "${helper}/file"
  git -C "${helper}" add file
  git -C "${helper}" commit -q -m 'remote update'
  git -C "${helper}" push -q origin main
  rm -rf "${helper}"
}

build_pair jarvis-fake-behind
build_pair jarvis-fake-dirty
build_pair jarvis-fake-ahead

# behind: remote is one commit ahead of clone (fast-forwardable).
advance_remote jarvis-fake-behind

# dirty: remote ahead too, AND working tree dirty.
advance_remote jarvis-fake-dirty
printf 'unstaged\n' >> "${repos_dir}/jarvis-fake-dirty/file"

# ahead: clone has a local commit that the remote doesn't.
git -C "${repos_dir}/jarvis-fake-ahead" config commit.gpgsign false
printf 'local-only\n' >> "${repos_dir}/jarvis-fake-ahead/file"
git -C "${repos_dir}/jarvis-fake-ahead" add file
git -C "${repos_dir}/jarvis-fake-ahead" commit -q -m 'local only'

# --- run the daemon in the background, watching our test repos -------------

log_file="${scratch}/sync_daemon.log"

(
  export SYNC_DAEMON_INTERVAL=1
  export SYNC_DAEMON_REPO_GLOB="${repos_dir}/jarvis-*"
  export SYNC_DAEMON_LOG="${log_file}"
  exec "${daemon}"
) &
daemon_pid=$!

# Allow ~3 cycles to elapse.
sleep 4

# Graceful shutdown: SIGTERM to the daemon, then wait briefly. Because the
# daemon runs sleep in the background and waits on it, the signal wakes it
# up promptly.
kill -TERM "${daemon_pid}" 2>/dev/null || true
wait "${daemon_pid}" 2>/dev/null || true

# --- assertions on the log --------------------------------------------------

if [ ! -s "${log_file}" ]; then
  bad "log file written" "no entries at ${log_file}"
else
  ok "log file written"
fi

assert_log() {
  local desc="$1" pattern="$2"
  if grep -q "${pattern}" "${log_file}" 2>/dev/null; then
    ok "${desc}"
  else
    bad "${desc}" "pattern not found: '${pattern}' in:
$(sed 's/^/          /' "${log_file}" 2>/dev/null || true)"
  fi
}

# Daemon lifecycle.
assert_log "daemon startup logged"  "daemon	startup"
assert_log "daemon shutdown logged" "daemon	shutdown"

# Per-repo expected actions (tab-separated columns: ts, level, repo, action).
assert_log "behind repo fast-forwarded"   "jarvis-fake-behind	fast_forwarded"
assert_log "dirty repo skipped"           "jarvis-fake-dirty	dirty_tree_skip"
assert_log "ahead repo skipped"           "jarvis-fake-ahead	ahead_skip"

# Behind repo should now actually be at the remote tip.
behind_local="$(git -C "${repos_dir}/jarvis-fake-behind" rev-parse HEAD 2>/dev/null || echo none)"
behind_remote="$(git -C "${repos_dir}/jarvis-fake-behind.git" rev-parse main 2>/dev/null || echo none)"
if [ "${behind_local}" = "${behind_remote}" ] && [ "${behind_local}" != "none" ]; then
  ok "behind repo HEAD now matches remote tip"
else
  bad "behind repo HEAD now matches remote tip" "local=${behind_local} remote=${behind_remote}"
fi

# Dirty repo must NOT have advanced — its local file should still differ.
dirty_clone_head="$(git -C "${repos_dir}/jarvis-fake-dirty" rev-parse HEAD 2>/dev/null || echo none)"
dirty_remote_head="$(git -C "${repos_dir}/jarvis-fake-dirty.git" rev-parse main 2>/dev/null || echo none)"
if [ "${dirty_clone_head}" != "${dirty_remote_head}" ]; then
  ok "dirty repo HEAD did NOT advance"
else
  bad "dirty repo HEAD did NOT advance" "clone=${dirty_clone_head} remote=${dirty_remote_head}"
fi

# Ahead repo must NOT have moved either.
ahead_local_after="$(git -C "${repos_dir}/jarvis-fake-ahead" rev-parse HEAD 2>/dev/null || echo none)"
ahead_remote_after="$(git -C "${repos_dir}/jarvis-fake-ahead.git" rev-parse main 2>/dev/null || echo none)"
if [ "${ahead_local_after}" != "${ahead_remote_after}" ]; then
  ok "ahead repo HEAD preserved (local commit retained)"
else
  bad "ahead repo HEAD preserved" "clone=${ahead_local_after} remote=${ahead_remote_after}"
fi

# Log line shape: every non-blank line should start with an ISO-8601 UTC ts
# followed by a tab. Count lines that do NOT match that pattern.
shape_violations="$(awk '!/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\t/ && NF > 0 { c++ } END { print c+0 }' "${log_file}" 2>/dev/null || echo 99)"
if [ "${shape_violations}" = "0" ]; then
  ok "log shape: every line is timestamped"
else
  bad "log shape: every line is timestamped" "${shape_violations} lines did not match"
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
