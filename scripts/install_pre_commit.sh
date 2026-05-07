#!/usr/bin/env bash
# JARVIS — install the pre-commit framework into a target repo (TD-X28).
#
# Wires:
#   .pre-commit-config.yaml  → ruff (lint+fix) + ruff-format + detect-secrets
#                              + JARVIS namespace/main-block enforcement
#                              + JARVIS force-push block (TD-X31)
#   .secrets.baseline        → detect-secrets baseline (seeded via scan)
#   .jarvis-hooks/pre-commit → checked-in copy of TD-X24 + TD-X25 hook
#   .jarvis-hooks/pre-push   → checked-in copy of TD-X31 force-push block
#   .git/hooks/pre-commit    → managed by `pre-commit install`
#   .git/hooks/pre-push      → managed by `pre-commit install --hook-type pre-push`
#
# pre-commit framework's `pre-commit install` overwrites
# .git/hooks/pre-commit. Without the local-hook indirection above, that
# would silently drop JARVIS's main-block + namespace enforcement. The
# .pre-commit-config.yaml template registers the JARVIS hook as a `local`
# repo entry that runs on every commit (always_run, pass_filenames: false),
# so the framework owns the .git/hooks file but JARVIS's rules still fire.
#
# Usage:
#   scripts/install_pre_commit.sh [target_repo] [--force]
#
# --force overwrites an existing .pre-commit-config.yaml without prompting.
# All other files are overwritten unconditionally on the assumption they
# are JARVIS-managed (.jarvis-hooks/, .secrets.baseline).

set -euo pipefail

force=0
target=""
for arg in "$@"; do
  case "${arg}" in
    --force) force=1 ;;
    -*) printf 'install_pre_commit: unknown flag: %s\n' "${arg}" >&2; exit 2 ;;
    *)
      if [ -z "${target}" ]; then target="${arg}"
      else printf 'install_pre_commit: unexpected extra arg: %s\n' "${arg}" >&2; exit 2
      fi
      ;;
  esac
done

target="${target:-$(pwd)}"
target="$(cd "${target}" 2>/dev/null && pwd || true)"
[ -n "${target}" ] || { printf 'install_pre_commit: target does not exist\n' >&2; exit 1; }
[ -d "${target}/.git" ] || { printf 'install_pre_commit: %s is not a git repo\n' "${target}" >&2; exit 1; }

# A Python repo is the expected case (ruff is python-only). We don't
# hard-block non-python repos because a repo may add Python later, but we
# do warn so the operator can confirm.
if [ ! -f "${target}/pyproject.toml" ] && [ ! -f "${target}/setup.cfg" ] && [ ! -f "${target}/setup.py" ]; then
  printf 'install_pre_commit: warning — no pyproject.toml / setup.cfg / setup.py at %s; ruff will no-op\n' "${target}" >&2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="${script_dir}/_templates"
config_template="${template_dir}/.pre-commit-config.yaml"
baseline_template="${template_dir}/.secrets.baseline"
jarvis_hook_template="${template_dir}/hooks/pre-commit"
jarvis_pre_push_template="${template_dir}/hooks/pre-push"

for f in "${config_template}" "${baseline_template}" "${jarvis_hook_template}" "${jarvis_pre_push_template}"; do
  [ -f "${f}" ] || { printf 'install_pre_commit: template missing: %s\n' "${f}" >&2; exit 1; }
done

# --- pre-commit binary -------------------------------------------------------

if ! command -v pre-commit >/dev/null 2>&1; then
  printf 'install_pre_commit: installing pre-commit via uv tool...\n'
  if command -v uv >/dev/null 2>&1; then
    uv tool install pre-commit
  else
    printf 'install_pre_commit: neither pre-commit nor uv on PATH; install one and retry\n' >&2
    exit 1
  fi
fi

# --- detect-secrets binary (used to seed baseline) --------------------------

if ! command -v detect-secrets >/dev/null 2>&1; then
  printf 'install_pre_commit: installing detect-secrets via uv tool...\n'
  if command -v uv >/dev/null 2>&1; then
    uv tool install detect-secrets
  else
    printf 'install_pre_commit: detect-secrets unavailable; install or set PATH\n' >&2
    exit 1
  fi
fi

# --- file installs -----------------------------------------------------------

config_dst="${target}/.pre-commit-config.yaml"
if [ -f "${config_dst}" ] && ! cmp -s "${config_template}" "${config_dst}"; then
  if [ "${force}" -eq 0 ]; then
    printf '  .pre-commit-config.yaml exists with different content at %s\n' "${config_dst}"
    printf '  overwrite? [y/N] '
    read -r answer </dev/tty || answer=""
    case "${answer}" in
      y|Y|yes|YES) cp "${config_template}" "${config_dst}" ;;
      *) printf '  kept existing .pre-commit-config.yaml — JARVIS hooks may not run\n' ;;
    esac
  else
    cp "${config_template}" "${config_dst}"
  fi
else
  cp "${config_template}" "${config_dst}"
fi

# JARVIS local hooks — checked-in copies at .jarvis-hooks/* so the
# `local` repo entries in .pre-commit-config.yaml have something to invoke.
mkdir -p "${target}/.jarvis-hooks"
cp "${jarvis_hook_template}" "${target}/.jarvis-hooks/pre-commit"
chmod +x "${target}/.jarvis-hooks/pre-commit"
cp "${jarvis_pre_push_template}" "${target}/.jarvis-hooks/pre-push"
chmod +x "${target}/.jarvis-hooks/pre-push"

# --- pre-commit install ------------------------------------------------------

( cd "${target}" && pre-commit install --hook-type pre-commit )
( cd "${target}" && pre-commit install --hook-type pre-push )

# --- seed the secrets baseline ----------------------------------------------

# Use the live scanner to capture current state. Anything reported here is
# documented as a known finding so subsequent commits don't fail on it.
# Operators audit the baseline before committing on adoption.
if [ ! -f "${target}/.secrets.baseline" ]; then
  ( cd "${target}" && detect-secrets scan > .secrets.baseline ) || {
    printf 'install_pre_commit: detect-secrets scan failed; copying empty template instead\n' >&2
    cp "${baseline_template}" "${target}/.secrets.baseline"
  }
else
  printf '  .secrets.baseline already present; left in place (audit before commit)\n'
fi

# --- summary -----------------------------------------------------------------

cat <<SUMMARY
JARVIS pre-commit framework installed in ${target}.
  config:    ${target}/.pre-commit-config.yaml
  baseline:  ${target}/.secrets.baseline
  jarvis:    ${target}/.jarvis-hooks/pre-commit
  pre-push:  ${target}/.jarvis-hooks/pre-push
  hook:      ${target}/.git/hooks/pre-commit  (managed by pre-commit framework)
  pre-push:  ${target}/.git/hooks/pre-push    (managed by pre-commit framework)

Next steps:
  - Audit .secrets.baseline for any unexpected entries
  - git add .pre-commit-config.yaml .secrets.baseline .jarvis-hooks/pre-commit .jarvis-hooks/pre-push
  - Commit per ADR-0005 namespace conventions

Run all hooks against the working tree without committing:
  pre-commit run --all-files
SUMMARY
