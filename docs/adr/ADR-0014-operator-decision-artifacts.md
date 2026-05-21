# ADR-0014: Operator Decision Artifacts

- **Status:** Proposed
- **Date:** 2026-05-21
- **Author:** Ken (architect), Claude (draft)
- **Supersedes:** none
- **Related:** ADR-0012 (project/phase model), ADR-0013 (merge gate)

## Context

Forge makes pipeline decisions at every stage transition — park (cost
cap, RAM pressure), needs_input (preflight questions), recovery_handoff
(AC-6 Aider failure), escalate (high risk score), chain_blocked
(ADR-0013 AC-2), skipped (cascade failure).

Today these are logged piecemeal across `activity_events`, log files,
and `forge_phases.wait_reason`. There is no single artifact capturing
"WHY did this decision fire?" in a re-readable form. The
operator-replay use case — "Why did phase 3 of my financial project
pause overnight?" — cannot be served without log archaeology.

`pipeline/schemas/council_decision.py` exists in forge but is
unsuitable: it models a 4-lens chat-review artifact
(solo_dev/cio/ea/big_tech), not a pipeline decision. A read-only audit
of jarvis-council on 2026-05-21 (HEAD 123aafb) confirmed the Council
repository is docs-only at this stage — 5 ADRs, no Python source, no
`schemas/` directory. Council's planned schema is a 7-specialist + CIO
aggregate verdict emitted via GitHub PR comments — fundamentally
different shape and subject from forge's pipeline decisions. A
cross-repo decision contract therefore cannot be locked today.

## Decision

Add a forge-internal `OperatorDecision` schema + best-effort writer +
reader, distinct from `CouncilDecision`. Land in two PRs.

### Schema — `pipeline/schemas/operator_decision.py`

```python
@dataclass(frozen=True)
class OperatorDecision:
    id: str                            # UUID4 hex — primary key
    project_id: str                    # tie-back
    phase_id: str                      # tie-back
    decision_type: str                 # park | needs_input | recovery_handoff
                                       #   | escalate | chain_blocked | skipped
    actor: str                         # which subsystem fired:
                                       #   cost_estimator | preflight | risk_scorer
                                       #   | ac6 | merge_watcher | project_runner
    timestamp: str                     # ISO 8601 UTC

    # Why
    reason: str                        # short label (<100 chars)
    detail: str                        # full narrative (<2 KB)

    # State at decision time
    triggered_at_stage: str            # phase's stage when this fired
    triggered_by_event: str | None     # soft FK to activity_events

    # Threshold decisions (cost-park, risk-escalate)
    threshold_metric: str | None       # cost_usd | risk_score | stale_seconds | None
    threshold_value: float | None
    actual_value: float | None

    # Routing
    next_stage: str | None             # where decision routed the phase

    # Operator interaction (needs_input only)
    operator_question: str | None
    operator_answer: str | None        # filled when operator responds
```

Validator `validate_operator_decision(d)` enforces:
- `id` matches UUID4 format
- `decision_type` and `actor` in allowed sets
- `timestamp` parses as ISO 8601
- Per-type required fields:
  - park, escalate → `threshold_metric` + `threshold_value` + `actual_value`
  - needs_input → `operator_question`
  - recovery_handoff → `next_stage`

### Writer — `pipeline/operator_decisions.py`

- `write_operator_decision(d, *, runs_dir)` — best-effort atomic write
- Path: `runs/<project_id>/<phase_id>/decisions/<id>.json`
- Atomicity: temp file + `os.rename`
- Failure mode: log + return None, never propagates (matches
  `_maybe_generate_run_md` pattern)
- One file per decision; immutable after write

### Reader — `pipeline/operator_decisions.py`

- `read_operator_decisions(project_id, phase_id, runs_dir)` returns
  `list[OperatorDecision]` sorted by timestamp ASC
- Used by `pipeline/run_md.py::_render_decisions` (already exists at
  line 324; rewire to read from artifact files)

### Producer call sites — 6 identified

| Site | Decision type | File:line (approx) |
|---|---|---|
| Dependency pre-gate chain_blocked cascade | chain_blocked | project_runner.py:1182 |
| AC-6 PR-B Aider failure handoff | recovery_handoff | project_runner.py:2056-2170 |
| Cost-park gate | park | project_runner.py:1326-1362 |
| Preflight needs_input fire | needs_input | preflight.py |
| Risk-scorer high-risk gate | escalate | risk_scorer.py |
| Cascade failure to skipped | skipped | project_runner.py (_cascade_failure) |

### run.md integration

`run.md` Decisions section renders each `OperatorDecision` as:
- One-line summary: `<timestamp> · <decision_type> · <reason>`
- Relative link to JSON: `[detail](decisions/<id>.json)`

## Consequences

**Positive**
- Operator can replay overnight unattended runs end-to-end
- Forensics for "why did X happen" become trivial (read JSON, no log archaeology)
- Foundation for programmatic decision-replay across projects
- Best-effort writes keep the pipeline robust — disk fault does not break a phase
- Clean separation from `CouncilDecision` — Council can ship its own schema
  independently when ready

**Negative**
- ~5–10 extra files per phase (artifacts dir)
- 6 producer sites need wiring (deferred to PR-B)
- Cross-repo integration with future Council decisions needs a follow-up
  ADR when Council's schema exists

## Alternatives considered

1. **Extend `CouncilDecision`** — rejected: load-bearing field mismatch
   with Council's planned 7-specialist + CIO model; rename would cascade
   through forge's existing 4-lens chat usage.
2. **DB-only (no filesystem artifacts)** — rejected: breaks the
   round-trip refinement workflow ("operator brings the artifact to chat").
3. **Inline in run.md (no separate JSON)** — rejected: makes programmatic
   replay impossible; un-parseable.
4. **Transactional write semantics (block transitions on write failure)**
   — rejected: pipeline robustness > artifact reliability; matches
   established `_maybe_generate_run_md` pattern.

## Implementation notes

Land in two PRs to keep concerns separate:

- **PR-A — Schema + writer + reader + unit tests** (~0.5 session, B-trait)
  - New module `pipeline/schemas/operator_decision.py`
  - New module `pipeline/operator_decisions.py`
  - Unit tests: schema validation, atomic write, read-back round-trip,
    per-type required-field enforcement
  - No producer wiring — keeps PR-A purely additive

- **PR-B — Wire 6 producer call sites + integration tests + run.md update**
  (~0.5–1 session, B-trait)
  - Each producer site gets a single `write_operator_decision(...)` call
    after its existing transition
  - run.md Decisions section reads from artifacts
  - Integration test: trigger cost-park, assert artifact exists at correct
    path, parses back to `OperatorDecision`, run.md links to it

## Acceptance criteria

- `OperatorDecision` schema + validator + writer + reader land cleanly
- All 6 producer sites emit decisions when their gates fire
- run.md Decisions section renders artifact links
- No regression in existing 1007 tests (post-revert baseline)
- B-trait self-merge protocol; ADR-0005 trailers on every commit
