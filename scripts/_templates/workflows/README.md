# JARVIS GitHub Actions workflow templates

Canonical source for the CI workflows propagated to every JARVIS repo's
`.github/workflows/`. These templates enforce policies that benefit from
running on the GitHub side (full git history, PR context, status check API)
rather than the local-commit side handled by `_templates/hooks/`.

## Workflows

| File | TD | Purpose |
|---|---|---|
| `pr-base-staleness.yml` | TD-X23 | Check the PR's merge-base age vs the target branch. Posts an idempotent comment when the base is ≥14 days old; fails the required check when it's ≥30 days. Catches PRs that have rotted (silent merge conflicts, lost context). |
| `ci.yml` | Native-gated CI rollout | GitHub-hosted guardrails only: `secret-scan` runs against the detect-secrets baseline on PRs and pushes to `main`. Expensive trusted checks moved to Forge native CI on Sandbox and report as `forge/native-ci-shadow`. |
| `trusted-sandbox-ci.yml` | Sandbox runner backup | Manual `workflow_dispatch` backup for repo-owned no-secret checks on the trusted Sandbox runner. It remains available for operator fallback, but does not run automatically on PRs because Forge native CI owns the automatic trusted gate. See `docs/policy/TRUSTED_SANDBOX_CI.md`. |

## Propagation

Templates here live under `scripts/_templates/workflows/`. The propagation
step (Phase B3) copies each file into the consuming repo's
`.github/workflows/` directory. There is no automated job today. Operators
copy workflow files by hand, or Forge renders workflow templates while the
`propagate_scripts.sh` engine remains shell-template oriented.

`jarvis-standards` itself dogfoods the workflow at
`.github/workflows/pr-base-staleness.yml`. Any PR opened against
`jarvis-standards`'s `main` exercises the check.

For repos promoted to Forge native CI, branch protection and repository
rulesets should require exactly:

- `secret-scan`
- `base-staleness`
- `forge/native-ci-shadow`

Do not require hosted `lint`, `typecheck`, `test`, or `ci-pass` on native-gated
repos; those checks are duplicate paid GitHub-hosted work once Forge native CI is
active.

## Adding a new workflow

1. Drop the YAML in this directory under its functional name.
2. Add a row to the table above.
3. Mention the §15.2 rule (or other standard) being enforced.
4. Update `docs/DEPLOYMENT.md` §15.2.1 with the new mechanism.
5. Copy the file into `jarvis-standards/.github/workflows/` so the new
   workflow takes effect on this repo.
