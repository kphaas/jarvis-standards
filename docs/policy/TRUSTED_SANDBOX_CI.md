# Trusted Sandbox CI

Trusted Sandbox CI is the private-repo self-hosted compute pattern for JARVIS
pull requests. Forge native CI is the automatic gate: it moves no-secret compute
from GitHub-hosted runners onto the Sandbox Mac while keeping GitHub as the PR
status and branch-protection control plane via `forge/native-ci-shadow`.

The repo-local `.github/workflows/trusted-sandbox-ci.yml` workflow is now a
manual backup only. Operators can dispatch it when Forge native CI is degraded,
but it must not run automatically on every PR because that duplicates the native
gate.

## Ownership

| Surface | Owner | Source |
|---|---|---|
| Manual backup workflow policy and template | `jarvis-standards` | `scripts/_templates/workflows/trusted-sandbox-ci.yml` |
| Runner registry, setup script, doctor, monitor | `jarvis-forge` | Forge runner fleet config and runbooks |
| Repo-specific workflow copy | Consuming repo | `.github/workflows/trusted-sandbox-ci.yml` |

## Trust Boundary

Forge native CI is only for private repositories and trusted same-repo PR
branches. Public repositories and fork PRs stay on GitHub-hosted runners unless
a separate trust model is approved.

Required gates:

- `JARVIS_ENABLE_SANDBOX_RUNNER` must be set to `true` in the consuming repo.
- PR head repo must equal the base repo. Fork PRs are refused.
- PR branch must start with `claude-code/` or `codex/`.
- Jobs run with `contents: read` only.
- No secrets are passed to the self-hosted job.
- The Forge watcher and repo config decide which PRs and paths run native
  checks. Do not trust dependency-update branches on Sandbox without a separate
  policy decision.

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
3. Add the repo to Forge native CI config in `jarvis-forge` as `onboarding`.
4. Open a trusted `claude-code/*` or `codex/*` sample PR and verify
   `forge/native-ci-shadow` posts a green status.
5. Promote the repo to `active` in Forge native CI and require exactly
   `github/guardrails` and `forge/native-ci-shadow` in branch
   protection/rulesets.
6. Keep `.github/workflows/trusted-sandbox-ci.yml` as a manual
   `workflow_dispatch` backup.

## Cost Model

Forge native CI and self-hosted runner jobs do not consume GitHub-hosted Actions
minutes. Keep one GitHub-hosted guardrail job for checks that should remain
independent of Sandbox health: secret scanning and PR base-staleness. Do not run
duplicate hosted `lint`, `typecheck`, `test`, or `ci-pass` jobs after a repo is
native-gated.
