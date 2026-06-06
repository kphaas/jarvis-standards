# Trusted Sandbox CI

Trusted Sandbox CI is the private-repo self-hosted runner pattern for JARVIS
pull requests. It moves no-secret compute from GitHub-hosted runners onto the
Sandbox Mac while keeping GitHub as the PR status and branch-protection control
plane.

## Ownership

| Surface | Owner | Source |
|---|---|---|
| Workflow policy and template | `jarvis-standards` | `scripts/_templates/workflows/trusted-sandbox-ci.yml` |
| Runner registry, setup script, doctor, monitor | `jarvis-forge` | Forge runner fleet config and runbooks |
| Repo-specific workflow copy | Consuming repo | `.github/workflows/trusted-sandbox-ci.yml` |

## Trust Boundary

The trusted workflow is only for private repositories and trusted same-repo PR
branches. Public repositories and fork PRs stay on GitHub-hosted runners unless
a separate trust model is approved.

Required gates:

- `JARVIS_ENABLE_SANDBOX_RUNNER` must be set to `true` in the consuming repo.
- PR head repo must equal the base repo. Fork PRs are refused.
- PR branch must start with `claude-code/` or `codex/`.
- Jobs run with `contents: read` only.
- No secrets are passed to the self-hosted job.
- The workflow uses source path filters so docs-only PRs do not run the full
  trusted suite.

## Rendering

The template has these placeholders:

| Placeholder | Meaning |
|---|---|
| `@@RUNNER_REPO_LABEL@@` | Repo-specific runner label, for example `jarvis-alpha`. |
| `@@JS_PROJECT_DIRS@@` | Space-separated JavaScript project directories, or empty to auto-detect common dirs. |

`propagate_scripts.sh` currently writes shell templates with a bash generated
header and executable bit, so it must not directly write YAML workflows yet.
Until workflow propagation is added, operators copy the rendered workflow by
hand or use Forge tooling to render the placeholders.

## Rollout Checklist

1. Register a repo-scoped runner on Sandbox with labels:
   `sandbox,<repo>,trusted,macos-arm64`.
2. Set `JARVIS_ENABLE_SANDBOX_RUNNER=true` in the target repo's Actions
   variables.
3. Add `.github/workflows/trusted-sandbox-ci.yml` on a `claude-code/*` or
   `codex/*` branch.
4. Open a PR and verify the trusted workflow runs on the Sandbox runner.
5. Add the repo to Forge's runner fleet registry as `active` only after the
   workflow is merged and the runner doctor passes.

## Cost Model

Self-hosted runner jobs do not consume GitHub-hosted Actions minutes. Keep small
checks combined in this workflow, use `concurrency.cancel-in-progress`, and keep
GitHub-hosted jobs for checks that must remain independent of Sandbox health
such as fleet monitoring or base-staleness checks.
