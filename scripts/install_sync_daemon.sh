#!/usr/bin/env bash
# JARVIS — install the polling sync daemon as a LaunchAgent (TD-X27, TD-X30).
#
# Renders the plist template with the current $HOME and the configured
# polling interval, drops it into ~/Library/LaunchAgents/, then bootstrap
# + enable + kickstart through launchctl. Idempotent: safe to re-run;
# existing agent is bootout'd before re-bootstrap so the new plist takes
# effect.
#
# Configuration:
#   SYNC_DAEMON_INTERVAL   seconds between cycles (default 300; positive
#                          integer required, otherwise install aborts)
#
# The daemon script is staged at $HOME/.jarvis/sync_daemon.sh — outside
# any source repo, so the installer never dirties a tracked working tree
# (TD-X30 Bug B fix). The plist's ProgramArguments points to that path.
#
# Phase 2 of the CI/CD substrate — installing the daemon on Sandbox + Air.
# Phase 1 only ships the template; this script is dormant until Phase 2.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="${script_dir}/_templates"
plist_template="${template_dir}/launchagents/com.jarvis.sync_daemon.plist.template"
daemon_template="${template_dir}/sync_daemon.sh"

label="com.jarvis.sync_daemon"
agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${agents_dir}/${label}.plist"

# Daemon staging path lives under ~/.jarvis/, not inside any source repo.
# Keeping it out of the tracked working tree means the daemon's per-cycle
# clean-tree check on jarvis-standards stays accurate after install.
jarvis_dir="${HOME}/.jarvis"
daemon_target="${jarvis_dir}/sync_daemon.sh"

# --- interval --------------------------------------------------------------

# SYNC_DAEMON_INTERVAL controls the polling cadence the LaunchAgent
# inherits. Default 300s; must be a positive integer. Reject anything
# else loudly so a typo doesn't silently fall back to default and waste
# the operator's verification cycle.
interval="${SYNC_DAEMON_INTERVAL:-300}"
if ! printf '%s' "${interval}" | grep -qE '^[1-9][0-9]*$'; then
  printf 'install_sync_daemon: SYNC_DAEMON_INTERVAL must be a positive integer (got: %q)\n' "${interval}" >&2
  exit 1
fi

# --- preflight ---------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'install_sync_daemon: macOS-only (uname=%s)\n' "$(uname -s)" >&2
  exit 1
fi

if [ ! -f "${plist_template}" ]; then
  printf 'install_sync_daemon: template missing: %s\n' "${plist_template}" >&2
  exit 1
fi

if [ ! -f "${daemon_template}" ]; then
  printf 'install_sync_daemon: daemon script missing: %s\n' "${daemon_template}" >&2
  exit 1
fi

uid="$(id -u)"
[ -n "${uid}" ] || { printf 'install_sync_daemon: cannot resolve uid\n' >&2; exit 1; }

mkdir -p "${agents_dir}"
mkdir -p "${jarvis_dir}"

# --- render plist ------------------------------------------------------------

# Substitute {{HOME}} and {{INTERVAL}} with $HOME and the validated
# interval value. Use bash parameter substitution to avoid sed escaping
# headaches on paths that might contain unusual characters.
plist_content="$(cat "${plist_template}")"
rendered="${plist_content//'{{HOME}}'/${HOME}}"
rendered="${rendered//'{{INTERVAL}}'/${interval}}"
printf '%s' "${rendered}" > "${plist_path}"
chmod 644 "${plist_path}"

# --- stage daemon script -----------------------------------------------------

# Copy the daemon body to ~/.jarvis/sync_daemon.sh. Outside any source
# repo so re-running the installer does not leave a tracked-tree dirty.
cp "${daemon_template}" "${daemon_target}"
chmod +x "${daemon_target}"

# --- launchctl: bootout (best-effort), bootstrap, enable, kickstart ---------

domain="gui/${uid}"
service="${domain}/${label}"

# JARVIS_INSTALL_SKIP_LAUNCHCTL is a test-only escape hatch. The installer
# test exercises the render + stage path against a temp HOME and must not
# register a real service in the operator's launchd domain. Production
# callers leave this unset.
if [ "${JARVIS_INSTALL_SKIP_LAUNCHCTL:-0}" != "1" ]; then
  # Bootout existing instance to pick up plist changes. Ignore failure
  # (service may not be loaded yet on first install).
  launchctl bootout "${service}" >/dev/null 2>&1 || true

  launchctl bootstrap "${domain}" "${plist_path}"
  launchctl enable "${service}"
  launchctl kickstart -k "${service}"

  # launchctl print exits non-zero if the service is missing.
  if ! launchctl print "${service}" >/dev/null 2>&1; then
    printf 'install_sync_daemon: service did not register: %s\n' "${service}" >&2
    exit 1
  fi
fi

cat <<SUMMARY
JARVIS sync daemon installed.
  user:      $(id -un) (uid=${uid})
  service:   ${service}
  plist:     ${plist_path}
  daemon:    ${daemon_target}
  interval:  ${interval}s
  logs:      ${jarvis_dir}/sync_daemon.log
             ${jarvis_dir}/sync_daemon.stdout.log
             ${jarvis_dir}/sync_daemon.stderr.log

Tail the daemon's own log:
  tail -f ${jarvis_dir}/sync_daemon.log
SUMMARY
