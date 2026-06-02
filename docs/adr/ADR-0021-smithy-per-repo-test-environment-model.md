# ADR-0021 — Smithy Per-Repo Test-Environment Model

**Repo:** `jarvis-standards`
**Status:** PROPOSED
**Date:** 2026-06-02
**Author:** Ken Haas (implementation: Claude Code / Opus 4.8)
**Applies to:** the Smithy/forge test gate (`pipeline/auto_tester.py`) running suites of repos in `DEFAULT_REPO_ALLOWLIST`
**Related:**
- ADR-0010 (this repo) — Cross-Repo Runtime Bridge Contract (forge as a caller into other repos; this ADR is the *test-gate* analogue of that runtime contract)
- ADR-0013 (this repo) — Forge autonomous execution & merge gate (the gate this gate feeds)

---

## 1. Context

The forge test gate runs a target repo's pytest suite to decide whether a phase's changes are safe to merge. It originally resolved a single interpreter — forge's own `.venv` python (`_FORGE_PYTHON`) — for **every** target. That interpreter has only forge's dependencies.

`jarvis-financial` (a `uv` workspace) and `jarvis-medical` declare their own dependency sets (e.g. `pytest-asyncio`, `structlog`, `pydantic-settings`, workspace siblings) that forge's venv does not contain. Pointing forge's interpreter at their suites raises `ModuleNotFoundError` at collection → pytest rc2 → the gate fail-closed-blocks with `suite_error`. Both repos are already in `DEFAULT_REPO_ALLOWLIST`, so the state was *safe but unusable*: every phase against them blocked, regardless of code quality.

Each target already declares the correct environment for itself in its substrate `ci.yml` (`uv sync` with workspace/extras/dev flags, then `uv run pytest -m "not integration"`). Forge should reuse that declaration, not guess.

A hard constraint: a live worker (e.g. the `jarvis-financial` trading agent) may be running out of the repo's own `.venv`. The gate must never mutate that environment.

## 2. Decision

**Run each target repo's suite in that repo's own `uv`-locked environment, isolated from the repo's live `.venv`, auto-detected per repo.**

### 2.1 Auto-detect the runner

`resolve_runner(repo_dir)`, used by **both** gate entry points (changed-file and full-suite):
- `pyproject.toml` **and** `uv.lock` both present → **UV mode**.
- Otherwise → **FORGE mode** (the existing `_FORGE_PYTHON`; covers forge itself and bare repos such as the smoke-target).

`_FORGE_PYTHON` is retained **only** as the FORGE-mode fallback; no gate path hardcodes it anymore.

### 2.2 Isolation (non-negotiable)

All `uv` calls set `UV_PROJECT_ENVIRONMENT=~/.cache/smithy-test-envs/<repo-basename>`. The gate builds into this dedicated, persistent (warm/fast on repeat) environment and **never** touches the repo's own `.venv`. This is the test-gate counterpart to ADR-0010's rule that forge, acting as a cross-repo caller, must not perturb a target's running state.

### 2.3 Environment build mirrors the repo's own CI

Sync flags are derived from the repo's `pyproject.toml`, mirroring the substrate `ci.yml` greps:
- `[tool.uv.workspace]` → `--all-packages`
- `[dependency-groups]` or `[tool.uv.dev-dependencies]` → `--group dev`
- `--all-extras` always

The gate runs `uv sync --locked <flags>` (deterministic; asserts the lock matches `pyproject.toml`, no resolution) with its **own** generous timeout, separate from the pytest timeout (a cold workspace sync is slow). It then runs pytest via `uv run --no-sync --project <repo> python -m pytest …`, leaving the existing command structure and `-rf` retry logic unchanged.

### 2.4 New reason code: `env_error`

`env_error` (the test **environment** could not be built — sync failed, lock stale, sync timeout) is distinct from `suite_error` (the tests ran but are untrustworthy). **Both BLOCK** (fail-closed); the distinction exists for operator clarity — "couldn't set up" vs "tests broke". `env_error` blocks even when a phase opts out of tests.

### 2.5 What is NOT adopted from CI

Only the **sync flags** and the `-m "not integration"` marker are mirrored from the substrate `ci.yml`. The gate's own fail-closed return-code policy is preserved verbatim — in particular CI's "rc5 (no tests collected) = success" is **not** adopted; for the gate, no-tests/skip/timeout/rc2/rc3/rc4/rc5 all BLOCK.

## 3. Consequences

- `jarvis-financial` and `jarvis-medical` become gateable: their suites run in their own declared envs instead of failing import.
- First sync per repo is slow (cold); subsequent runs are warm via the persistent cache env.
- A new failure surface (`uv sync`) is introduced, contained by `env_error` (fail-closed) and a dedicated timeout.
- Forge's own suite and bare repos are unaffected (FORGE mode unchanged).
- The cache directory (`~/.cache/smithy-test-envs/`) is gate-owned state; it can be cleared safely (it only slows the next run).

## 4. Alternatives considered

- **Install every target's deps into forge's shared venv** — rejected: cross-repo version conflicts and unbounded venv growth; re-introduces the drift this avoids.
- **Sync into the repo's own `.venv`** — rejected: violates the isolation constraint (could disrupt a live worker).
- **Per-repo interpreter declared in the allowlist** — heavier and still requires each repo to maintain a second declaration; the repo's `uv.lock` + `ci.yml` already are the declaration.
