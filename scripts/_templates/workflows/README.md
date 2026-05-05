# JARVIS GitHub Actions workflow templates

Canonical source for the CI workflows propagated to every JARVIS repo's
`.github/workflows/`. These templates enforce policies that benefit from
running on the GitHub side (full git history, PR context, status check API)
rather than the local-commit side handled by `_templates/hooks/`.

## Workflows

| File | TD | Purpose |
|---|---|---|
| `pr-base-staleness.yml` | TD-X23 | Check the PR's merge-base age vs the target branch. Posts an idempotent comment when the base is ≥14 days old; fails the required check when it's ≥30 days. Catches PRs that have rotted (silent merge conflicts, lost context). |
| `ci.yml` | TD-X29 | Uniform per-repo CI: lint (ruff), typecheck (mypy), test (pytest), secret-scan (detect-secrets baseline audit). Each Python job gracefully skips when its config is absent. The aggregator job `ci-pass` is the single required-status-check name configured in branch protection. |

## Propagation

Templates here live under `scripts/_templates/workflows/`. The propagation
step (Phase B3) copies each file into the consuming repo's
`.github/workflows/` directory. There is no automated job today — operators
copy the files by hand or via `propagate_scripts.sh` once that engine
learns the workflows path.

`jarvis-standards` itself dogfoods the workflow at
`.github/workflows/pr-base-staleness.yml`. Any PR opened against
`jarvis-standards`'s `main` exercises the check.

## Adding a new workflow

1. Drop the YAML in this directory under its functional name.
2. Add a row to the table above.
3. Mention the §15.2 rule (or other standard) being enforced.
4. Update `docs/DEPLOYMENT.md` §15.2.1 with the new mechanism.
5. Copy the file into `jarvis-standards/.github/workflows/` so the new
   workflow takes effect on this repo.
