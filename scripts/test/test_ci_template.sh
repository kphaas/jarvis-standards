#!/usr/bin/env bash
# Tests for the native-gated workflow template set.
#
# GitHub-hosted Actions should stay cheap: secret scanning and PR/base
# guardrails run on GitHub, while expensive trusted checks run in Forge native
# CI and report as `forge/native-ci-shadow`.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ci="${repo_root}/scripts/_templates/workflows/ci.yml"
trusted="${repo_root}/scripts/_templates/workflows/trusted-sandbox-ci.yml"
readme="${repo_root}/scripts/_templates/workflows/README.md"
ruleset="${repo_root}/docs/policy/RULESET_CANONICAL.md"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

yaml_ok() {
  local path="$1"
  uv run --quiet --with pyyaml python3 -c "import yaml; yaml.safe_load(open('${path}'))" >/dev/null 2>&1
}

job_names() {
  awk '/^jobs:/{f=1; next} f && /^  [A-Za-z0-9_-]+:/{ sub(/^  /, ""); sub(/:.*/, ""); print }' "$1"
}

if yaml_ok "${ci}"; then
  ok "ci.yml parses as valid YAML"
else
  bad "ci.yml parses as valid YAML" "yaml.safe_load raised"
fi

if yaml_ok "${trusted}"; then
  ok "trusted-sandbox-ci.yml parses as valid YAML"
else
  bad "trusted-sandbox-ci.yml parses as valid YAML" "yaml.safe_load raised"
fi

jobs="$(job_names "${ci}")"
if [ "${jobs}" = "secret-scan" ]; then
  ok "hosted ci.yml has only the secret-scan job"
else
  bad "hosted ci.yml has only the secret-scan job" "found jobs: ${jobs}"
fi

if grep -qF "detect-secrets scan --baseline .secrets.baseline" "${ci}"; then
  ok "secret-scan checks the detect-secrets baseline"
else
  bad "secret-scan checks the detect-secrets baseline" "baseline scan command missing"
fi

if grep -qF "fetch-depth: 0" "${ci}"; then
  ok "secret-scan fetches history for baseline comparison"
else
  bad "secret-scan fetches history for baseline comparison" "fetch-depth: 0 missing"
fi

for removed in "  lint:" "  typecheck:" "  test:" "  ci-pass:"; do
  if grep -qF "${removed}" "${ci}"; then
    bad "hosted ci.yml omits ${removed}" "found removed hosted job"
  else
    ok "hosted ci.yml omits ${removed}"
  fi
done

if grep -qF "workflow_dispatch:" "${trusted}" && ! grep -qF "pull_request:" "${trusted}"; then
  ok "trusted-sandbox-ci is manual backup only"
else
  bad "trusted-sandbox-ci is manual backup only" "expected workflow_dispatch and no pull_request trigger"
fi

if grep -qF "forge/native-ci-shadow" "${readme}" \
   && grep -qF "secret-scan" "${readme}" \
   && grep -qF "base-staleness" "${readme}"; then
  ok "workflow README documents native-gated required checks"
else
  bad "workflow README documents native-gated required checks" \
    "README must mention forge/native-ci-shadow, secret-scan, and base-staleness"
fi

if grep -qF '"context": "forge/native-ci-shadow"' "${ruleset}" \
   && grep -qF '"context": "secret-scan"' "${ruleset}" \
   && grep -qF '"context": "base-staleness"' "${ruleset}"; then
  ok "ruleset canonical documents native-gated required checks"
else
  bad "ruleset canonical documents native-gated required checks" \
    "ruleset payload must include forge/native-ci-shadow, secret-scan, and base-staleness"
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
