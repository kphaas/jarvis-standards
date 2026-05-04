#!/usr/bin/env bash
# Tests for the JARVIS git hooks (TD-X22 commit-msg, TD-X25 pre-commit).
#
# Exercises each hook in a throwaway temp directory. Prints PASS/FAIL per
# case and exits 1 on any failure. Safe to run from any directory.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
commit_msg_hook="${repo_root}/scripts/_templates/hooks/commit-msg"
pre_commit_hook="${repo_root}/scripts/_templates/hooks/pre-commit"

[ -x "${commit_msg_hook}" ] || chmod +x "${commit_msg_hook}"
[ -x "${pre_commit_hook}" ] || chmod +x "${pre_commit_hook}"

pass=0
fail=0

ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

# ----------------------------------------------------------------------------
# commit-msg tests
# ----------------------------------------------------------------------------
printf '\ncommit-msg hook (TD-X22)\n'

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# Use an isolated HOME so the audit log writes to scratch, not the real one.
export HOME="${scratch}/home"
mkdir -p "${HOME}"

# Init a tiny repo so `git rev-parse --show-toplevel` resolves cleanly.
git -C "${scratch}" init -q

run_commit_msg() {
  cp "$1" "$2"
  ( cd "${scratch}" && "${commit_msg_hook}" "$2" )
}

# Case 1: Cursor trailer is removed.
in1="${scratch}/case1.txt"
exp1="${scratch}/case1.expected"
out1="${scratch}/case1.out"
{ printf 'feat(x): something\n\nbody line\n\nCo-authored-by: Cursor <cursoragent@cursor.com>\n'; } > "${in1}"
{ printf 'feat(x): something\n\nbody line\n\n'; } > "${exp1}"
run_commit_msg "${in1}" "${out1}"
if cmp -s "${out1}" "${exp1}"; then
  ok "Cursor trailer removed"
else
  bad "Cursor trailer removed" "$(diff "${exp1}" "${out1}")"
fi

# Case 2: Human Co-authored-by is preserved (different email).
in2="${scratch}/case2.txt"
out2="${scratch}/case2.out"
{ printf 'feat(x): pair\n\nCo-authored-by: Alice <alice@example.com>\n'; } > "${in2}"
run_commit_msg "${in2}" "${out2}"
if cmp -s "${in2}" "${out2}"; then
  ok "Human Co-authored-by preserved"
else
  bad "Human Co-authored-by preserved" "$(diff "${in2}" "${out2}")"
fi

# Case 3: No trailer, message unchanged.
in3="${scratch}/case3.txt"
out3="${scratch}/case3.out"
{ printf 'chore: bump\n\nplain body, nothing to strip\n'; } > "${in3}"
run_commit_msg "${in3}" "${out3}"
if cmp -s "${in3}" "${out3}"; then
  ok "No trailer: message unchanged"
else
  bad "No trailer: message unchanged" "$(diff "${in3}" "${out3}")"
fi

# Case 4: Idempotency — running twice yields same as once.
in4="${scratch}/case4.txt"
once="${scratch}/case4.once"
twice="${scratch}/case4.twice"
{ printf 'feat: a\n\nCo-authored-by: Cursor <cursoragent@cursor.com>\n'; } > "${in4}"
run_commit_msg "${in4}" "${once}"
cp "${once}" "${twice}"
( cd "${scratch}" && "${commit_msg_hook}" "${twice}" )
if cmp -s "${once}" "${twice}"; then
  ok "Idempotent across two runs"
else
  bad "Idempotent across two runs" "$(diff "${once}" "${twice}")"
fi

# Case 5: Empty file handled gracefully.
in5="${scratch}/case5.txt"
out5="${scratch}/case5.out"
: > "${in5}"
if run_commit_msg "${in5}" "${out5}"; then
  if [ ! -s "${out5}" ]; then
    ok "Empty file: graceful (still empty)"
  else
    bad "Empty file: graceful (still empty)" "output non-empty"
  fi
else
  bad "Empty file: graceful (still empty)" "hook exit non-zero"
fi

# Bonus: Exit status is always 0 (audit-log directory unwritable).
in6="${scratch}/case6.txt"
out6="${scratch}/case6.out"
{ printf 'msg\n'; } > "${in6}"
HOME_BACKUP="${HOME}"
export HOME=/nonexistent/should-not-exist-xyz
run_commit_msg "${in6}" "${out6}"
rc=$?
export HOME="${HOME_BACKUP}"
if [ "${rc}" -eq 0 ]; then
  ok "Exit 0 even when audit log unwritable"
else
  bad "Exit 0 even when audit log unwritable" "exit code ${rc}"
fi

# ----------------------------------------------------------------------------
# pre-commit tests (TD-X25 main/master block + TD-X24 namespace)
# ----------------------------------------------------------------------------
printf '\npre-commit hook (TD-X25 main block + TD-X24 namespace)\n'

# Build a fresh repo so we can switch branches cleanly.
pcrepo="${scratch}/pcrepo"
git init -q "${pcrepo}"
git -C "${pcrepo}" -c user.email=t@t -c user.name=t commit --allow-empty -q -m initial
git -C "${pcrepo}" branch -M main

# Run the hook with explicit identity + branch. Returns exit code; stderr
# captured to a per-call file we can inspect for warnings.
# Args: branch, JARVIS_AGENT (empty for default), HOOK_HOSTNAME_OVERRIDE (empty for default)
last_stderr=""
run_hook() {
  local branch="$1"
  local agent="$2"
  local host_override="$3"
  ( cd "${pcrepo}" && git checkout -q "${branch}" 2>/dev/null )
  last_stderr="${scratch}/stderr.$$.${RANDOM}"
  (
    cd "${pcrepo}"
    if [ -n "${agent}" ]; then export JARVIS_AGENT="${agent}"; else unset JARVIS_AGENT; fi
    if [ -n "${host_override}" ]; then export HOOK_HOSTNAME_OVERRIDE="${host_override}"; else unset HOOK_HOSTNAME_OVERRIDE; fi
    "${pre_commit_hook}"
  ) 2>"${last_stderr}"
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${actual}" -eq "${expected}" ]; then
    ok "${desc}"
  else
    bad "${desc}" "expected exit ${expected}, got ${actual}; stderr: $(cat "${last_stderr}" 2>/dev/null)"
  fi
}

assert_stderr_has() {
  local desc="$1" needle="$2"
  if grep -q "${needle}" "${last_stderr}" 2>/dev/null; then
    ok "${desc}"
  else
    bad "${desc}" "expected stderr to contain '${needle}', got: $(cat "${last_stderr}" 2>/dev/null)"
  fi
}

# --- TD-X25 main/master block (regression) ---
run_hook main "human" "macbook-air"; assert_exit "main blocked (exit 1)" 1 $?
git -C "${pcrepo}" branch master main
run_hook master "human" "macbook-air"; assert_exit "master blocked (exit 1)" 1 $?

# --- detached HEAD allowed (regression) ---
git -C "${pcrepo}" checkout -q -b dummy-for-detach
sha="$(git -C "${pcrepo}" rev-parse HEAD)"
git -C "${pcrepo}" checkout -q --detach "${sha}"
last_stderr="${scratch}/stderr.detached"
( cd "${pcrepo}" && "${pre_commit_hook}" ) 2>"${last_stderr}"; rc=$?
assert_exit "detached HEAD allowed (exit 0)" 0 "${rc}"
git -C "${pcrepo}" branch -D dummy-for-detach 2>/dev/null || true

# Ensure each run starts on a known branch so checkout in run_hook can switch.
git -C "${pcrepo}" checkout -q main 2>/dev/null

# Pre-create branches we'll cycle through.
for b in feature/foo claude-code/foo cursor/foo copilot/foo; do
  git -C "${pcrepo}" branch "${b}" main 2>/dev/null || true
done

# --- TD-X24 namespace cases ---

# claude-code agent on feature/* → REJECT
run_hook feature/foo "claude-code" ""; assert_exit "claude-code on feature/foo → reject" 1 $?
assert_stderr_has "  …error mentions namespace + identity" "reserved for human"

# claude-code agent on claude-code/* → silent allow
run_hook claude-code/foo "claude-code" ""; assert_exit "claude-code on claude-code/foo → allow" 0 $?

# human on feature/* → silent allow
run_hook feature/foo "human" ""; assert_exit "human on feature/foo → allow" 0 $?

# human on claude-code/* → warn + allow
run_hook claude-code/foo "human" ""; assert_exit "human on claude-code/foo → allow with warning" 0 $?
assert_stderr_has "  …stderr carries the override warning" "agent namespace"

# cursor agent on feature/* → REJECT
run_hook feature/foo "cursor" ""; assert_exit "cursor on feature/foo → reject" 1 $?

# cursor agent on cursor/* → allow
run_hook cursor/foo "cursor" ""; assert_exit "cursor on cursor/foo → allow" 0 $?

# copilot agent on feature/* → REJECT
run_hook feature/foo "copilot" ""; assert_exit "copilot on feature/foo → reject" 1 $?

# copilot agent on copilot/* → allow
run_hook copilot/foo "copilot" ""; assert_exit "copilot on copilot/foo → allow" 0 $?

# Hostname-fallback: no JARVIS_AGENT, hostname=jarvis-sandbox → claude-code identity → reject feature/*
run_hook feature/foo "" "jarvis-sandbox"; assert_exit "host=jarvis-sandbox + feature/foo → reject" 1 $?

# Hostname-fallback: no JARVIS_AGENT, hostname=macbook-air → human → allow feature/*
run_hook feature/foo "" "macbook-air"; assert_exit "host=macbook-air + feature/foo → allow" 0 $?

# Unknown identity (unrecognized hostname, no env) → treated as human, allowed on feature/*
run_hook feature/foo "" "some-random-host"; assert_exit "unknown identity + feature/foo → allow" 0 $?

# Other namespaces (fix/*, chore/*) are unrestricted regardless of identity.
git -C "${pcrepo}" branch chore/foo main 2>/dev/null || true
run_hook chore/foo "claude-code" ""; assert_exit "claude-code on chore/foo → allow (unrestricted ns)" 0 $?

# ----------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
