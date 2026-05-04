#!/usr/bin/env bash
# JARVIS local sync inspector — read-only diagnostic for cross-repo drift.
#
# Usage:
#   sync_check.sh                # current repo (cwd's enclosing repo)
#   sync_check.sh /path/to/repo  # specific repo
#   sync_check.sh --all          # auto-detect JARVIS repos under
#                                # ~/jarvis-* or /Users/jarvissand/jarvis-*
#
# Per repo, prints branch, working-tree state, local main vs origin/main,
# and (if not on main) age of the current branch's merge-base.
#
# Read-only: NO fetch, NO pull, NO mutation. All comparisons use the local
# refs as they sit. Run after a manual `git fetch --all` for fresh remote
# state.
#
# Exit code: 0 if every repo inspected is clean / synced, 1 if any need
# attention. Suitable for chaining into shell aliases or status lines.

set -u

# ------------------------------ ANSI -----------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_R=$'\033[31m'; C_Y=$'\033[33m'; C_G=$'\033[32m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=""; C_Y=""; C_G=""; C_D=""; C_0=""
fi

# ------------------------------ args -----------------------------------------
mode="single"
target=""
for arg in "$@"; do
  case "${arg}" in
    --all) mode="all" ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      printf 'sync_check: unknown flag: %s\n' "${arg}" >&2
      exit 2
      ;;
    *)
      [ -z "${target}" ] && target="${arg}" || { printf 'sync_check: too many args\n' >&2; exit 2; }
      ;;
  esac
done

# ------------------------------ repo discovery -------------------------------
discover_repos() {
  local hostname_lc
  hostname_lc="$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  local roots=()
  case "${hostname_lc}" in
    *sandbox*) roots=("/Users/jarvissand") ;;
    *)         roots=("${HOME}") ;;
  esac
  for root in "${roots[@]}"; do
    for d in "${root}"/jarvis-*; do
      [ -d "${d}/.git" ] && printf '%s\n' "${d}"
    done
  done
}

# ------------------------------ repo inspection ------------------------------
need_attention=0
behind_repos=()
stale_branch_repos=()

inspect_one() {
  local repo="$1"
  local name; name="$(basename "${repo}")"

  if [ ! -d "${repo}/.git" ]; then
    printf '  %s%-22s%s  not a git repo\n' "${C_R}" "${name}" "${C_0}"
    need_attention=1
    return
  fi

  local branch
  branch="$(git -C "${repo}" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"

  # Working-tree status
  local porcelain modified untracked dirty_label dirty_color
  porcelain="$(git -C "${repo}" status --porcelain 2>/dev/null)"
  modified="$(printf '%s\n' "${porcelain}" | grep -cE '^( M|M |MM|A |AM|D | D|R |C )')"
  untracked="$(printf '%s\n' "${porcelain}" | grep -c '^??')"
  if [ -z "${porcelain}" ]; then
    dirty_label="clean"
    dirty_color="${C_G}"
  else
    dirty_label="dirty(M=${modified} U=${untracked})"
    dirty_color="${C_Y}"
    need_attention=1
  fi

  # main vs origin/main
  local ahead="?" behind="?" main_label main_color
  if git -C "${repo}" rev-parse --verify -q origin/main >/dev/null && \
     git -C "${repo}" rev-parse --verify -q main        >/dev/null; then
    ahead="$(git -C "${repo}" rev-list --count origin/main..main  2>/dev/null || echo '?')"
    behind="$(git -C "${repo}" rev-list --count main..origin/main 2>/dev/null || echo '?')"
    if [ "${ahead}" = "0" ] && [ "${behind}" = "0" ]; then
      main_label="synced"; main_color="${C_G}"
    elif [ "${ahead}" = "0" ]; then
      main_label="behind ${behind}"; main_color="${C_Y}"
      behind_repos+=("${name}"); need_attention=1
    elif [ "${behind}" = "0" ]; then
      main_label="ahead ${ahead}"; main_color="${C_Y}"
    else
      main_label="diverged ${ahead}↑/${behind}↓"; main_color="${C_R}"
      need_attention=1
    fi
  else
    main_label="no main/origin"; main_color="${C_D}"
  fi

  # Branch base age
  local age_label="" age_color=""
  if [ "${branch}" != "main" ] && [ "${branch}" != "(detached)" ] && \
     git -C "${repo}" rev-parse --verify -q origin/main >/dev/null; then
    local base base_ts now_ts age_days
    base="$(git -C "${repo}" merge-base HEAD origin/main 2>/dev/null || true)"
    if [ -n "${base}" ]; then
      base_ts="$(git -C "${repo}" show -s --format=%ct "${base}" 2>/dev/null || echo 0)"
      now_ts="$(date -u +%s)"
      age_days=$(( (now_ts - base_ts) / 86400 ))
      if   [ "${age_days}" -ge 30 ]; then age_color="${C_R}"; stale_branch_repos+=("${name}"); need_attention=1
      elif [ "${age_days}" -ge 14 ]; then age_color="${C_Y}"; stale_branch_repos+=("${name}"); need_attention=1
      else age_color="${C_G}"
      fi
      age_label="base=${age_days}d"
    fi
  fi

  printf '  %-22s  %sbranch=%-32s%s  %s%-26s%s  main:%s%-22s%s  %s%s%s\n' \
    "${name}" \
    "${C_D}" "${branch}" "${C_0}" \
    "${dirty_color}" "${dirty_label}" "${C_0}" \
    "${main_color}" "${main_label}" "${C_0}" \
    "${age_color}" "${age_label}" "${C_0}"
}

# ------------------------------ dispatch -------------------------------------
repos=()
case "${mode}" in
  all)
    while IFS= read -r r; do repos+=("${r}"); done < <(discover_repos)
    ;;
  single)
    if [ -n "${target}" ]; then
      repos=("$(cd "${target}" && pwd)")
    else
      tl="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [ -z "${tl}" ] && { printf 'sync_check: not inside a git repo and no path given\n' >&2; exit 2; }
      repos=("${tl}")
    fi
    ;;
esac

printf '%sJARVIS sync_check%s — %d repo(s)\n\n' "${C_D}" "${C_0}" "${#repos[@]}"
for r in "${repos[@]}"; do inspect_one "${r}"; done

# ------------------------------ summary --------------------------------------
echo
if [ "${#behind_repos[@]}" -gt 0 ]; then
  printf '%sBehind origin/main:%s %s\n' "${C_Y}" "${C_0}" "${behind_repos[*]}"
  printf '  fix: cd <repo> && git pull --ff-only\n'
fi
if [ "${#stale_branch_repos[@]}" -gt 0 ]; then
  printf '%sStale branch base (>14d):%s %s\n' "${C_Y}" "${C_0}" "${stale_branch_repos[*]}"
  printf '  fix: cd <repo> && git fetch origin main && git rebase origin/main\n'
fi
if [ "${need_attention}" -eq 0 ]; then
  printf '%sAll clean.%s\n' "${C_G}" "${C_0}"
fi

exit "${need_attention}"
