#!/usr/bin/env bash
# Tests for scripts/_templates/workflows/ci.yml (TD-X29 + TD-X32).
#
# Lints the YAML and grep-asserts that the workspace-aware conditional
# logic added in TD-X32 actually exists in the rendered template.
# Cheap structural checks; no runner spin-up. Companion to the live PR
# CI, which exercises the workflow end-to-end on jarvis-standards
# itself.
#
# Cases:
#   1. ci.yml parses as valid YAML
#   2. test job gate also requires root pyproject.toml (TD-X32)
#   3. test job's sync step references [tool.uv.workspace] detection
#   4. test job's sync step uses --all-packages on the workspace branch
#   5. test job's sync step adds --group dev (covers family case)
#   6. typecheck job mirrors test's workspace-aware sync
#   7. lint job is unchanged — does NOT depend on uv sync
#   8. workflows/README.md mentions TD-X32 / workspace handling

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ci="${repo_root}/scripts/_templates/workflows/ci.yml"
readme="${repo_root}/scripts/_templates/workflows/README.md"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

# --- 1. YAML lint -----------------------------------------------------------

if uv run --quiet --with pyyaml python3 -c "import yaml; yaml.safe_load(open('${ci}'))" >/dev/null 2>&1; then
  ok "ci.yml parses as valid YAML"
else
  bad "ci.yml parses as valid YAML" "yaml.safe_load raised"
fi

# --- 2. test gate requires root pyproject.toml ------------------------------

if awk '/^  test:/{f=1} f && /Skip if no root pyproject.toml or no tests/{found=1; exit} END{exit !found}' "${ci}"; then
  ok "test job gate requires root pyproject.toml + tests/ (TD-X32)"
else
  bad "test job gate requires root pyproject.toml + tests/ (TD-X32)" \
    "did not find the updated 'Skip if no root pyproject.toml or no tests/' header in the test job"
fi

# --- 3. test job sync references workspace detection -----------------------

# Look for the conditional's tell — the echo on the workspace branch.
# The literal `[tool.uv.workspace]` in the bash conditional is heavily
# escape-laden (`'^\[tool\.uv\.workspace\]'`); matching the echo string
# is a much simpler structural assertion.
if awk '/^  test:/{f=1} f && /^  [a-z]/ && !/^  test:/{exit} f && /uv workspace detected/{found=1} END{exit !found}' "${ci}"; then
  ok "test job sync has workspace-detected branch"
else
  bad "test job sync has workspace-detected branch" \
    "expected echo 'uv workspace detected ...' in test job's sync step"
fi

# --- 4. test job uses --all-packages on workspace branch -------------------

if awk '/^  test:/{f=1} f && /^  [a-z]/ && !/^  test:/{exit} f && /uv sync --all-packages --all-extras --group dev/{found=1} END{exit !found}' "${ci}"; then
  ok "test job workspace branch: --all-packages --all-extras --group dev"
else
  bad "test job workspace branch: --all-packages --all-extras --group dev" \
    "expected exact command not found in test job"
fi

# --- 5. test job non-workspace branch adds --group dev --------------------

if awk '/^  test:/{f=1} f && /^  [a-z]/ && !/^  test:/{exit} f && /^[[:space:]]*uv sync --all-extras --group dev/{found=1} END{exit !found}' "${ci}"; then
  ok "test job non-workspace branch: --all-extras --group dev"
else
  bad "test job non-workspace branch: --all-extras --group dev" \
    "expected non-workspace fallback command not found in test job"
fi

# --- 6. typecheck job mirrors test's workspace-aware sync -----------------

if awk '/^  typecheck:/{f=1} f && /^  [a-z]/ && !/^  typecheck:/{exit} f && /uv workspace detected/{a=1} f && /uv sync --all-packages --all-extras --group dev/{b=1} END{exit !(a && b)}' "${ci}"; then
  ok "typecheck job has the same workspace-aware sync as test"
else
  bad "typecheck job has the same workspace-aware sync as test" \
    "typecheck job missing one of [tool.uv.workspace] detection or --all-packages branch"
fi

# --- 7. lint job is unaffected — no uv sync ------------------------------

if awk '/^  lint:/{f=1} f && /^  [a-z]/ && !/^  lint:/{exit} f && /uv sync/{found=1} END{exit found}' "${ci}"; then
  ok "lint job does NOT call uv sync (unchanged)"
else
  bad "lint job does NOT call uv sync (unchanged)" \
    "found a uv sync call in the lint job"
fi

# --- 8. README mentions TD-X32 / workspace -------------------------------

if grep -qiE 'TD-X32|workspace' "${readme}"; then
  ok "workflows README documents TD-X32 / workspace handling"
else
  bad "workflows README documents TD-X32 / workspace handling" \
    "no mention of TD-X32 or 'workspace' in ${readme}"
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
