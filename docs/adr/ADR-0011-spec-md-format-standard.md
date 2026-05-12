# ADR-0011: Spec.md Format Standard for Forge Pipeline Adoption

**Repo:** `jarvis-standards`
**Status:** Accepted
**Date:** 2026-05-12
**Author:** Ken Haas (drafted by Claude Opus 4.7)
**Supersedes:** —
**Related:**
- ADR-0005 (this repo) — Multi-writer coordination (same commit-trailer pattern; specs flow through the same branching model)
- ADR-0008 (this repo) — Structlog as Python logging standard (parser + watcher emit structured logs at every stage)
- ADR-0009 (this repo) — Ruff-S as static security standard (lint gate within the pipeline a spec triggers)
- ADR-0010 (this repo) — Cross-repo runtime bridge contract (sibling pattern: bridges are runtime, specs are pre-runtime)
- `jarvis-forge/pipeline/spec_md.py` — canonical parser
- `jarvis-forge/docs/SPEC_FORMAT.md` — full implementation reference

---

## 1. Context

### 1.1 What this ADR is

`jarvis-forge` implements the **walk-away development loop**: drop a
spec.md into `specs/inbox/`, an inbox watcher (LaunchAgent) picks it up,
the AutoCode pipeline runs (preflight → claude_runner → auto_reviewer →
auto_pr_opener), and a draft PR lands on GitHub. The loop is fully
operational as of 2026-05-12.

The loop expects spec.md files in a specific format, currently defined
*only* in `pipeline/spec_md.py`. Other modules that adopt the same
pipeline shape (Council, Family, future modules) will need to emit
specs Forge can consume — and Forge will need to emit specs Council can
consume in turn.

Without a documented cross-repo standard, each module risks diverging:
different field names, different required sections, different
validation semantics. Within months we'd have an N×N adapter problem.

### 1.2 Why now

The cost of *not* documenting this is concrete and measured. The
2026-05-12 walk-away smoke session required **six retries** to land a
valid spec — not because the format is complex, but because the only
reference was source code. Each retry surfaced a different gotcha:
H2 vs H1 headers, frontmatter `acceptance_criteria` (ignored) vs body
`# Acceptance Criteria` (the actual source), plain bullets vs `- [ ]`
checkboxes, etc. Two of the failed runs left `.error.json` sidecars
that still exist in the operator's `specs/failed/` directory.

If a sole human operator hits six retries today, an arbitrary downstream
module ingesting Forge-style specs will hit thirty. This ADR closes the
loop before the second consumer arrives.

### 1.3 Scope

In scope:
- Frontmatter schema (required + optional fields, value spaces).
- Body section grammar (H1-only, case-insensitive, hyphen/space/underscore
  interchangeable).
- Required body sections (`# Description`, `# Acceptance Criteria`).
- Validation invariants any conforming parser must enforce.
- The 4-digit `ADR-XXXX` regex for the `standards` field.

Out of scope (deliberately, for separate ADRs if/when they're needed):
- Runtime envelope between watcher and AutoCode (internal to Forge).
- Sidecar JSON shape (operational artifact, not a spec format concern).
- Output-md (audit md) frontmatter — covered downstream by the
  `auto_pr_opener` and `output_md` modules.
- Multi-spec batch formats.

---

## 2. Decision

The format defined by `jarvis-forge/pipeline/spec_md.py` is the
**canonical Forge spec format**. Any module adopting the Forge
walk-away pipeline (whether by importing the parser, vendoring it, or
re-implementing it) **MUST** conform to the invariants below. The full
implementation reference lives at
`jarvis-forge/docs/SPEC_FORMAT.md`; this ADR is the policy.

### 2.1 Format invariants

1. **YAML frontmatter** at the top of the file, delimited by `---`
   lines. Top-level **must parse to a YAML mapping** (an object); a
   scalar or list at the top level is invalid.

2. **Required frontmatter fields:**
   - `title` — non-empty string.
   - `target_repo` — non-empty string.

3. **Constrained frontmatter fields:**
   - `priority` ∈ {`P1`, `P2`, `P3`} (default `P2`).
   - `estimated_complexity` ∈ {`small`, `medium`, `large`} (default `small`).
   - `cost_cap_usd` is a number, `> 0` and `<= 50.00` (default `1.50`).
   - `standards`, when present, is a list of strings, **each matching
     the regex `^ADR-\d{4}$`** (4-digit zero-padded).
   - `target_branch`, when present, is a string (default `main`).

4. **Body grammar:**
   - Section headers are **H1 only** (`# …`). H2 and deeper are
     ignored by the section parser.
   - Header matching is **case-insensitive** and treats hyphens,
     spaces, and underscores as equivalent
     (`# Acceptance Criteria` ≡ `# acceptance-criteria` ≡ `# acceptance_criteria`).

5. **Required body sections:**
   - `# Description` — free-form prose. Empty descriptions are
     parser-accepted but operationally useless (the runner has no
     other source of intent).
   - `# Acceptance Criteria` — at least one entry using `- [ ]`
     checkbox syntax. Plain bullets are silently filtered out and do
     not count as criteria.

6. **Optional body sections** (free-form bullets):
   - `# Constraints`
   - `# Files to Touch`

7. **Validation timing:** all of the above MUST be enforced at parse
   time. A spec failing any invariant MUST be rejected with a single
   error message aggregating all violations, NOT silently coerced
   to defaults beyond those listed in §2.1(3).

### 2.2 Identity

A spec's `id` is operator-supplied or auto-generated by the parser
(first 6 hex characters of the file's SHA-256, prefixed `F-`). IDs
need not be globally unique across modules; collision resolution is
the consumer's responsibility (Forge handles this in `autocode.py`
via `_generate_spec_id` + retry).

---

## 3. Consequences

### Positive

- **Onboarding is copy-paste.** A new module gets `specs/templates/example.md`
  from Forge and is producing valid specs in minutes, not weeks.
- **Validation errors at parse time.** Operators see a single error
  message naming the violations; no debugging mid-pipeline.
- **One reference, one parser.** Future modules can either import
  `pipeline.spec_md.parse_spec_md` directly or re-implement against
  this ADR. Either way, conformance is testable.
- **Cross-repo orchestration becomes tractable.** Council and Family
  can author specs Forge consumes, and vice versa, without per-pair
  adapter shims.

### Negative

- **Format changes require coordinated updates** across:
  Forge parser → `SPEC_FORMAT.md` → this ADR → downstream consumers.
  Mitigated by validation being strict — additions that ignore
  unknown fields are safe; renames or removals are breaking.
- **Legacy non-conforming specs (if any)** need migration. As of
  2026-05-12 there are zero non-conforming specs in production; the
  cost is theoretical until a second adopter exists.
- **Strict checkbox syntax for criteria can surprise users** who
  expect plain bullets. The `SPEC_FORMAT.md` Common Mistakes section
  documents this explicitly, but the surprise cost is real until the
  format is in muscle memory.

### Neutral

- The format is **Markdown + YAML** — both ubiquitous, both
  human-editable, both editor-supported. No proprietary parsing.
- The 4-digit `ADR-XXXX` regex aligns with the existing ADR file
  naming in this repo (`ADR-0001-…` through `ADR-0011-…`).

---

## 4. Alternatives considered

### Option A — JSON spec files

A JSON envelope with all fields including criteria as an array.
Rejected: humans write Markdown, not JSON; criteria-as-checkboxes
is a low-cost ergonomic win; YAML frontmatter + Markdown body is the
established pattern in the ecosystem (output_md uses it too).

### Option B — Pure YAML (no body sections)

Frontmatter-only spec with `description`, `acceptance_criteria`,
`constraints`, `files_to_touch` all in the YAML mapping. Rejected:
prose in YAML quickly becomes painful (escape rules, line-folding,
quoting). The current split — structured metadata in frontmatter,
prose in body — matches how humans actually think about specs.

### Option C — Defer until second consumer exists

Wait to standardize until Council or Family is actually adopting the
pipeline. Rejected: the cost-of-no-standard is already realized (six
retries during the 2026-05-12 smoke). The standard is small, the
parser exists, and writing it down now is cheaper than retroactively
unifying two implementations later.

---

## 5. Reversal conditions

This decision should be revisited if any of these occur:

1. A second module's natural spec shape diverges substantially from
   this format, and the divergence is *more* informative than the
   current schema (e.g. a different field set is mandatory for that
   domain).
2. The 4-digit `ADR-XXXX` regex runs out — i.e. ADR-9999 is reached.
   (Not a 2026-decade concern.)
3. The parser at `jarvis-forge/pipeline/spec_md.py` materially
   changes its behavior. In that case the ADR + `SPEC_FORMAT.md`
   MUST be updated in the same PR, or the parser change is rejected.

---

## 6. References

- `jarvis-forge/pipeline/spec_md.py` — canonical parser, returns
  validated `SpecMd` dataclass.
- `jarvis-forge/docs/SPEC_FORMAT.md` — full implementation reference
  with Quick Start, schema table, Common Mistakes side-by-side, run
  lifecycle diagram.
- `jarvis-forge/specs/templates/example.md` — ready-to-`cp` starter.
- `jarvis-forge/pipeline/inbox_watcher.py` — the consumer that drives
  the walk-away loop end-to-end.
- ADR-0005 (this repo) — Multi-writer coordination. The same
  `X-Machine:` / `AI-Agent:` / `AI-Model:` commit trailers apply to
  PRs produced from valid specs.
