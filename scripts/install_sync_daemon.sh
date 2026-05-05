#!/usr/bin/env bash
# JARVIS — install the polling sync daemon as a LaunchAgent (TD-X27).
#
# Renders the plist template with the current $HOME, drops it into
# ~/Library/LaunchAgents/, then bootstrap + enable + kickstart through
# launchctl. Idempotent: safe to re-run; existing agent is bootout'd
# before re-bootstrap so the new plist takes effect.
#
# The daemon script is expected at $HOME/jarvis-standards/scripts/sync_daemon.sh.
# This installer expects to be run from a clone of jarvis-standards and
# resolves the template / source script relative to itself.
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

# Resolve daemon target path. The plist references
# $HOME/jarvis-standards/scripts/sync_daemon.sh, so we copy the templated
# daemon script there with normal +x perms.
daemon_target="${HOME}/jarvis-standards/scripts/sync_daemon.sh"

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
mkdir -p "${HOME}/.jarvis"
mkdir -p "$(dirname "${daemon_target}")"

# --- render plist ------------------------------------------------------------

# Substitute {{HOME}} with $HOME. Use printf to avoid sed escaping headaches
# on paths that might contain unusual characters.
plist_content="$(cat "${plist_template}")"
rendered="${plist_content//'{{HOME}}'/${HOME}}"
printf '%s' "${rendered}" > "${plist_path}"
chmod 644 "${plist_path}"

# --- copy daemon script ------------------------------------------------------

# Phase 1 leaves this as a no-op when the daemon is already in place.
# Phase 2 installer runs from the standards clone and copies the template
# to its canonical location.
cp "${daemon_template}" "${daemon_target}"
chmod +x "${daemon_target}"

# --- launchctl: bootout (best-effort), bootstrap, enable, kickstart ---------

domain="gui/${uid}"
service="${domain}/${label}"

# Bootout existing instance to pick up plist changes. Ignore failure
# (service may not be loaded yet on first install).
launchctl bootout "${service}" >/dev/null 2>&1 || true

launchctl bootstrap "${domain}" "${plist_path}"
launchctl enable "${service}"
launchctl kickstart -k "${service}"

# --- verify ------------------------------------------------------------------

# launchctl print exits non-zero if the service is missing.
if ! launchctl print "${service}" >/dev/null 2>&1; then
  printf 'install_sync_daemon: service did not register: %s\n' "${service}" >&2
  exit 1
fi

interval="$(grep -A1 SYNC_DAEMON_INTERVAL "${plist_path}" | tail -n1 | sed -E 's|.*<string>(.*)</string>.*|\1|' || echo unknown)"

cat <<SUMMARY
JARVIS sync daemon installed.
  user:      $(id -un) (uid=${uid})
  service:   ${service}
  plist:     ${plist_path}
  daemon:    ${daemon_target}
  interval:  ${interval}s
  logs:      ${HOME}/.jarvis/sync_daemon.log
             ${HOME}/.jarvis/sync_daemon.stdout.log
             ${HOME}/.jarvis/sync_daemon.stderr.log

Tail the daemon's own log:
  tail -f ${HOME}/.jarvis/sync_daemon.log
SUMMARY
