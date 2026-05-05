# JARVIS template inventory

Source-of-truth templates propagated by `propagate_scripts.sh` (for the
`*.template.sh` family) or by hand-targeted installers (for the other
families). Every artifact JARVIS expects to live in a consumer repo
originates here.

## Layout

| Path | Family | What it is |
|---|---|---|
| `commit_core.template.sh` | propagate-engine | Unified commit script — F/B trait switches per `propagate.config`. Generated output lands at `<consumer>/scripts/<repo>_commit.sh` |
| `check_sync.template.sh` | propagate-engine | Pre-commit drift validator. Generated output lands at `<consumer>/scripts/check_sync.sh` |
| `ruff_detect.template.sh` | propagate-engine | Sourceable lib for ruff resolution across consumer repos |
| `hooks/commit-msg` | hook installer | TD-X22 — strips Cursor agent's `Co-authored-by` trailer. Installed via `scripts/install_hooks.sh` into `.git/hooks/commit-msg` |
| `hooks/pre-commit` | hook installer | TD-X25 + TD-X24 — main-block + namespace enforcement. Installed via `scripts/install_hooks.sh` into `.git/hooks/pre-commit`. Also referenced by the pre-commit framework config below as a `local` repo entry. |
| `hooks/README.md` | docs | Installation + extension instructions for the hooks family |
| `workflows/pr-base-staleness.yml` | workflow installer | TD-X23 — PR base staleness check. Copied into `<consumer>/.github/workflows/pr-base-staleness.yml` |
| `workflows/ci.yml` | workflow installer | TD-X29 — uniform per-repo CI (lint / typecheck / test / secret-scan). Copied into `<consumer>/.github/workflows/ci.yml` |
| `workflows/README.md` | docs | Workflow family inventory + propagation notes |
| `.pre-commit-config.yaml` | pre-commit installer | TD-X28 — pre-commit.com framework config. Copied into consumer repo root by `scripts/install_pre_commit.sh` |
| `.secrets.baseline` | pre-commit installer | TD-X28 — empty Yelp `detect-secrets` baseline. Seeded by `install_pre_commit.sh` via `detect-secrets scan` against the consumer repo, falls back to this template if scan fails |
| `sync_daemon.sh` | LaunchAgent installer | TD-X27 — polling sync daemon body. Staged at `~/.jarvis/sync_daemon.sh` (outside any source repo, per TD-X30) by `scripts/install_sync_daemon.sh` |
| `launchagents/com.jarvis.sync_daemon.plist.template` | LaunchAgent installer | TD-X27 + TD-X30 — LaunchAgent wrapper. Rendered with `{{HOME}}` and `{{INTERVAL}}` substitutions and dropped into `~/Library/LaunchAgents/` by `scripts/install_sync_daemon.sh`. `{{INTERVAL}}` reads from the caller's `SYNC_DAEMON_INTERVAL` env var (default `300`, positive integer required). |

## Family conventions

### propagate-engine (`*.template.sh`)

`propagate_scripts.sh` reads `propagate.config`, substitutes `@@VAR@@`
placeholders per row, and writes a `# GENERATED FROM jarvis-standards`
header into each consumer's target path. See `scripts/README.md` for the
template-file structure (5-line meta-block stripped on generation).

### hook installer

Plain executable scripts under `hooks/`. `scripts/install_hooks.sh` copies
them into `<repo>/.git/hooks/` per fresh clone — `.git/hooks/` is not
tracked by git, so this step is required after every `git clone`.

### workflow installer

Plain YAML under `workflows/`. Copied by hand (or via a future propagation
step) into `<repo>/.github/workflows/`. `jarvis-standards` itself
dogfoods every workflow at `.github/workflows/`.

### pre-commit installer

`scripts/install_pre_commit.sh` lays down `.pre-commit-config.yaml`,
`.secrets.baseline`, and `.jarvis-hooks/pre-commit` (a checked-in copy of
`hooks/pre-commit` so the framework's `local` repo entry can invoke it),
then runs `pre-commit install`. Once installed the framework owns
`.git/hooks/pre-commit`; the local-hook indirection keeps JARVIS's
namespace + main-block enforcement firing.

### LaunchAgent installer

`scripts/install_sync_daemon.sh` renders the plist template with
`{{HOME}}` and `{{INTERVAL}}` substituted, writes to
`~/Library/LaunchAgents/`, stages the daemon body at
`~/.jarvis/sync_daemon.sh`, then `launchctl bootstrap` + `enable` +
`kickstart`. `SYNC_DAEMON_INTERVAL` configures the polling cadence
(default 300s, positive integer); `JARVIS_INSTALL_SKIP_LAUNCHCTL=1` is a
test-only knob that skips the `launchctl` registration steps so the
installer test can exercise the render + stage path without registering
a real service.

`uninstall_sync_daemon.sh` is the symmetric `bootout` + plist removal +
`~/.jarvis/sync_daemon.sh` removal + legacy-copy removal at
`~/jarvis-standards/scripts/sync_daemon.sh` (where Phase-1 installers
left a tracked-tree-dirtying copy before TD-X30). Logs at `~/.jarvis/`
are preserved so the operator can audit what happened during the
daemon's runtime.

## Adding a new template

1. Decide the family. Pick the existing one if it fits — adding a family
   adds an installer script and is rarely justified.
2. Drop the artifact in the matching directory.
3. Add a row to the table above and a one-line note in `scripts/README.md`
   if it's propagate-engine.
4. Wire the installer (or `propagate.config`) so the artifact reaches
   consumer repos.
5. Update `docs/DEPLOYMENT.md` §15.2.x with the new mechanism.
6. Add a smoke test under `scripts/test/` if the artifact has runtime
   behavior worth validating.
