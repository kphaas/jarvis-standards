#!/usr/bin/env bash
# Tests for install_sync_daemon.sh (TD-X30 — installer fixes for
# SYNC_DAEMON_INTERVAL propagation and source-repo pollution).
#
# Exercises the render + stage path of the installer against a sandboxed
# $HOME and asserts on the rendered plist + staged daemon. The
# launchctl-talking section is suppressed via JARVIS_INSTALL_SKIP_LAUNCHCTL=1
# so the test never registers a real service or touches the operator's
# launchd domain.
#
# Cases:
#   1. Default install → plist has interval 300
#   2. SYNC_DAEMON_INTERVAL=30 → plist has interval 30
#   3. SYNC_DAEMON_INTERVAL=invalid → installer rejects with clear error
#   4. Staged daemon at $HOME/.jarvis/sync_daemon.sh exists and is +x
#   5. Source repo working tree unchanged after install (no untracked
#      files newly introduced under scripts/)
#   6. ProgramArguments path in rendered plist references ~/.jarvis/, not
#      ~/jarvis-standards/scripts/ (regression for Bug B)

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${repo_root}/scripts/install_sync_daemon.sh"

[ -x "${installer}" ] || chmod +x "${installer}"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# Snapshot the source repo's untracked-file set BEFORE the test runs so
# we can detect any new pollution introduced by the installer at the end.
# `git status --porcelain` is run from the repo root.
pre_dirty="$(git -C "${repo_root}" status --porcelain 2>/dev/null | sort)"

# --- helper: invoke installer in a sandboxed HOME ---------------------------

# run_installer INTERVAL_VALUE
#   INTERVAL_VALUE is exported as SYNC_DAEMON_INTERVAL when non-empty.
# Captures stdout+stderr to ${last_out}; sets RC.
last_out=""
RC=0
run_installer() {
  local interval_val="${1-}"
  last_out="${scratch}/installer.$$.${RANDOM}"
  fake_home="${scratch}/home.${RANDOM}"
  mkdir -p "${fake_home}"

  (
    export HOME="${fake_home}"
    export JARVIS_INSTALL_SKIP_LAUNCHCTL=1
    if [ -n "${interval_val}" ]; then
      export SYNC_DAEMON_INTERVAL="${interval_val}"
    else
      unset SYNC_DAEMON_INTERVAL
    fi
    "${installer}"
  ) >"${last_out}" 2>&1
  RC=$?
}

# --- helper: extract SYNC_DAEMON_INTERVAL value from a rendered plist ------

extract_interval() {
  local plist="$1"
  # Anchor on the <key>SYNC_DAEMON_INTERVAL</key> XML element, not any
  # mention of the name (the template's docstring comment includes the
  # variable name in prose).
  awk '/<key>SYNC_DAEMON_INTERVAL<\/key>/{getline; print; exit}' "${plist}" \
    | sed -E 's|.*<string>(.*)</string>.*|\1|'
}

# --- case 1: default install → interval 300 --------------------------------

run_installer ""
plist="${fake_home}/Library/LaunchAgents/com.jarvis.sync_daemon.plist"
if [ "${RC}" -eq 0 ] && [ -f "${plist}" ]; then
  iv="$(extract_interval "${plist}")"
  if [ "${iv}" = "300" ]; then
    ok "default install: plist interval=300"
  else
    bad "default install: plist interval=300" "got '${iv}'"
  fi
else
  bad "default install: plist interval=300" "RC=${RC}; output:
$(sed 's/^/          /' "${last_out}")"
fi

# --- case 4 (rolled into case 1): staged daemon present + executable --------

staged="${fake_home}/.jarvis/sync_daemon.sh"
if [ -x "${staged}" ]; then
  ok "staged daemon present and +x at ~/.jarvis/sync_daemon.sh"
else
  bad "staged daemon present and +x at ~/.jarvis/sync_daemon.sh" \
    "missing or not executable: ${staged}"
fi

# --- case 6 (rolled into case 1): plist points at ~/.jarvis/, not legacy ---

if grep -q "${fake_home}/.jarvis/sync_daemon.sh" "${plist}" 2>/dev/null && \
   ! grep -q "jarvis-standards/scripts/sync_daemon.sh" "${plist}" 2>/dev/null; then
  ok "plist ProgramArguments uses ~/.jarvis/ path (Bug B regression)"
else
  bad "plist ProgramArguments uses ~/.jarvis/ path (Bug B regression)" \
    "see plist:
$(sed 's/^/          /' "${plist}")"
fi

# --- case 2: explicit interval honored -------------------------------------

run_installer 30
plist="${fake_home}/Library/LaunchAgents/com.jarvis.sync_daemon.plist"
if [ "${RC}" -eq 0 ] && [ -f "${plist}" ]; then
  iv="$(extract_interval "${plist}")"
  if [ "${iv}" = "30" ]; then
    ok "SYNC_DAEMON_INTERVAL=30: plist interval=30"
  else
    bad "SYNC_DAEMON_INTERVAL=30: plist interval=30" "got '${iv}'"
  fi
else
  bad "SYNC_DAEMON_INTERVAL=30: plist interval=30" "RC=${RC}"
fi

# A larger value, exercises the no-leading-zero branch.
run_installer 1800
plist="${fake_home}/Library/LaunchAgents/com.jarvis.sync_daemon.plist"
iv="$(extract_interval "${plist}")"
if [ "${RC}" -eq 0 ] && [ "${iv}" = "1800" ]; then
  ok "SYNC_DAEMON_INTERVAL=1800: plist interval=1800"
else
  bad "SYNC_DAEMON_INTERVAL=1800: plist interval=1800" \
    "RC=${RC} interval='${iv}'"
fi

# --- case 3: invalid intervals rejected ------------------------------------

assert_reject() {
  local desc="$1" value="$2"
  run_installer "${value}"
  if [ "${RC}" -ne 0 ] && grep -q "must be a positive integer" "${last_out}"; then
    ok "${desc}"
  else
    bad "${desc}" "RC=${RC}; output:
$(sed 's/^/          /' "${last_out}")"
  fi
}

assert_reject "SYNC_DAEMON_INTERVAL=invalid → reject"  "invalid"
assert_reject "SYNC_DAEMON_INTERVAL=0 → reject"        "0"
assert_reject "SYNC_DAEMON_INTERVAL=-30 → reject"      "-30"
assert_reject "SYNC_DAEMON_INTERVAL=30s → reject"      "30s"

# Empty string: bash parameter expansion ${VAR:-300} treats "" as unset,
# so the installer falls back to 300. Verify that's the behavior so the
# fallback is the documented spec.
last_out="${scratch}/explicit_empty"
fake_home="${scratch}/home.empty"
mkdir -p "${fake_home}"
(
  export HOME="${fake_home}"
  export JARVIS_INSTALL_SKIP_LAUNCHCTL=1
  export SYNC_DAEMON_INTERVAL=""
  "${installer}"
) >"${last_out}" 2>&1
RC=$?
# Bash parameter expansion ${SYNC_DAEMON_INTERVAL:-300} treats empty
# string as unset, so the installer should fall back to 300. Verify
# that's the behavior — and document it as the spec.
if [ "${RC}" -eq 0 ]; then
  iv="$(extract_interval "${fake_home}/Library/LaunchAgents/com.jarvis.sync_daemon.plist")"
  if [ "${iv}" = "300" ]; then
    ok "SYNC_DAEMON_INTERVAL='' → default 300 (parameter-expansion fallback)"
  else
    bad "SYNC_DAEMON_INTERVAL='' → default 300" "got '${iv}'"
  fi
else
  bad "SYNC_DAEMON_INTERVAL='' → default 300" "installer failed unexpectedly: RC=${RC}"
fi

# --- case 5: source repo working tree unchanged ----------------------------

post_dirty="$(git -C "${repo_root}" status --porcelain 2>/dev/null | sort)"
if [ "${pre_dirty}" = "${post_dirty}" ]; then
  ok "source repo working tree unchanged after installs"
else
  bad "source repo working tree unchanged after installs" \
    "pre/post diff:
$(diff <(printf '%s\n' "${pre_dirty}") <(printf '%s\n' "${post_dirty}") | sed 's/^/          /')"
fi

# --- case 7: rendered plist passes plutil lint -----------------------------

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "${plist}" >/dev/null 2>&1; then
    ok "rendered plist passes plutil -lint"
  else
    bad "rendered plist passes plutil -lint" \
      "plutil reported errors on ${plist}"
  fi
else
  printf '  SKIP  rendered plist passes plutil -lint (plutil unavailable)\n'
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
