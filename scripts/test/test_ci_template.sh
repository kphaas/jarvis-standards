#!/usr/bin/env bash
# Tests for scripts/_templates/workflows/ci.yml (TD-X29 + TD-X32 + TD-X35
# + TD-X48 + TD-X48 v2).
#
# Lints the YAML and grep-asserts that the workspace-aware (TD-X32),
# dev-group-aware (TD-X35), integration-marker (TD-X48), and exit-5
# tolerant (TD-X48 v2) conditional logic exists in the rendered template.
# Cheap structural checks; no runner spin-up. Companion to the live PR
# CI, which exercises the workflow end-to-end on jarvis-standards itself.
#
# Cases:
#   1.  ci.yml parses as valid YAML
#   2.  test job gate also requires root pyproject.toml (TD-X32)
#   3.  test job sync references [tool.uv.workspace] detection (TD-X32)
#   4.  test job sync sets WORKSPACE_FLAG=--all-packages on workspace match (TD-X32)
#   5.  test job sync references [dependency-groups] / [tool.uv.dev-dependencies] detection (TD-X35)
#   6.  test job sync sets DEV_FLAG=--group dev on dev-group match (TD-X35)
#   7.  test job sync command uses ${WORKSPACE_FLAG} and ${DEV_FLAG}, not hardcoded flags
#   8.  typecheck job mirrors test's workspace + dev-group conditional
#   9.  lint job is unchanged — does NOT depend on uv sync
#   10. workflows/README.md mentions TD-X32 / TD-X35 / workspace handling
#   11. test job pytest step exposes PYTEST_MARKERS env var (TD-X48)
#   12. test job pytest step defaults PYTEST_MARKERS to "not integration" (TD-X48)
#   13. test job pytest invocation uses -m "${PYTEST_MARKERS}" (TD-X48)
#   14. test job pytest step references vars.JARVIS_PYTEST_MARKERS for repo override (TD-X48)
#   15. test job treats pytest exit 5 ("no tests collected") as success (TD-X48 v2)

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ci="${repo_root}/scripts/_templates/workflows/ci.yml"
readme="${repo_root}/scripts/_templates/workflows/README.md"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

# Awk helper: extract one job block (between `^  <jobname>:` and the next
# top-level job header) into a temp file. Returns path on stdout.
job_block() {
  local job="$1"
  awk -v j="${job}" '
    $0 ~ "^  " j ":"        { f=1; next }
    f && /^  [a-z][a-z_-]*:/ { exit }
    f                       { print }
  ' "${ci}"
}

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

# --- 3. test job sync references workspace detection (TD-X32) --------------

test_block="$(job_block test)"
if grep -qF '\[tool\.uv\.workspace\]' <<<"${test_block}"; then
  ok "test job sync detects [tool.uv.workspace] (TD-X32)"
else
  bad "test job sync detects [tool.uv.workspace] (TD-X32)" \
    "expected literal '[tool\\.uv\\.workspace]' in test job's sync step grep"
fi

# --- 4. test job sets WORKSPACE_FLAG=--all-packages on workspace branch ----

if grep -qF 'WORKSPACE_FLAG="--all-packages"' <<<"${test_block}"; then
  ok "test job workspace branch: WORKSPACE_FLAG=\"--all-packages\" (TD-X32)"
else
  bad "test job workspace branch: WORKSPACE_FLAG=\"--all-packages\" (TD-X32)" \
    "expected WORKSPACE_FLAG assignment to --all-packages in test job"
fi

# --- 5. test job sync references dev-group detection (TD-X35) --------------

if grep -qF '\[dependency-groups\]' <<<"${test_block}" \
   && grep -qF '\[tool\.uv\.dev-dependencies\]' <<<"${test_block}"; then
  ok "test job sync detects [dependency-groups] OR [tool.uv.dev-dependencies] (TD-X35)"
else
  bad "test job sync detects [dependency-groups] OR [tool.uv.dev-dependencies] (TD-X35)" \
    "expected literals '[dependency-groups]' and '[tool\\.uv\\.dev-dependencies]' in test job's sync step"
fi

# --- 6. test job sets DEV_FLAG=--group dev on dev-group branch ------------

if grep -qE 'DEV_FLAG="--group dev"' <<<"${test_block}"; then
  ok "test job dev-group branch: DEV_FLAG=\"--group dev\" (TD-X35)"
else
  bad "test job dev-group branch: DEV_FLAG=\"--group dev\" (TD-X35)" \
    "expected DEV_FLAG assignment to '--group dev' in test job"
fi

# --- 7. test job sync command uses ${WORKSPACE_FLAG} and ${DEV_FLAG} ------

if grep -qE '^[[:space:]]*uv sync \$\{WORKSPACE_FLAG\} --all-extras \$\{DEV_FLAG\}[[:space:]]*$' <<<"${test_block}"; then
  ok "test job sync uses \${WORKSPACE_FLAG} and \${DEV_FLAG} (no hardcoded flags)"
else
  bad "test job sync uses \${WORKSPACE_FLAG} and \${DEV_FLAG} (no hardcoded flags)" \
    "expected exact line 'uv sync \${WORKSPACE_FLAG} --all-extras \${DEV_FLAG}' in test job"
fi

# --- 8. typecheck job mirrors test's workspace + dev-group conditional ----

typecheck_block="$(job_block typecheck)"
fail_msg=""
grep -qF '\[tool\.uv\.workspace\]' <<<"${typecheck_block}" || fail_msg="${fail_msg} no workspace detection;"
grep -qF 'WORKSPACE_FLAG="--all-packages"' <<<"${typecheck_block}" || fail_msg="${fail_msg} no WORKSPACE_FLAG assignment;"
grep -qF '\[dependency-groups\]' <<<"${typecheck_block}" || fail_msg="${fail_msg} no dependency-groups detection;"
grep -qF 'DEV_FLAG="--group dev"' <<<"${typecheck_block}" || fail_msg="${fail_msg} no DEV_FLAG assignment;"
grep -qE '^[[:space:]]*uv sync \$\{WORKSPACE_FLAG\} --all-extras \$\{DEV_FLAG\}[[:space:]]*$' <<<"${typecheck_block}" || fail_msg="${fail_msg} no \${WORKSPACE_FLAG}/\${DEV_FLAG} sync line;"
if [ -z "${fail_msg}" ]; then
  ok "typecheck job mirrors test job's workspace + dev-group conditional"
else
  bad "typecheck job mirrors test job's workspace + dev-group conditional" \
    "missing in typecheck:${fail_msg}"
fi

# --- 9. lint job is unaffected — no uv sync -------------------------------

lint_block="$(job_block lint)"
if grep -q 'uv sync' <<<"${lint_block}"; then
  bad "lint job does NOT call uv sync (unchanged)" \
    "found a uv sync call in the lint job"
else
  ok "lint job does NOT call uv sync (unchanged)"
fi

# --- 10. README mentions TD-X32 / TD-X35 / workspace ----------------------

if grep -qE 'TD-X32|TD-X35|workspace|dev-group' "${readme}"; then
  ok "workflows README documents TD-X32 / TD-X35 / workspace / dev-group handling"
else
  bad "workflows README documents TD-X32 / TD-X35 / workspace / dev-group handling" \
    "no mention of TD-X32, TD-X35, 'workspace', or 'dev-group' in ${readme}"
fi

# --- 11. test job pytest step exposes PYTEST_MARKERS env (TD-X48) ---------

if grep -qE '^[[:space:]]*PYTEST_MARKERS:' <<<"${test_block}"; then
  ok "test job pytest step exposes PYTEST_MARKERS env var (TD-X48)"
else
  bad "test job pytest step exposes PYTEST_MARKERS env var (TD-X48)" \
    "expected 'PYTEST_MARKERS:' env binding in test job pytest step"
fi

# --- 12. PYTEST_MARKERS defaults to "not integration" (TD-X48) -----------

if grep -qF "'not integration'" <<<"${test_block}"; then
  ok "test job pytest step defaults PYTEST_MARKERS to 'not integration' (TD-X48)"
else
  bad "test job pytest step defaults PYTEST_MARKERS to 'not integration' (TD-X48)" \
    "expected literal 'not integration' default in PYTEST_MARKERS expression"
fi

# --- 13. pytest invocation uses -m "${PYTEST_MARKERS}" (TD-X48) ----------

if grep -qE 'uv run pytest -m "\$\{PYTEST_MARKERS\}"' <<<"${test_block}"; then
  ok "test job pytest invocation uses -m \"\${PYTEST_MARKERS}\" (TD-X48)"
else
  bad "test job pytest invocation uses -m \"\${PYTEST_MARKERS}\" (TD-X48)" \
    "expected 'uv run pytest -m \"\${PYTEST_MARKERS}\"' in test job"
fi

# --- 14. repo-level override via vars.JARVIS_PYTEST_MARKERS (TD-X48) -----

if grep -qF 'vars.JARVIS_PYTEST_MARKERS' <<<"${test_block}"; then
  ok "test job pytest step references vars.JARVIS_PYTEST_MARKERS for repo override (TD-X48)"
else
  bad "test job pytest step references vars.JARVIS_PYTEST_MARKERS for repo override (TD-X48)" \
    "expected 'vars.JARVIS_PYTEST_MARKERS' (GitHub repo variable) in test job pytest step"
fi

# --- 15. test job treats pytest exit 5 as success (TD-X48 v2) ------------
#
# When the marker filter excludes every test, pytest exits 5 ("no tests
# collected"). The substrate must capture that exit code and treat it as
# success — otherwise repos whose suites are 100% integration-marked
# (e.g. family) fail CI on the substrate's own default behavior.

fail_msg=""
grep -qE '\[ "\$rc" -eq 5 \]' <<<"${test_block}" || fail_msg="${fail_msg} no '[ \"\$rc\" -eq 5 ]' guard;"
grep -qE '^[[:space:]]*exit 0[[:space:]]*$' <<<"${test_block}" || fail_msg="${fail_msg} no 'exit 0' branch;"
grep -qE '^[[:space:]]*rc=\$\?[[:space:]]*$' <<<"${test_block}" || fail_msg="${fail_msg} no 'rc=\$?' capture;"
if [ -z "${fail_msg}" ]; then
  ok "test job treats pytest exit 5 (no tests collected) as success (TD-X48 v2)"
else
  bad "test job treats pytest exit 5 (no tests collected) as success (TD-X48 v2)" \
    "missing in test job pytest step:${fail_msg}"
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
