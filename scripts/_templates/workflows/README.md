# JARVIS GitHub Actions workflow templates

Canonical source for the CI workflows propagated to every JARVIS repo's
`.github/workflows/`. These templates enforce policies that benefit from
running on the GitHub side (full git history, PR context, status check API)
rather than the local-commit side handled by `_templates/hooks/`.

## Workflows

| File | TD | Purpose |
|---|---|---|
| `pr-base-staleness.yml` | TD-X23 | Check the PR's merge-base age vs the target branch. Posts an idempotent comment when the base is ≥14 days old; fails the required check when it's ≥30 days. Catches PRs that have rotted (silent merge conflicts, lost context). |
| `ci.yml` | TD-X29 + TD-X32 + TD-X35 + TD-X48 + TD-X48 v2 | Uniform per-repo CI: lint (ruff), typecheck (mypy), test (pytest), secret-scan (detect-secrets baseline audit). Each Python job gracefully skips when its config is absent. The aggregator job `ci-pass` is the single required-status-check name configured in branch protection. **Workspace-aware sync (TD-X32):** test + typecheck detect `[tool.uv.workspace]` in the root `pyproject.toml` and add `--all-packages` to `uv sync` so workspace siblings install. **Dev-group-aware sync (TD-X35):** the same two jobs detect `[dependency-groups]` (PEP 735) or `[tool.uv.dev-dependencies]` (legacy uv) and add `--group dev` only when present; repos that put pytest in `[project.optional-dependencies]` (e.g. financial) skip the flag and no longer fail with `Group `dev` is not defined`. Repos with no root `pyproject.toml` skip test + typecheck entirely. Lint is unaffected — `uv tool run ruff` operates on the filesystem and does not need a synced env. **Integration-marker filter (TD-X48):** test job invokes `uv run pytest -m "not integration"` by default — tests requiring external services (DB, network) MUST register `@pytest.mark.integration` and are skipped from default CI. Override per-repo via the `JARVIS_PYTEST_MARKERS` repo-level variable (Settings → Variables). **Exit-5 handling (TD-X48 v2):** when the marker filter excludes every test in a 100%-integration repo, pytest exits 5; substrate captures rc, treats 5 as success with a `::notice::` annotation. See `docs/policy/CI_CONVENTIONS.md`. |

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
