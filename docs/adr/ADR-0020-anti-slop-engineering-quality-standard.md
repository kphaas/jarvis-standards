# ADR-0020 — Anti-Slop Engineering Quality Standard (Enterprise Baseline)

**Status:** PROPOSED
**Date:** 2026-05-30
**Companion:** ADR-0019 (Discovery-First Context Protocol)
**Applicability:** ALL repos enrolled in autonomous codegen. No exemptions. Regulated repos stack compliance overlays on top.

---

## 1. Context

"Highest standard, no shortcuts" needs a concrete, checkable definition or it can't be enforced. AI slop = plausible-but-low-quality code: stubs, swallowed errors, untested branches, duplication, hallucinated APIs, ignored conventions, speculative over-engineering. External validation reinforces one principle: the review model is NOT a substitute for deterministic verification — deterministic gates (lint, types, tests, scanners) do what they can; the LLM judges only what they cannot.

## 2. Decision — the quality floor (every bar is a gate)

Legend: [CI] deterministic gate (blocks merge, free) · [LLM] review-stage judgment · [CI+LLM] both. Prefer deterministic; never spend review tokens on what CI checks for free.

1. Complete [LLM] — no UNTRACKED stubs (TODO/FIXME/pass-stub/NotImplementedError). Deferring allowed only via a filed TD with its ID referenced inline, e.g. TODO(TD-###). Can't finish and can't defer cleanly → needs_input.
2. Real error handling [CI+LLM] — no bare except / silent swallow (linter flags; reviewer judges meaningfulness). Match the repo's pattern.
3. Tested [CI] — new behavior gets tests; fixes get a regression test; coverage gate on touched paths.
4. Conforming [LLM] — match the repo's existing conventions (discovered first). No second way to do an existing thing.
5. Verified APIs [LLM] — never call a symbol/endpoint/column unconfirmed by discovery. No hallucinated interfaces.
6. DRY [LLM] — reuse helpers found in discovery; no copy-paste reimplementation.
7. Edge cases [LLM] — handle empty/None/error inputs, not just the happy path.
8. No over-engineering / YAGNI [LLM] — minimal change meeting acceptance criteria; no speculative abstraction.
9. Security invariant [CI] — no hardcoded secrets/IPs/tokens/certs; secrets via repo get_secret(); secret + static-analysis scans block on critical severity.
10. Observable [CI+LLM] — use the repo's structured logging; no leftover print/debug (linter + reviewer).
11. In-scope [CI+LLM] — touch only files_to_touch; diff-scope check + reviewer judgment; no drive-by refactors.
12. Commit hygiene [CI] — ADR-0005 trailers; no Co-authored-by on AI commits; title ≤70 chars (hook/CI check).
13. Documented interfaces [LLM] — docstrings on public functions/APIs; non-obvious decisions commented.
14. Migration-safe [LLM] — schema/API changes reversible and backward-compatible.
15. CI-green required [CI] — formatter + linter + type-check + tests + scanners all pass before merge; branch protection enforces.

## 3. Definition of Done

Done only when: complete (no untracked stubs) · conforming · discovered/verified · in-scope · AND all CI gates green (format/lint/type/test/coverage/secret/security). Anything less → rework or needs_input.

## 4. Review-stage gate = structured artifact

The Claude review stage emits a pass/fail record PER LLM bar (not prose), with the discovery note attached. Any fail → reject (no merge) or needs_input. This record is the auditable review artifact.

## 5. Compliance Overlays (trait-scoped — inject only where the trait applies)

These are engineering controls that SUPPORT HIPAA / FSI — NOT legal compliance certification. Actual compliance requires policies, BAAs, audits, and legal review beyond code. This standard is not a compliance authority.

### 5.1 HIPAA overlay — jarvis-medical (PHI)

- PHI encrypted in transit and at rest.
- No PHI in logs, errors, traces, or test fixtures — ever. Synthetic / de-identified data only.
- Least-privilege access; audit-log every PHI read/write.
- PHI must not leave the trust boundary without explicit, gated de-identification; on uncertainty, fail closed (do not egress).
- Data minimization; secure deletion.
- The repo-context map (companion ADR) must be PHI-scrubbed before it reaches the review model.

### 5.2 FSI overlay — jarvis-financial

- Immutable audit trail on every financial action/decision.
- Idempotent money operations; no partial or silent failure on money paths.
- Kill-switch / circuit-breaker + pre-trade validation gates honored (per jarvis-financial's kill-switch / pre-trade governance ADR).
- Data-integrity and reconciliation checks; segregation of duties.
- No financial credentials/keys in code.

## 6. Implementation Contract — forge + Smithy

### 6.1 Injection (binding to the digest mechanism)

- Every enrolled repo's CLAUDE.md carries a canonical `## Codegen Rules` block: baseline bars always; HIPAA/FSI overlay only for the matching trait.
- The forge Aider digest ALWAYS injects the `## Codegen Rules` block verbatim (within budget, keyword-independent) — so the floor reaches the weakest model, where slop originates.
- The Claude review stage applies the [LLM] bars and emits the structured gate artifact.
- CI (substrate ci.yml) enforces the [CI] bars + branch protection. Deterministic gates not yet in substrate ci.yml (e.g. type-check, coverage, security scan) are added as part of implementation.
- Propagated via substrate so every repo carries the block uniformly.

### 6.2 Smithy (new repos)

New repos are scaffolded with the `## Codegen Rules` block (baseline + overlay if regulated) already in CLAUDE.md — born compliant.

## 7. Consequences

- Slop becomes a gate failure, not a merge.
- Review tokens spent only on judgment CI cannot do — cheaper and more reliable.
- Requires per-repo `## Codegen Rules` blocks + substrate propagation + a structured review-artifact format + CI gate additions.
