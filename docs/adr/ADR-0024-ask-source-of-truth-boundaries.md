# ADR-0024: Establish Ask Source-of-Truth Boundaries

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** Ken Haas, Codex
- **Supersedes:** N/A
- **Related:** ADR-0010 Cross-Repo Runtime Bridge Contract, docs/ASK_SOURCE_OF_TRUTH.md

---

## Context

JARVIS already has working Ask behavior in two places:

- `jarvis-helm` owns the AT-0/operator Ask workspace. It uses Alpha for chat
  completions, threads, memory, Beacon web evidence, research reports, voice
  input, and avatar response state.
- `jarvis-family` owns the parent/child-safe Ask path. It uses Family API
  routes, role-aware safety checks, answer filtering, parent-only document
  sources, and a child-safe UI.

Adding a third Ask UI in `jarvis-alpha` would duplicate behavior and make it
unclear which app owns future Ask changes.

## Decision

JARVIS will treat `jarvis-helm` as the source of truth for operator Ask and
`jarvis-family` as the source of truth for family-safe Ask. `jarvis-alpha` is a
backend/control-plane provider for operator Ask, not an Ask frontend owner. The
machine-readable source of truth is `contracts/ask_surfaces.v1.json`.

## Consequences

### Positive

- Helm's working operator Ask features are preserved rather than reimplemented.
- Family's child/parent safety behavior remains isolated and testable.
- Alpha can keep improving chat completions, Beacon, memory, approvals, and
  audit without owning another chat surface.
- Future agents have a contract to consult before moving Ask behavior.

### Negative

- Cross-repo changes now require updating a standards contract before moving
  Ask ownership.
- Helm and Family remain separate surfaces instead of a single shared component
  until a deliberate extraction is designed.

### Neutral

- Shared UI/code may still be extracted later, but only after the contract is
  updated and both existing test suites remain green.

## Sovereignty First compliance

No new external dependency is introduced.

| Component | Tier | Fallback |
|---|---|---|
| Ask source-of-truth contract | Internal standard | Existing Helm and Family behavior remains in place |

## Alternatives considered

### Option A - Put Ask UI in Alpha

Rejected. Alpha already owns the backend/control-plane pieces. Adding a full
Ask UI would create a third source of truth and duplicate Helm.

### Option B - Merge Family Ask into Helm

Rejected for now. Family Ask has child-specific safety and document-source
rules that should not be mixed into the operator workspace without a deliberate
migration.

### Option C - Keep both surfaces but document no boundary

Rejected. That leaves future agents free to copy the working pieces into a
third app again.

## Reversal conditions

1. Helm and Family agree on a shared Ask component/package with equivalent
   safety and evidence tests.
2. Alpha becomes the explicit product owner for an operator UI, with Helm
   retired or reduced to a shell.
3. A new cross-repo UI package exists and both apps consume it directly.

## References

- `contracts/ask_surfaces.v1.json`
- `docs/ASK_SOURCE_OF_TRUTH.md`
- `jarvis-helm/src/ask/AskWorkspace.tsx`
- `jarvis-helm/src/ask/alphaAskClient.ts`
- `jarvis-family/api/routes/ask.py`
- `jarvis-family/api/services/ask_safety.py`
- `jarvis-family/ui/src/components/ask/AskChat.tsx`
