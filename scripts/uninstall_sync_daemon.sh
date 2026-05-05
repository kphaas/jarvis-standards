#!/usr/bin/env bash
# JARVIS — uninstall the polling sync daemon LaunchAgent (TD-X27, TD-X30).
#
# Symmetric to install_sync_daemon.sh: launchctl bootout, then remove the
# plist and the staged daemon script at ~/.jarvis/sync_daemon.sh. Best-
# effort: each removal step tolerates a missing artifact so the
# uninstaller is idempotent.
#
# Also tolerates the legacy install path at
# $HOME/jarvis-standards/scripts/sync_daemon.sh (Phase-1 installer
# location, before TD-X30 moved staging to ~/.jarvis/). Leftover legacy
# copies are removed if present so they don't continue to dirty the
# standards working tree.
#
# Logs are left in place — they are operator data, not derived from the
# install. Operator wipes them by hand if desired.

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

# Staged daemon script at the canonical (TD-X30) path.
canonical_daemon="${HOME}/.jarvis/sync_daemon.sh"
if [ -f "${canonical_daemon}" ]; then
  rm -f "${canonical_daemon}"
  printf 'uninstall_sync_daemon: removed %s\n' "${canonical_daemon}"
fi

# Legacy daemon copy left in jarvis-standards by Phase-1 installer.
# Remove if present so the standards working tree stops showing as dirty
# in the daemon's per-cycle clean-tree check.
legacy_daemon="${HOME}/jarvis-standards/scripts/sync_daemon.sh"
if [ -f "${legacy_daemon}" ]; then
  rm -f "${legacy_daemon}"
  printf 'uninstall_sync_daemon: removed legacy copy at %s\n' "${legacy_daemon}"
fi

cat <<SUMMARY
Daemon uninstalled. Logs retained:
  ${HOME}/.jarvis/sync_daemon.log
  ${HOME}/.jarvis/sync_daemon.stdout.log
  ${HOME}/.jarvis/sync_daemon.stderr.log

Remove logs by hand if desired:
  rm -f ${HOME}/.jarvis/sync_daemon.*.log
SUMMARY
