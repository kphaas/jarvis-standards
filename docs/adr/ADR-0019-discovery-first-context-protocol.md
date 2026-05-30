# ADR-0019 — Discovery-First Context Protocol for Autonomous Codegen

**Status:** PROPOSED
**Date:** 2026-05-30
**Companion:** ADR-0020 (Anti-Slop Engineering Quality Standard)
**Applies to:** all repos enrolled in autonomous codegen (forge pipeline + Smithy)

---

## 1. Context

Autonomous codegen (Aider draft → Claude review) must understand existing code before editing, or it produces conflicting, duplicate, or wrong code. The review model (Claude Code) costs real tokens per file read; the draft model (Aider) runs local and free. Naive "read the repo every phase" is both a correctness need and a cost trap. Industry practice (Aider repo-map, code-graph tooling) and external validation converge on: a cached structural map + bounded blast-radius reads + cheap-model-first / expensive-model-last.

## 2. Decision

### 2.1 Discovery is mandatory and read-only before any edit

Verify reality by reading — never assume signatures, columns, config keys, or patterns from memory or spec wording. Reuse helpers found in discovery. Record a short discovery note (what was read/verified; any conflict).

### 2.2 Cost asymmetry drives the design

- Aider (local, free $): fed generously — its own tree-sitter repo-map + full discovery directive.
- Claude review (real $): fed a compact curated packet only. Never live-reads the whole repo.

### 2.3 Tiered, cached context

- Tier 1 — cached repo map: local tree-sitter-derived structural map (signatures + dependency edges), COMPRESSED and TOKEN-CAPPED (never a full-repo pack). Refreshed incrementally (changed files only).
- Tier 2 — bounded blast-radius reads: live-read only files_to_touch + their direct dependencies, helpers, interfaces, tests, config. Expand to callers/callees ONE hop only when a signature or contract changes. Stop unless evidence shows broader impact.
- Tier 3 — curated review packet (what Claude sees): Tier-1 map slice + Tier-2 files + Aider's draft diff + applicable tests + the repo's `## Codegen Rules`. Nothing else.

### 2.4 Freshness contract

The cached map records the commit SHA it was built from. At phase start, compare to HEAD; on mismatch, incrementally rebuild before use. A stale map is never served — rebuild or block, fail loud.

### 2.5 Fail-closed-bounded fallback

If map generation fails (parse error, OOM), fall back to Tier-2 bounded reads only and log loudly. Never fall back to whole-repo reads; never proceed silently.

### 2.6 Local-only constraint

All code intelligence runs local (private mesh + PHI + gateway-only egress). No cloud code-graph/indexing services. We deliberately skip embeddings/RAG for candidate selection: it is weak on exact contracts and dependency truth — what discovery requires — and the deterministic dependency graph is more precise at our scale.

### 2.7 Scope = write-jail

Blast radius is also the write boundary: modify only files_to_touch (existing hard cap). Discovery scope and edit scope are the same set.

### 2.8 Stop on conflict (hard gate)

If discovery shows the spec conflicts with reality (referenced symbol/column/endpoint absent or different), the phase transitions to needs_input with the specific conflict. Never improvise around it.

## 3. Enforcement (hybrid)

- Aider draft stage: discovery directive injected via the digest (best-effort, local model).
- Claude review stage (the real gate): consume the discovery note + curated packet, confirm the draft was written against verified reality, and gate any spec-vs-reality conflict to needs_input before approving. No approval without discovery.

## 4. Implementation Contract — forge + Smithy

### 4.1 forge (existing repos) — B-trait, separate follow-up PR

- A local generator (e.g. Repomix in compression mode + token cap; tool-agnostic — named as impl detail, swappable without a new ADR) builds the Tier-1 map on Sandbox, secret-scanned, and PHI-scrubbed for HIPAA-trait repos (the map is fed to Claude = egress).
- Cached locally on Sandbox; NOT committed (avoids VCS churn/staleness). Optional committed docs/repo-context.md snapshot for audit only.
- Refresh on commit / phase-start, incremental, SHA-stamped.
- Claude-review stage assembles the Tier-3 packet instead of live full-repo reads.
- Propagated via substrate as a capability trait (e.g. HAS_REPO_CONTEXT) so all enrolled repos get it uniformly — not forge-only.

### 4.2 Smithy (new repos from a spec) — greenfield optimization

- Drop the standards bundle: CLAUDE.md with the canonical `## Codegen Rules` block (baseline + trait overlay if regulated) + an architecture/invariants seed.
- Emit the initial Tier-1 map from the build plan it already holds (no cold-start parse).
- Repo is born discovery-ready and standards-compliant; first phase needs no cold parse.

## 5. Consequences

- Claude token spend per phase = compact map slice + bounded files + diff — bounded, not repo-sized.
- Conflicts surface as operator questions, not silent wrong code.
- No new pipeline stage; folds into the existing two-stage flow + needs_input gate.
- Adds a local map generator + a freshness / secret / PHI-scrub guard to maintain.
