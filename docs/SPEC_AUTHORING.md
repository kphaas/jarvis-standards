# Spec authoring — project & phase markdown

How to write a multi-phase project drop that the [jarvis-forge](https://github.com/kphaas/jarvis-forge)
pipeline accepts and runs end-to-end. This is the **teaching companion** to
`forge_spec_lint.py` — the linter *enforces* the schema; this doc *explains*
it so you don't learn the grammar by trial and error (the way
`phase-11-phi-stripper` burned four authoring cycles).

> **Status:** canonical reference. The authoritative grammar lives in
> jarvis-forge source (cited throughout). When the parsers change, this doc
> follows; it never invents rules the code doesn't enforce.

---

## TL;DR

1. A project drop is a directory: `project.md` + `phases/*.md` + a `.ready` sentinel.
2. `project.md` carries YAML frontmatter; `## Phases` body bullets must be **bare phase ids** — no decorators.
3. Each phase needs `# Description` and `# Acceptance Criteria` as **H1** (`#`), not H2 (`##`).
4. Acceptance criteria are `- [ ]` **checkboxes** — numbered lists are silently dropped.
5. Lint before you drop: `python scripts/forge_spec_lint.py projects/inbox/<your-id>`.

---

## The two-bouncer problem (why lint exists)

A spec passes through **two different validators** on its way to execution, and
they do not agree. That disagreement is the single biggest source of authoring
churn.

| Bouncer | Where | Strictness | Source |
|---|---|---|---|
| **1 — static** | `forge_spec_validate.py` (run by hand, by you) | **Lenient** — stops at `validate_phase`, which *accepts an empty `# Description` and zero acceptance criteria* | `jarvis-forge/pipeline/schemas/phase.py` |
| **2 — runtime** | the inbox-watcher, at drop time | **Strict** — synthesizes a `SpecMd` from your phase and re-parses it through `validate_spec_md`, which *requires* a non-empty description and ≥1 checkbox | `jarvis-forge/pipeline/spec_md.py` |

The trap: a phase that prints `OK` under bouncer 1 gets **rejected the moment
bouncer 2 synthesizes its spec**. You fix it, re-run the static validator, it
says OK again, you re-drop, it fails again — the four-cycle dance.

**`forge_spec_lint.py` closes the gap.** It is a *dry run of the runtime path*:
it imports and calls the same chain the watcher uses —
`parse_project_md` → `parse_phase_md` → `_phase_to_spec` → `_spec_to_md_text`
→ `parse_spec_md` — so there is no second validator to drift from. Run the
linter and you see bouncer 2's verdict before you drop.

```bash
# bouncer 1 — static, lenient (scope rules + schema)
python scripts/forge_spec_validate.py projects/inbox/<your-id>

# the real gate — dry-run of runtime, strict (what actually fails you)
python scripts/forge_spec_lint.py projects/inbox/<your-id>
```

---

## Anatomy of a project drop

Drops live in `jarvis-forge/projects/inbox/<your-project-id>/`. Copy the
canonical template — don't hand-assemble:

```bash
cp -r projects/templates/multiphase projects/inbox/<your-id>
```

```
projects/inbox/<your-id>/
├── project.md              project frontmatter + ## Phases body
├── phases/
│   ├── phase-1-<slug>.md   entry phase (depends_on: [])
│   └── phase-2-<slug>.md   follow-up (depends_on: [phase-1-<slug>])
└── .ready                  empty sentinel — see below
```

| Sentinel | Effect | Source |
|---|---|---|
| `.ready` | **Required.** The watcher refuses any project without it (`_is_project_stable`). Drop *after* every `.md` is in place — it's the "I'm done writing, process me" signal that closes the partial-write race. | `pipeline/inbox_watcher.py:612` (TD-#79) |
| `<name>.lock` | Written by the watcher itself when it picks up the drop. Don't create it. | `pipeline/inbox_watcher.py:631` |

> There is **no `.pause` sentinel** today. To stop the watcher from picking up
> a drop, don't create `.ready` (or work in `projects/templates/`, which is
> never scanned). If you need to pause work mid-flight, that's a phase-stage
> concern (`parked`), not a sentinel.

The watcher polls every 5 s (`DEFAULT_POLL_INTERVAL_S`). On pickup it globs
`phases/*.md` — **it executes whatever phase files exist, regardless of what
`## Phases` declares.** That divergence is pitfall #4 below.

---

## `project.md` required shape

### Frontmatter

Parsed by `parse_project_md` → `validate_project`
(`jarvis-forge/pipeline/project_md.py`, `pipeline/schemas/project.py`).

| Field | Required | Type | Rule |
|---|---|---|---|
| `schema_version` | yes | int | Must equal `1`. Defaults to `1` if omitted, but be explicit. |
| `id` | **yes** | string | Non-empty. The project id. |
| `title` | **yes** | string | Non-empty, human-readable. |
| `description` | recommended | string | **A frontmatter field, *not* a body section.** Use a `|` block scalar for multi-line. One paragraph: why, definition of done, scope boundary. |
| `status` | no | enum | `planning` \| `in_progress` \| `complete` \| `failed`. Leave at `planning`; the pipeline owns it. |
| `constraints` | no | mapping | Project-wide defaults surfaced to every phase (see below). |

`constraints` keys consumed by `_phase_to_spec` as per-phase fallbacks
(`jarvis-forge/pipeline/project_runner.py:360`):

| Key | Meaning |
|---|---|
| `target_repo` | Repo slug every phase builds against. |
| `target_branch` | Base branch (default `main`). |
| `cost_cap_usd` | Project-wide ceiling. Sum of per-phase caps should not exceed it. |
| `pr_draft` | `false` opens real PRs. A phase may override. |
| `priority` / `standards` | `P0`–`P3`; `standards` is a list of `ADR-XXXX` ids. |

### `## Phases` body — bullet rules

The parser reads **only** the `## Phases` H2 section to populate
`Project.phases`, one bare id per bullet (`_extract_phases_section`).

✅ **Correct** — bare ids, matching the phase files exactly:

```markdown
## Phases

- phase-1-create-route
- phase-2-register-router
```

❌ **Wrong** — trailing decorators / descriptions. The bullet text must equal
the phase `id` character-for-character:

```markdown
## Phases

- phase-1-create-route — adds the GET endpoint   ❌ " — adds…" makes the id not match
- Phase 2: register the router                   ❌ not an id at all
```

A decorated bullet doesn't error loudly — it **silently diverges** declared
intent from what runs (the watcher globs files; see pitfall #4).

---

## phase md required shape

### Frontmatter

Parsed by `parse_phase_md` → `validate_phase`
(`jarvis-forge/pipeline/phase_md.py`, `pipeline/schemas/phase.py`).

| Field | Required | Type | Rule |
|---|---|---|---|
| `schema_version` | yes | int | Must equal `1`. |
| `id` | **yes** | string | Must match `^phase-\d+-[a-z0-9-]+$` (`PHASE_ID_PATTERN`). |
| `project_id` | **yes** | string | Non-empty; matches the parent project `id`. |
| `phase_index` | **yes** | int | `>= 0`. |
| `title` | **yes** | string | Non-empty. |
| `depends_on` | no | list | Each entry must match the phase-id regex **and** name a phase in this project. `[]` for the entry phase. |
| `current_stage` | no | enum | Must be `inbox` at drop time; the pipeline manages transitions. |
| `files_to_touch` | **in practice yes** | list | Aider's editable scope. See pitfall #3 — empty breaks new-file creation. |
| `constraints` | no | mapping | `cost_cap_usd`, `aider_model`, `pr_draft`, `priority`, `estimated_complexity`. |
| `codegen_strategy` | no | enum | `aider-then-claude` (default) \| `claude-only`. |

### Body — required sections (H1!)

The phase parser recognizes **only H1 (`#`) headings** named `Description` and
`Acceptance Criteria` (`_parse_sections` / `_normalize_heading`). Everything
else is ignored.

| Section | Heading | Strict requirement |
|---|---|---|
| `# Description` | **H1 `#`** | Non-empty body (enforced by `validate_spec_md` at runtime — bouncer 2). |
| `# Acceptance Criteria` | **H1 `#`** | At least one `- [ ]` checkbox. |

✅ **Correct:**

```markdown
# Description

Add `GET /api/auto/overview` to `server/routes/auto.py`. Returns a JSON
summary. Do not touch the router registration — that's phase-2.

# Acceptance Criteria

- [ ] `GET /api/auto/overview` returns 200 with a JSON body
- [ ] A smoke test in `tests/test_auto_routes.py` exercises the route
- [ ] No other file is created or modified
```

❌ **Wrong** — H2 headings are **silently dropped**, leaving description/AC
empty; bouncer 2 then rejects the synthesized spec:

```markdown
## Description          ❌ H2 — parser skips it; description parses as ""

## Acceptance Criteria  ❌ H2 — parser skips it; AC parses as []
```

### Checkbox AC format

Only `- [ ]` (or `- [x]`) checkbox bullets are parsed as criteria
(`_extract_checkboxes`, regex `^\s*-\s*\[[ xX]\]\s*(.+)$`).

✅ `- [ ] Route returns 200`
❌ `1. Route returns 200` — a numbered list is **not** parsed as a criterion
❌ `- Route returns 200` — a plain bullet (no `[ ]`) is **not** a criterion

---

## Common pitfalls — the 5 `phase-11` mistakes

These are the five distinct validator behaviors that the
`phase-11-phi-stripper` loop surfaced. They map 1:1 to `forge_spec_lint.py`'s
internal modes (a)–(e).

| # | Mistake | What the validators do | Fix |
|---|---|---|---|
| **1** | H2 `## Description` / `## Acceptance Criteria` | Parser only reads H1, so both sections parse empty. Bouncer 1 (lenient) passes; **bouncer 2 rejects** ("description … required", "acceptance criteria … at least one checkbox"). | Use single `#`. |
| **2** | Numbered acceptance criteria (`1.` `2.`) | The H1 is found but `_extract_checkboxes` matches no items → empty AC → bouncer 2 rejects. | Convert to `- [ ]` checkboxes. |
| **3** | Empty `files_to_touch` | **Both** validators accept it — no schema rejects an empty list — but the Aider draft stage *parse-errors on new-file creation* (smoke #5, 2026-05-18). Only the linter flags it. | Declare each file in the frontmatter `files_to_touch:` list. A list in the body is not parsed. |
| **4** | `## Phases` bullet ≠ phase-file id | Runtime globs `phases/*.md` and **ignores** the declared list, so a mismatch never fails the run — it silently diverges intent from execution. The linter treats it as an error. | Make every bullet the bare id; one bullet per file. |
| **5** | Relying on the lenient validator | `validate_phase` accepts empty description/AC; `validate_spec_md` (runtime) does not. Passing bouncer 1 ≠ passing bouncer 2. | Always run `forge_spec_lint.py` — it *is* bouncer 2. |

---

## The lint workflow (draft → lint → drop)

```bash
# 1. draft — copy the template, edit placeholders, rename phase files
cp -r projects/templates/multiphase projects/inbox/<your-id>
#    rename phase-1-example.md → phase-1-<your-slug>.md (keep the phase-N-<slug> shape)
#    update the ## Phases bullets to match

# 2. lint — run BOTH, fix until clean
python scripts/forge_spec_validate.py projects/inbox/<your-id>   # scope rules + schema
python scripts/forge_spec_lint.py     projects/inbox/<your-id>   # dry-run of runtime (the real gate)

# 3. drop — only after both are green
touch projects/inbox/<your-id>/.ready
```

Exit codes (both tools): `0` = no errors (warnings are non-fatal, read them
anyway), `1` = at least one error, `2` = bad argument / missing directory.

`forge_spec_validate.py` adds operator-facing **scope rules** on top of the
schema — caps that keep a phase first-pass-completable on the local model:

| Rule | Limit |
|---|---|
| Acceptance criteria / phase | ≤ 5 (error above) |
| `files_to_touch` / phase | ≤ 2 (warn at 3, error at 4+); empty warns |
| `# Description` length | ≤ 50 non-blank lines (warn), ≤ 80 (error) |
| `cost_cap_usd` / phase | ≤ $5.00 |
| Total phases / project | 1–15 (target 5–10) |

`--llm` shells out to local `ollama` for a per-phase completability estimate;
`--json` emits a machine-readable report.

---

## Templates and starting points

| Resource | Path (in jarvis-forge) |
|---|---|
| **Canonical template** (copy this) | `projects/templates/multiphase/` |
| Project file example | `projects/templates/multiphase/project.md` |
| **Golden phase reference** | `projects/templates/multiphase/phases/phase-1-example.md` |
| Scope rules + worked re-chunking example | `projects/templates/AUTHORING_GUIDE.md` |
| Failure-driven lessons (append after each failure) | `projects/templates/LESSONS.md` |

For a real-world golden, also read the most recently shipped phase under
`projects/done/` — production phases are the best worked examples of "what
clears both bouncers."

---

## When lint and reality disagree

The linter is a faithful dry run of the runtime *spec-shape* path, but it
deliberately omits the **environmental** checks `run_preflight` does with a
live repo + DB. If a phase lints clean but still fails at runtime, the cause is
almost always one of these — not a spec grammar problem:

| Symptom | Likely cause | Where to look |
|---|---|---|
| Lints OK, parks immediately | target repo missing / dirty git tree / cost-cap risk score | `run_preflight` in `pipeline/project_runner.py` |
| Aider runs 19 min, 0 patches | phase too big for `qwen3:14b` first-pass (≥250 LOC) | LESSONS.md §01; re-chunk |
| `status: execute_failed`, `stage: post_aider_zero_patches` | Aider exit=0 but produced nothing | LESSONS.md §02 |
| `"Exceeded USD budget"` but spend is cents | hit the **iteration** cap (15), not the dollar cap — a spec-ambiguity signal | LESSONS.md §05 |
| Phase 1 fails, phases 2–3 vanish | cascade-skip from upstream failure (`skipped` stage) | many-small-phases rule, LESSONS.md §06 |

When a project fails for a spec-quality reason, **append a lesson** to
`LESSONS.md` so the pattern becomes detectable and a future validator rule can
make it un-repeatable.

---

### Source of truth

This doc explains; the code decides. Authoritative grammar:

- **Parsers** — `jarvis-forge/pipeline/project_md.py`, `pipeline/phase_md.py`, `pipeline/spec_md.py`
- **Schemas / validators** — `pipeline/schemas/project.py` (`validate_project`), `pipeline/schemas/phase.py` (`validate_phase`), `pipeline/spec_md.py` (`validate_spec_md`)
- **Runtime synthesis** — `pipeline/project_runner.py` (`_phase_to_spec`, `_spec_to_md_text`)
- **Linter** — `scripts/forge_spec_lint.py` (PR #1516); static validator `scripts/forge_spec_validate.py`
- **Watcher / sentinel** — `pipeline/inbox_watcher.py`
