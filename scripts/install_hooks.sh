#!/usr/bin/env bash
# JARVIS — install local git hooks from the canonical templates.
#
# Usage:
#   scripts/install_hooks.sh [target_repo] [--force]
#
# Defaults target_repo to the current working directory. If hooks already
# exist with different content, prompts before overwriting; --force skips
# the prompt (useful for CI / scripted bootstraps).
#
# Hooks installed:
#   commit-msg  — TD-X22, strips Cursor Co-authored-by trailer (§15.2 #12)
#   pre-commit  — TD-X25, blocks direct commits to main / master (§15.2 #11)

set -euo pipefail

force=0
target=""
for arg in "$@"; do
  case "${arg}" in
    --force) force=1 ;;
    -*)
      printf 'install_hooks: unknown flag: %s\n' "${arg}" >&2
      exit 2
      ;;
    *)
      if [ -z "${target}" ]; then
        target="${arg}"
      else
        printf 'install_hooks: unexpected extra argument: %s\n' "${arg}" >&2
        exit 2
      fi
      ;;
  esac
done

target="${target:-$(pwd)}"
target="$(cd "${target}" 2>/dev/null && pwd || true)"
if [ -z "${target}" ]; then
  printf 'install_hooks: target directory does not exist\n' >&2
  exit 1
fi

if [ ! -d "${target}/.git" ]; then
  printf 'install_hooks: %s is not a git repo (.git/ missing)\n' "${target}" >&2
  exit 1
fi

# Resolve template directory relative to this script.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="${script_dir}/_templates/hooks"

if [ ! -d "${template_dir}" ]; then
  printf 'install_hooks: template dir not found: %s\n' "${template_dir}" >&2
  exit 1
fi

hooks_dir="${target}/.git/hooks"
mkdir -p "${hooks_dir}"

install_one() {
  local name="$1"
  local src="${template_dir}/${name}"
  local dst="${hooks_dir}/${name}"

  if [ ! -f "${src}" ]; then
    printf '  %-12s SKIP (template missing: %s)\n' "${name}" "${src}"
    return
  fi

  if [ -f "${dst}" ] && ! cmp -s "${src}" "${dst}"; then
    if [ "${force}" -eq 0 ]; then
      printf '  %-12s exists with different content at %s\n' "${name}" "${dst}"
      printf '              overwrite? [y/N] '
      read -r answer </dev/tty || answer=""
      case "${answer}" in
        y|Y|yes|YES) ;;
        *)
          printf '  %-12s SKIP (kept existing)\n' "${name}"
          return
          ;;
      esac
    fi
  fi

  cp "${src}" "${dst}"
  chmod +x "${dst}"
  printf '  %-12s installed -> %s\n' "${name}" "${dst}"
}

printf 'Installing JARVIS hooks into %s\n' "${target}"
install_one commit-msg
install_one pre-commit
printf 'Done.\n'
