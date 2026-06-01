# ADR-0013 — Forge Autonomous-Pass Execution Model & Multi-Phase Merge-Gate (P0.2)

- **Number:** 0013
- **Status:** Proposed → Accepted on merge.
- **Repo / trait:** jarvis-standards · **P-trait** (Ken merges; raw-git + `jarvis_pr` or substrate per commit workflow).
- **Supersedes/extends:** ADR-0012 (project/phase data model). This ADR changes the runtime semantics of ADR-0012's state machine: the `pr → merged` transition.
- **Date:** 2026-05-19.
- **Origin:** smoke arc closeout (smokes #1–#8 + B1/B2 fixes #1271/#1272/#1280 + cleanup-tooling fix #1283). Decisions pressure-tested through 4 lenses (CIO / Solo Dev / EA / AI-dev).

---

## 1. Context

The smoke arc proved **single-phase, trivial, happy-path** MD-spec → Aider → Claude → governed-draft-PR, unattended, on production code (smoke #8: 8.4k-token additive MD, Aider succeeded, one phase, parked at `awaiting_merge`).

What is **NOT proven**: multi-phase projects, phase dependencies, the merge-gate, oversized phases, and Aider-failure handoff. These are precisely where AI-autonomous coding breaks. Before any autonomous pass — and well before jarvis-financial self-coding — the execution model must be locked and the foundational safety control (the merge-gate) built to spec.

ADR-0012 §3.3 state machine has `pr → merged | failed`. Today the runtime cascades `preflight → claude → pr → merged` in one function call on `execute_spec` success; `merged` is **local DB state only** — phase N+1 starts immediately regardless of actual GitHub PR state. For multi-phase projects this silently corrupts (phase N+1 builds on stale main). This ADR fixes that.

---

## 2. Decision — locked execution model (the 7 OQs)

| Ref | Decision |
|---|---|
| **OQ5 / P0.2** | Enforce phase `depends_on` at runtime. **"Done" = PR *merged*, read authoritatively from GitHub** — never inferred from local DB state. |
| **OQ2** | **Sequential across projects.** Encoded as an **enforced invariant** `max_concurrent_projects = 1`, not an emergent property. Parallel-across-projects deferred (revisit only after multi-phase is proven safe). |
| **P1.4** | **One Aider session per phase.** Plus: preflight enforces a **phase size/complexity bound** (see AC-5). |
| **P1.5** | **Always Aider → Claude** (uniform pipeline, no success-detection branch). Plus: a **defined Aider-failure handoff contract** (see AC-6). |
| **P1.6** | Council **deferred off the autonomous-pass critical path.** The proven loop runs without it (B-trait: CI+self-merge; P-trait: Ken merges). **Council / stronger governance is a PREREQUISITE for jarvis-financial self-coding** — financial does NOT self-code under single-AI-review only. |
| **OQ3** | `pipeline/orchestrator.py` council stubs deferred with P1.6 (council track). |
| **OQ4** | Orphaned `pipeline/reviewer.py` **quarantined or deleted** via a separate cleanup PR — not left silently (an autonomous AI pass may pattern-match to dead code). |

---

## 3. P0.2 — Multi-Phase Merge-Gate: design + acceptance criteria

The build that falls out of OQ5. ACs are binding; CC implements to these and stop-reports on any divergence.

- **AC-1 — `depends_on` enforcement.** Phase N+1 must not leave `inbox`/`preflight` until every phase in its `depends_on` is in terminal-merged state. No `depends_on` ⇒ linear order applies (phase k+1 depends on phase k implicitly within a project).

- **AC-2 — Authoritative 3-state PR read.** The gate reads PR state from the **GitHub API** (`gh`), never local DB:
  - **merged** → dependency satisfied; advance.
  - **open** → **park** the dependent phase in a wait state (do not advance, do not fail).
  - **closed-unmerged (rejected)** → **fail the project and surface to operator.** Never hang; never advance.

- **AC-3 — Hard-sync to merged HEAD before the next AI session.** Before spawning phase N+1's Aider/Claude session, the runner must hard-sync the working tree to the **post-merge main HEAD**. Branch-level gating is insufficient — the AI hallucinates against stale *context*, not just a stale branch.

- **AC-4 — Wait-state is first-class + glanceable.** The merge-wait park must emit a single-line, dashboard-visible reason, e.g. `phase-<N+1> blocked: awaiting merge of PR #<X> (phase-<N>)`. No log-spelunking to discover why an overnight run "did nothing."

- **AC-5 — Preflight phase-size bound.** Preflight rejects or flags phases whose size/complexity (e.g. `files_to_touch` count, spec length, blast-radius score) exceeds a configured budget an AI coder cannot reliably one-shot. (Smoke #8 was trivially small; this path is unproven.)

- **AC-6 — Aider-failure handoff contract.** "Always Aider→Claude" must explicitly define the path when Aider produces nothing/empty/broken: Claude must **detect** unusable Aider output and either (a) do the work from the spec itself, or (b) fail the phase cleanly — **never "polish garbage."** This path was never exercised in any smoke.

- **AC-7 — PR-state polling.** Define how the watcher checks PR state on its tick without GitHub rate-limit exhaustion (cache + backoff; do not raw-poll every 5s tick unbounded).

- **AC-8 — Supersede the local cascade.** The implicit `pr → merged` local-DB cascade in `_drive_phase_transitions_from_result` is removed/gated behind the authoritative GitHub read.

---

## 4. Consequences — accepted tradeoffs

- **Throughput reality (accepted, CIO finding #1).** Sequential + merge-gate + P-trait ⇒ **one phase per human merge.** Autonomous overnight on a P-trait repo (jarvis-financial **is** P-trait) is **not** "drop a 10-phase MD, wake to it done" — it is **one phase per Ken's merge approval**. This is the deliberate safety/throughput tradeoff. Explicitly accepted.

- **AI-error containment (the point).** "Done"=merged forces a human (P-trait) or CI+review (B-trait) checkpoint **between every AI-coded phase**, preventing compounding AI errors across phases. This is the single highest-leverage control before financial self-coding.

- **Single source of truth.** GitHub PR state is authoritative; the local-DB dual-truth divergence is eliminated.

- **Unproven paths remain (must be exercised before financial).** The merge-gate itself, oversized phases (AC-5), and Aider-failure (AC-6) are unproven. A **non-trivial multi-phase smoke** must exercise all three before jarvis-financial self-coding.

---

## 5. Scope boundary / follow-ons (NOT this ADR)

1. **P0.2 implementation** — CC, B-trait, references this ADR's ACs.
2. **Non-trivial multi-phase smoke** — 2+ dependent phases + merge-gate wait + an oversized phase + an Aider-failure injection. The real autonomy de-risk (smoke #8 only proved the toy case).
3. **Council buildout** — its own track (Stage 1 spec'd; ADR-0004 GitHub-API integration). Deferred here.
4. **Parallel-across-projects** — deferred; revisit only after multi-phase proven.
5. **jarvis-financial self-coding governance prerequisite** — financial requires council / stronger-than-single-AI-review governance, decided before it self-codes.

---

## 6. Relationship to ADR-0012

ADR-0012 defines the project/phase **data model** and state machine structure. This ADR changes the **runtime semantics** of the `pr → merged` transition: that transition now requires (a) `depends_on` satisfied and (b) authoritative GitHub *merged* state, plus the `closed-unmerged → fail` and `open → park` branches (AC-2). The implicit local-DB cascade is superseded (AC-8). No ADR-0012 schema change is implied; if a `depends_on` or wait-reason column is absent, that is an ADR-0012 amendment to be filed alongside P0.2.

---

*Pressure-tested 4-lens (CIO / Solo Dev / EA / AI-dev), 2026-05-19. All 7 decisions held; findings #1–6 folded in as §3 ACs and §4 accepted tradeoffs.*
