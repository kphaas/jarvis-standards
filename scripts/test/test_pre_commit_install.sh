#!/usr/bin/env bash
# Tests for the JARVIS pre-commit framework bootstrap (TD-X28).
#
# Builds a temp Python repo, runs install_pre_commit.sh, and exercises:
#   - file installs land in expected paths
#   - secret-bearing commit is blocked by detect-secrets
#   - lint-violating Python is auto-fixed by ruff before commit
#   - committing on main is blocked by the JARVIS local hook
#
# All four behaviors must hold. Exits 1 on any failure.
#
# Network: the first run downloads the ruff-pre-commit + detect-secrets
# hook repos into ~/.cache/pre-commit. Subsequent runs are offline-safe.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${repo_root}/scripts/install_pre_commit.sh"

[ -x "${installer}" ] || chmod +x "${installer}"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# Fresh HOME so namespace-violation logs land in scratch, not the real one.
# Note: pre-commit uses ~/.cache/pre-commit which we keep on the real HOME
# so the hook repo cache is reused across runs. We override only the
# JARVIS audit path, which uses HOME explicitly.
real_home="${HOME}"
fake_home="${scratch}/home"
mkdir -p "${fake_home}"

# --- build a tiny Python repo -----------------------------------------------

repo="${scratch}/precommit-test-repo"
git -c init.defaultBranch=main init -q "${repo}"
git -C "${repo}" config user.email t@t
git -C "${repo}" config user.name t
git -C "${repo}" config commit.gpgsign false

cat > "${repo}/pyproject.toml" <<'TOML'
[project]
name = "precommit-test-repo"
version = "0.0.0"
TOML

cat > "${repo}/clean.py" <<'PY'
def hello() -> str:
    return "hi"
PY

git -C "${repo}" add pyproject.toml clean.py
git -C "${repo}" commit -q -m initial

# --- run installer -----------------------------------------------------------

if ! "${installer}" "${repo}" --force >/dev/null 2>&1; then
  bad "installer succeeds" "see installer output (re-run manually)"
else
  ok "installer succeeds"
fi

[ -f "${repo}/.pre-commit-config.yaml" ] && ok "config installed" || bad "config installed" ".pre-commit-config.yaml missing"
[ -f "${repo}/.secrets.baseline" ]       && ok "baseline installed" || bad "baseline installed" ".secrets.baseline missing"
[ -x "${repo}/.jarvis-hooks/pre-commit" ] && ok "jarvis hook installed" || bad "jarvis hook installed" ".jarvis-hooks/pre-commit missing"
[ -f "${repo}/.git/hooks/pre-commit" ]   && ok "framework wired into .git/hooks/pre-commit" || bad "framework wired" "missing"

# Commit the framework artifacts onto main BEFORE we exercise the hook,
# so subsequent branches inherit a working .pre-commit-config.yaml.
# `git -c core.hooksPath=/dev/null commit` bypasses the just-installed
# pre-commit hook (which would block this on-main commit). This is a
# test-setup-only escape hatch; production install_pre_commit.sh callers
# commit on a branch first and merge.
( cd "${repo}" && git add -A && \
    git -c core.hooksPath=/dev/null commit -q -m 'install pre-commit framework' )

# Helper: try a commit on a feature branch with the given identity.
# Captures combined stdout+stderr to ${last_out} and sets RC.
last_out=""
RC=0
try_commit() {
  local branch="$1" identity="$2"
  last_out="${scratch}/commit.$$.${RANDOM}"
  (
    cd "${repo}"
    if git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null; then
      git checkout -q "${branch}"
    else
      git checkout -q -b "${branch}"
    fi
    export JARVIS_AGENT="${identity}"
    export HOME="${fake_home}"
    git add -A
    git commit -m 'try'
  ) >"${last_out}" 2>&1
  RC=$?
}

# clean_tree → drop everything that isn't tracked at HEAD; useful between
# negative-path tests that left artifacts in the working tree or index.
clean_tree() {
  ( cd "${repo}" && \
      git reset -q --hard HEAD && \
      git clean -qfdx -e .pre-commit-config.yaml -e .secrets.baseline -e .jarvis-hooks ) || true
}

# --- detect-secrets blocks a fake AWS key -----------------------------------

# Branch off main so we don't trip the on-main block while exercising the
# secret-scan path.
( cd "${repo}" && git checkout -q -b feature/secret-test main )

cat > "${repo}/leaky.py" <<'PY'
# Intentional fake secret for hook validation.
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
PY

try_commit feature/secret-test human
if [ "${RC}" -ne 0 ] && grep -q -i 'secret' "${last_out}" 2>/dev/null; then
  ok "detect-secrets blocks a fake AWS key"
else
  bad "detect-secrets blocks a fake AWS key" "exit=${RC}; output:
$(sed 's/^/          /' "${last_out}")"
fi

clean_tree

# --- ruff auto-fixes a lint violation ---------------------------------------

( cd "${repo}" && git checkout -q -b feature/lint-test main )

cat > "${repo}/lintme.py" <<'PY'
import os
import sys


def f() -> int:
    return 1
PY

# `import os` and `import sys` are unused — ruff F401 should remove them
# via --fix. The first commit attempt fails because ruff modified files;
# re-stage and the second attempt succeeds with the fixed file.
try_commit feature/lint-test human
if [ "${RC}" -ne 0 ]; then
  ( cd "${repo}" && git add -A )
  try_commit feature/lint-test human
fi

if [ "${RC}" -eq 0 ]; then
  if ! grep -q '^import os' "${repo}/lintme.py" 2>/dev/null && \
     ! grep -q '^import sys' "${repo}/lintme.py" 2>/dev/null; then
    ok "ruff auto-fixes unused imports"
  else
    bad "ruff auto-fixes unused imports" "imports still present in lintme.py"
  fi
else
  bad "ruff auto-fixes unused imports" "commit still failed after re-stage; output:
$(sed 's/^/          /' "${last_out}")"
fi

clean_tree

# --- JARVIS hook blocks commit on main --------------------------------------

( cd "${repo}" && git checkout -q main )
echo "tweak" > "${repo}/note.txt"

try_commit main human
if [ "${RC}" -ne 0 ] && grep -q 'main' "${last_out}" 2>/dev/null; then
  ok "JARVIS local hook blocks commits on main"
else
  bad "JARVIS local hook blocks commits on main" "exit=${RC}; output:
$(sed 's/^/          /' "${last_out}")"
fi

clean_tree

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
