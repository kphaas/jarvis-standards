# ADR-0022 — Smithy Agent: Spec-Driven Project Authoring & Orchestration

**Repo:** `jarvis-standards`
**Status:** PROPOSED
**Date:** 2026-06-02
**Author:** Ken Haas (implementation: Claude Code / Opus 4.8)
**Applies to:** the layer above the Smithy/forge build pipeline in `jarvis-forge` — authoring, provisioning, and shepherding a project from a single spec
**Related:**
- ADR-0012 (this repo) — Project / Phase Pipeline Data Model (the `project.md` + `phase-*.md` format the Decomposer must emit; the agent reuses its parsers, it does not invent a schema)
- ADR-0013 (this repo) — Forge autonomous execution & merge gate (the pipeline the agent sits on top of, not a reimplementation)
- ADR-0021 (this repo) — Smithy per-repo test-environment model (the fail-closed test gate a shepherded phase passes through)
- ADR-0014 (this repo) — Operator Decision Artifacts (`CouncilDecision`; the decision-hook's eventual Council backend — the follow-up that ADR notes)
- ADR-0010 (this repo) — Cross-Repo Runtime Bridge Contract (how forge will call Council cross-repo when the hook's backend is swapped)

---

## 1. Context

The Smithy build machine works end-to-end: inbox → preflight → Aider (local codegen) → Claude (review/optimize) → fail-closed test gate (now per-repo `uv` env, ADR-0021) → PR → human merge. What is missing is the layer **above** it. Today a human hand-authors `project.md` + `phase-*.md`, provisions any new repo by hand, drops the spec into the inbox, and watches the dashboard. The build is autonomous; the *authoring and orchestration* around it is manual.

The goal: hand the system one spec, and have it author the project, provision a repo if needed, inject the work, and shepherd it through — without reimplementing the pipeline and without eroding the local-routing cost posture.

## 2. Decision

**Build a standalone Smithy Agent in `jarvis-forge` that sits ON TOP of the existing pipeline. It AUTHORS, PROVISIONS, INJECTS, and SHEPHERDS; it does not reimplement build, gate, or merge.** It is **not** the Council — the Council is a separate, later track (§2.6).

Five components:

### 2.1 Decomposer

`spec.md` → `project.md` + `phase-*.md`, generated via a **Claude cloud call** through forge's existing cloud-call path / Gateway adapter. Decomposition is once-per-project, rare, and the highest-leverage step — a bad breakdown corrupts the whole build — so it is the one place a cloud model earns its cost. Coding stays **local** via Aider, so the 79% local-routing target is preserved.

Output **MUST** conform to the existing project/phase MD format the pipeline already parses (ADR-0012): the agent reuses `parse_project_md` / `parse_phase_md` and does not invent a new schema. Per-call cost is tracked under the existing cost framework.

### 2.2 Polish gate

The Decomposer writes its draft `project.md` + phases to a **staging area**. A human reviews / edits / approves — including any "create repo X" plan — **before** anything is injected or provisioned. There is no autonomous repo-creation or injection without approval.

### 2.3 Provisioner

On approval, create the GitHub repo if required (`gh repo create`) and apply the JARVIS substrate (CI `ci.yml`, branch protection, `CLAUDE.md`). This is a privileged, side-effecting step, gated behind the polish approval (§2.2).

### 2.4 Shepherd

Watches the project's phases through the pipeline (`forge_phases`), surfaces `needs_input` / decisions, and reports status. It observes and routes; it does not build.

### 2.5 Decision-hook (the forward-compat seam)

Wherever the agent **makes a pick** — decomposition choices, a contested approach, preflight ambiguity — it routes through a **single abstraction**. Today the hook resolves via *single-model + surface-to-operator*. Later, finishing Council swaps **only the hook's backend** to the Council 3–4 lens (Solo Dev / AI Dev / Senior CI-CD / Enterprise Architect) — no rewrite of the agent. This seam is why building standalone-first creates no tech debt; it is the cross-repo follow-up ADR-0014 anticipates, wired per ADR-0010 when the contract exists.

### 2.6 Build order (recorded)

ADR → Decomposer (staging output) → Polish gate → Provisioner → Shepherd → (later) Council wire.

## 3. Scope / Deferred

- **v1 targets GREENFIELD projects** — a new repo from a spec. Decomposing **against an existing codebase's** `CLAUDE.md` + standards is a richer follow-up, not v1.
- **The exact `spec.md` input schema is PENDING** — it is defined when the Decomposer is scoped. Minimal shape: `title` / `goal` / `context` / `constraints` / `success criteria` / `target = new-or-existing`.

## 4. Consequences / Risks

- **New cloud-cost surface** (decomposition calls) — bounded (once per project) and recorded under the existing cost framework.
- **Provisioning is a privileged side effect** (repo creation, branch protection) — mitigated by the polish-gate approval; nothing side-effects before a human approves.
- **Council integration is deferred** — the decision-hook (§2.5) is the seam that makes it a backend swap, not a rewrite.

## 5. Alternatives considered

- **Fold authoring into the Council from the start** — rejected: blocks all authoring/orchestration on the (later) Council track; the decision-hook lets the agent ship now and absorb Council as a backend swap.
- **Extend the pipeline itself to author specs** — rejected: conflates the build machine with the layer above it; the pipeline reads `project.md` / `phase-*.md`, it should not also write them.
- **Autonomous provisioning on green decomposition** — rejected: repo creation and branch protection are privileged and hard to undo; the polish gate (§2.2) is the required human checkpoint.
