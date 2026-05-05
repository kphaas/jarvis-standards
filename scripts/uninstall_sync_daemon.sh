#!/usr/bin/env bash
# JARVIS — uninstall the polling sync daemon LaunchAgent (TD-X27).
#
# Symmetric to install_sync_daemon.sh: launchctl bootout, then remove the
# plist. Logs are left in place — they are operator data, not derived from
# the install. Operator wipes them by hand if desired.

set -euo pipefail

label="com.jarvis.sync_daemon"
agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${agents_dir}/${label}.plist"

uid="$(id -u)"
[ -n "${uid}" ] || { printf 'uninstall_sync_daemon: cannot resolve uid\n' >&2; exit 1; }

domain="gui/${uid}"
service="${domain}/${label}"

# bootout is the correct verb per JARVIS LaunchAgent protocol. Tolerate
# missing service (already unloaded).
launchctl bootout "${service}" >/dev/null 2>&1 || true

if [ -f "${plist_path}" ]; then
  rm -f "${plist_path}"
  printf 'uninstall_sync_daemon: removed %s\n' "${plist_path}"
else
  printf 'uninstall_sync_daemon: no plist at %s (already gone)\n' "${plist_path}"
fi

cat <<SUMMARY
Daemon uninstalled. Logs retained:
  ${HOME}/.jarvis/sync_daemon.log
  ${HOME}/.jarvis/sync_daemon.stdout.log
  ${HOME}/.jarvis/sync_daemon.stderr.log

Remove logs by hand if desired:
  rm -f ${HOME}/.jarvis/sync_daemon.*.log
SUMMARY
