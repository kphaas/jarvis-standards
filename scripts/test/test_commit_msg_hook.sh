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
# pre-commit tests (TD-X25)
# ----------------------------------------------------------------------------
printf '\npre-commit hook (TD-X25)\n'

# Build a fresh repo so we can switch branches cleanly.
pcrepo="${scratch}/pcrepo"
git init -q "${pcrepo}"
git -C "${pcrepo}" -c user.email=t@t -c user.name=t commit --allow-empty -q -m initial
git -C "${pcrepo}" branch -M main

# Helper: run the hook with HEAD pointed at a given branch, capture exit code.
run_on_branch() {
  local branch="$1"
  ( cd "${pcrepo}" && git checkout -q "${branch}" 2>/dev/null && "${pre_commit_hook}" )
}

# Case A: main → blocked.
if run_on_branch main >/dev/null 2>&1; then
  bad "Branch main blocked (exit 1)" "hook exited 0"
else
  ok "Branch main blocked (exit 1)"
fi

# Case B: master → blocked.
git -C "${pcrepo}" branch master main
if run_on_branch master >/dev/null 2>&1; then
  bad "Branch master blocked (exit 1)" "hook exited 0"
else
  ok "Branch master blocked (exit 1)"
fi

# Case C: feature/foo → allowed.
git -C "${pcrepo}" checkout -q -b feature/foo
if run_on_branch feature/foo >/dev/null 2>&1; then
  ok "Branch feature/foo allowed (exit 0)"
else
  bad "Branch feature/foo allowed (exit 0)" "hook exited non-zero"
fi

# Case D: claude-code/bar → allowed.
git -C "${pcrepo}" checkout -q -b claude-code/bar
if run_on_branch claude-code/bar >/dev/null 2>&1; then
  ok "Branch claude-code/bar allowed (exit 0)"
else
  bad "Branch claude-code/bar allowed (exit 0)" "hook exited non-zero"
fi

# Case E: detached HEAD → allowed.
sha="$(git -C "${pcrepo}" rev-parse HEAD)"
git -C "${pcrepo}" checkout -q --detach "${sha}"
if ( cd "${pcrepo}" && "${pre_commit_hook}" ) >/dev/null 2>&1; then
  ok "Detached HEAD allowed (exit 0)"
else
  bad "Detached HEAD allowed (exit 0)" "hook exited non-zero"
fi

# ----------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
