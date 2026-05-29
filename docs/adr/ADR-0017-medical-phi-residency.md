# ADR-0017 — Medical PHI Data Residency: Local-Only Boundary

**Status:** PROPOSED
**Date:** 2026-05-29
**Home:** jarvis-standards (shared sequence) · applies to jarvis-medical
**Owner:** Ken (medical = P-trait)
**Relates:** ADR-0016 (scoring engine, deferred persistence §5) · ADR-0010 (cross-repo bridge)
**Driven by:** discovery that Brain's shared memory pool feeds cloud LLM retrieval with **no classification gating** — `48_PHI` is not honored.

---

## 1. Context (discovery)
- Brain has **no `POST /v1/memory` handler** — only a GET stub. Medical writes currently 405 (silent integration break).
- Brain's memory pool (semantic/episodic/working) is retrieved **verbatim into cloud LLM prompts** via the Gateway (Claude/Gemini/Perplexity) for any non-`local` mode, with **no PHI/classification filter** (`ask.py`, `chat.py`, `router.py`).
- The store function records **no classification** → `48_PHI` cannot be segregated.
- Therefore Sandbox-side route labels (`CLOUD` / `OLLAMA` / `48_PHI`) carry **zero protective meaning** downstream.
- Asset at risk: kids' (Ryleigh 8, Sloane 5) + family PHI. Cloud egress of PHI is prohibited.

## 2. Decision

### 2.1 Hard boundary (invariant)
**Medical PHI is stored and processed on Sandbox only. It is NEVER written to Brain's shared memory pool (`/v1/memory`) or any path that can reach cloud retrieval.** Non-negotiable, enforced fail-closed. This **supersedes** the README's "residency: Brain Postgres" claim for PHI.

### 2.2 Local store = system of record for medical PHI
Medical PHI (panels/observations, scores, reports, audit) lives in a **durable, local, encrypted-at-rest store on Sandbox** — gitignored, outside the repo tree (consistent with the already-merged report-gen path `~/.local/share/jarvis-medical/`). This is the "filing cabinet" deferred in ADR-0016 §5.
- **Recommended:** SQLite under `~/.local/share/jarvis-medical/`, at-rest encryption (SQLCipher *or* OS-level encrypted dir), `chmod 600`. [confirm — §6]
- Tables: panels/observations · scores · report index · `phi_redactions` audit (also closes the phase-11 `:memory:` 6-yr retention gap).

### 2.3 AlphaPort / Brain role under the boundary
- `AlphaPort.write_memory` **must not** carry PHI. PHI content → local store, never Brain.
- phi_stripper routing changes: **any** content with PHI redactions (any confidence) → LOCAL. `ROUTE_BLOCK` (child-profile) stays. `CLOUD`/`OLLAMA` re-read as "Brain only if zero PHI." [confirm — keep a non-PHI Brain channel, or drop Brain memory for medical entirely? §6]
- This makes the `ROUTE_OLLAMA` no-op **moot** — superseded by the local-store boundary.

### 2.4 Fail-closed
Any attempt to send PHI-bearing content to Brain raises `BlockedEgressError` (extend the existing child-profile block to **all** PHI bound for the shared pool). Local store unavailable → **block + surface**, never fall back to Brain/cloud.

## 3. Cross-repo dependency (platform)
Brain ignoring classification is a **platform-wide** gap — any module (family, etc.) writing sensitive data to Brain memory is exposed. Tracked as a cross-repo TD against jarvis-alpha. **Medical does not wait on it** — A self-protects regardless.

## 4. Consequences
**+** Medical PHI provably never reaches cloud — boundary enforced on Sandbox, not reliant on Brain honoring labels.
**+** Resolves ADR-0016's deferred persistence + the phase-11 audit-retention gap.
**+** Aligns with already-merged report-gen (local-only) and the pure scoring engine (no persistence).
**−** Medical forgoes Brain's shared-memory/RAG for PHI (acceptable — PHI must not sit in a cloud-exposed pool).
**−** Requires redirecting the AlphaPort PHI path → local store (implementation follows this ADR).
**−** Needs encryption-at-rest + a backup/retention runbook.

## 5. Deferred (follow-up)
- Intake wiring (how panels reach the local store).
- Backup/restore runbook (encrypted local → Unraid encrypted volume, **never** Brain memory).
- Trends (now unblocked by a durable local store — separate work).

## 6. Open confirmations
1. Store encryption: **SQLCipher** vs OS-level encrypted dir + plain SQLite?
2. Keep a **non-PHI Brain channel** (health signals) or drop Brain memory for medical entirely?
3. Backup target for the encrypted store (Unraid encrypted volume)?

## 7. Enforcement / tests
- Invariant test: no medical path sends PHI-bearing content to AlphaPort/Brain (mirror report-gen's import-guard + a "redactions present → local-only" assertion).
- Fail-closed test: PHI → Brain raises `BlockedEgressError`; local-store-down → block, never Brain/cloud fallback.

---
*Boundary decision locked (A). Implementation follows. Engine + reports already align.*
