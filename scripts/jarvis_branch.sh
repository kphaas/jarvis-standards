#!/usr/bin/env bash
# jarvis_branch - create a new feature branch in the current repo, push upstream
#
# Usage: jarvis_branch <branch-name>
#
# Branch name must start with one of: feature/, claude-code/, hotfix/, chore/
#
# Behavior:
#   1. Verify clean tree
#   2. Switch to main + pull latest
#   3. Create new branch from main
#   4. Push upstream with -u
#
set -euo pipefail

readonly VALID_PREFIXES=("feature/" "claude-code/" "hotfix/" "chore/")

usage() {
  cat <<EOF
Usage: jarvis_branch <branch-name>

Create a new branch from latest origin/main and push upstream.

Branch name must start with one of:
  feature/        - human-driven feature work
  claude-code/    - agent-driven feature work
  hotfix/         - production fix
  chore/          - non-feature maintenance

Examples:
  jarvis_branch feature/m3-day-trading-agent
  jarvis_branch claude-code/td-x31-forge-substrate
EOF
  exit 1
}

if [ $# -ne 1 ] || [ -z "$1" ]; then
  usage
fi

readonly BRANCH="$1"

prefix_ok=0
for p in "${VALID_PREFIXES[@]}"; do
  if [[ "$BRANCH" == "$p"* ]]; then
    prefix_ok=1
    break
  fi
done
if [ "$prefix_ok" -ne 1 ]; then
  echo "ERROR: Branch name '$BRANCH' must start with one of: ${VALID_PREFIXES[*]}" >&2
  exit 4
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: Not in a git repository" >&2
  exit 2
fi

repo_root=$(git rev-parse --show-toplevel)
echo "-> Repo: $repo_root"

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: Working tree is dirty. Commit or stash first." >&2
  git status --short
  exit 3
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "ERROR: Branch '$BRANCH' already exists locally" >&2
  exit 5
fi
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Branch '$BRANCH' already exists on origin" >&2
  exit 5
fi

echo "-> Pulling latest origin/main..."
git checkout main
git pull origin main

echo "-> Creating branch '$BRANCH' from main..."
git checkout -b "$BRANCH"
echo "-> Pushing to origin with upstream tracking..."
git push -u origin "$BRANCH"

echo ""
echo "OK: Branch '$BRANCH' created and pushed"
echo "    You are on this branch. Edit + commit + run 'jarvis_pr' when ready."
