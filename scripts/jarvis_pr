#!/usr/bin/env bash
# jarvis_pr - push current branch + open a PR against main
#
# Usage: jarvis_pr [--draft] [--title "<title>"] [--body "<body>"]
#
# Default title/body: gh --fill (uses last commit msg)
#
set -euo pipefail

DRAFT=""
TITLE=""
BODY=""
USE_FILL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --draft)
      DRAFT="--draft"
      shift
      ;;
    --title)
      TITLE="$2"
      USE_FILL=0
      shift 2
      ;;
    --body)
      BODY="$2"
      USE_FILL=0
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: jarvis_pr [--draft] [--title "<title>"] [--body "<body>"]

Push current branch and open a PR against main.

Options:
  --draft         Create as draft PR
  --title TEXT    Custom PR title (default: last commit msg via gh --fill)
  --body TEXT     Custom PR body
  -h, --help      This message
EOF
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: Not in a git repository" >&2
  exit 2
fi

readonly BRANCH=$(git branch --show-current)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo "ERROR: Refusing to PR from $BRANCH. Switch to a feature branch first." >&2
  exit 3
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: Working tree is dirty. Commit before opening PR." >&2
  git status --short
  exit 4
fi

echo "-> Pushing branch '$BRANCH'..."
git push origin "$BRANCH"

echo "-> Opening PR..."
if [ "$USE_FILL" = "1" ]; then
  gh pr create --base main --head "$BRANCH" --fill $DRAFT
else
  gh pr create --base main --head "$BRANCH" --title "$TITLE" --body "$BODY" $DRAFT
fi

echo ""
echo "OK: PR opened. Use 'gh pr view --web' to open in browser."
