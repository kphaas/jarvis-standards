# JARVIS git hook templates

Canonical source for the local git hooks installed in every JARVIS repo. Hooks
enforce the rules in `docs/DEPLOYMENT.md` §15.2 (Multi-writer / commits, ADR-0005)
at the local-commit boundary, complementing GitHub branch protection on the
server side.

## Hooks

| Hook | TD | Enforces |
|---|---|---|
| `commit-msg` | TD-X22 | §15.2 #12 — strip the Cursor agent's `Co-authored-by: Cursor <cursoragent@cursor.com>` trailer so AI attribution flows through `AI-Agent` / `AI-Model` only |
| `pre-commit` | TD-X25 | §15.2 #11 — block direct commits to `main` / `master`; agents must work on a `claude-code/*` (or `feature/*` for humans) branch |

`commit-msg` is non-blocking by design (always exits 0) — it cleans the
message and writes a best-effort audit line to `~/.jarvis/trailer_strips.log`.
The strip pattern is anchored to the exact Cursor agent line and does NOT
touch legitimate human `Co-authored-by` trailers.

`pre-commit` exits 1 on `main` / `master` and 0 elsewhere. Detached HEAD is
treated as 0 so rebase / cherry-pick work normally.

## Install

From inside the repo:

```bash
/path/to/jarvis-standards/scripts/install_hooks.sh
```

Or specify a target:

```bash
/path/to/jarvis-standards/scripts/install_hooks.sh /path/to/some-repo
```

`--force` skips the overwrite prompt for non-interactive use.

The installer copies files into the target's `.git/hooks/` and `chmod +x`s
them. Hooks are local-only — see "Known gap" below.

## Extend

To add a new hook:

1. Drop the executable script in this directory under its standard git hook
   name (`prepare-commit-msg`, `post-commit`, etc.).
2. Add a corresponding `install_one <name>` line in `scripts/install_hooks.sh`.
3. Add a row to the table above and document the §15.2 rule it enforces.
4. Extend `scripts/test/test_commit_msg_hook.sh` with cases for the new behavior.
5. Update `docs/DEPLOYMENT.md` §15.2.1 to list the new hook.

## Validate locally

Before propagating hook changes:

```bash
scripts/test/test_commit_msg_hook.sh
```

(The script tests both `commit-msg` and `pre-commit` despite the historical
filename — extended in place per TD-X25.)

The test runner exercises both hooks against synthetic inputs in a temporary
git repo and prints PASS / FAIL per case. All cases must pass before opening
a PR.

## Known gap

Hooks live under `.git/hooks/`, which is **not tracked by git**. They must be
reinstalled after every fresh clone. Propagation from outside the clone
cannot solve this — the bootstrap step (`install_hooks.sh`) is required by
hand or via a clone wrapper. This is documented in `docs/DEPLOYMENT.md`
§15.2.1.
