# ADR-0009: Standardize on ruff S ruleset for Python static security analysis

- **Status:** Accepted
- **Date:** 2026-05-08
- **Deciders:** Ken
- **Supersedes:** N/A — there is no prior JARVIS-wide ADR on Python static security analysis. The legacy de-facto pattern (jarvis-forge running standalone `bandit` with a custom skiplist) is documented in this ADR's Context and explicitly retired here.
- **Related:** TD-X52 / [jarvis-standards#35](https://github.com/kphaas/jarvis-standards/issues/35) — substrate ci.yml propagation to forge, which executes the bandit-→-ruff-S migration on the forge side; jarvis-financial PR #59 (commit `68bf7a9`) — first JARVIS Python service shipping ruff S in production; `jarvis-forge/docs/audits/discovery_2026-05-08_X52_bandit.md` — discovery doc backing this decision; ADR-0005 (multi-writer model — informs the per-repo migration phasing pattern); ADR-0008 (structlog — companion ADR setting the precedent of "production-validated pattern wins, migration deferred to per-repo TDs")

---

## Context

JARVIS Python services across eight repos (`jarvis-standards`, `jarvis-alpha`, `jarvis-financial`, `jarvis-family`, `jarvis-forge`, `jarvis-council`, `jarvis-data-sources`, `jarvis-print-copilot`) need a consistent answer for static security analysis on PRs. Today the answer is split:

- **6 of 8 repos** (`alpha`, `family`, `council`, `data-sources`, `print-copilot`, `standards`) run no standalone Python security scanner. Their substrate `ci.yml` runs the `secret-scan` job (`detect-secrets` against `.secrets.baseline`) plus ruff with each repo's chosen ruleset, but no `bandit`-class analysis of code patterns. The 2026-05-08 cross-repo bandit census confirmed this: zero of the six have `bandit` in `.github/workflows/*.yml`, zero have `[tool.bandit]` in `pyproject.toml`, zero have `bandit.yaml`, zero include a bandit hook in `.pre-commit-config.yaml`.
- **1 of 8 (`jarvis-financial`)** runs ruff with `"S"` in its `[tool.ruff.lint.select]` list. The `S` ruleset is ruff's native port of `flake8-bandit`, which is itself a flake8 wrapper around bandit's checks. Practically, financial gets bandit-equivalent coverage as a side-effect of the existing ruff pass — single tool, single config, single CI invocation. PR #59 (the structlog reference implementation merged 2026-05-01) shipped this configuration; it has been running in production CI without operational complaint since.
- **1 of 8 (`jarvis-forge`)** runs standalone `bandit==1.9.4` as its own CI step (`bandit -c pyproject.toml -r server pipeline services memory metrics invariants -ll`), with `[tool.bandit]` config in `pyproject.toml` (eight skips: `B101`, `B404`, `B603`, `B110`, `B501`, `B607`, `B310`, `B608`), an exclusion list of seven directories (`tests`, `ui`, `dist`, `node_modules`, `.venv`, `__pycache__`, `logs`), one `# nosec B104` line annotation in `invariants/rules.py:115`, and a redundant on-disk `bandit.yaml` retained for `pipeline/claude_runner.py` to read at gate time. The forge configuration is the only standalone-bandit deployment in JARVIS.

The historical record on forge's bandit gate is informative. `git log --all --oneline | grep -iE 'bandit|B[0-9]{3}'` returns eight commits over the repo's lifetime: the initial install (`91d090e`, `622d592`), a CLAUDE.md sync (`b863fc8`), four "skip a false positive" patches (`53ff21c`, `806e8ee`, `efa490a`, `3c712a6`), and one false-match on the substring `B103` in a Jinja template commit (`0f4b424`). **No commit in forge's history has the shape "fix(security): bandit caught X."** The pattern is repetitive false-positive triage: bandit's noise floor required eight rule skips and a per-line `# nosec`, with no documented production catch on the other side of that maintenance cost. Bandit hasn't been load-bearing in forge's security posture; it has been a tool whose primary lifecycle artifact is its own skiplist.

The substrate `ci.yml` template (`scripts/_templates/workflows/ci.yml`, TD-X29 lineage) deliberately omits any bandit-class step. The substrate's security signal is `secret-scan` (detect-secrets baseline diff) plus repo-defined ruff rules. When forge adopts the substrate workflow under TD-X52, it inherits this default — the question becomes whether to (a) keep a forge-specific bandit job alongside the substrate's five jobs as a unique-to-forge addition, (b) drop bandit entirely and rely on detect-secrets + pipeline-time `_run_lint`, or (c) replace standalone bandit with ruff `S` in the existing ruff pass. Without an architectural lock, the forge port either replicates the legacy bandit drift or makes a one-off choice that doesn't generalize to the next repo's security question.

The architectural question is **which Python static security analysis tool is canonical, when one is run at all**. Three options were on the table:

1. **Push standalone bandit into the substrate as the JARVIS-wide standard.** Forces the five non-bandit repos to adopt tooling they didn't choose, replicating coverage one of them already gets via ruff. Substrate maintenance cost goes up; substrate portability claim ("Python + uv only") breaks.
2. **Keep forge-specific bandit as a parallel job; leave the rest of JARVIS untouched.** Encodes drift as policy. The substrate's design value is uniformity across consumers; carving forge out signals that any repo can opt into a one-off security tool indefinitely. The maintenance cost of forge's eight skips moves nowhere; the substrate gains nothing.
3. **Standardize on ruff `S` ruleset; deprecate standalone bandit.** Single tool (ruff) for lint + format + security. Pattern is already in production on financial; moving forge onto it brings forge into alignment with the only sibling that has measured experience with this class of analysis. Substrate stays untouched; the security signal is configured per-repo in `pyproject.toml`, which matches how every other ruff rule is already configured.

Option 3 is the only one consistent with the "production-validated pattern wins" framing established by ADR-0008. Financial is the only JARVIS Python service shipping ruff `S` today; that experience — including the absence of operational complaint — is the relevant data. Forge's standalone bandit has more deployment-time mileage but no validation evidence (no documented catch in the git log). When the validated pattern and the legacy pattern conflict, the validated one wins and the legacy gets a migration path.

## Decision

**JARVIS adopts the ruff `S` ruleset (ruff's native port of `flake8-bandit`) as the canonical Python static security analysis tool**, with the following binding rules:

1. **Ruff `S` is the standard for static security analysis across all JARVIS Python repos.** Any repo that runs static security analysis on Python code does so via `S` rules in its `[tool.ruff.lint.select]` configuration, in the same ruff invocation that runs the rest of its lint pass. There is no separate "security" CI step.
2. **Standalone `bandit` is deprecated.** New repos do not add bandit. Existing repos with bandit migrate to ruff `S` in dedicated per-repo TDs; the migration is mechanical because ruff's `S` codes are a direct namespace port of bandit's `B` codes.
3. **Substrate stays untouched.** The substrate `ci.yml` template (`scripts/_templates/workflows/ci.yml`) does not gain a bandit step or an `S`-specific step; it already runs `uv tool run ruff check .`, which honours each repo's `[tool.ruff.lint]` configuration. Substrate scope remains "workflow + hooks." There is no substrate `pyproject.toml` template; this ADR is the canonical source for the configuration shape.
4. **Skiplists carry forward explicitly.** Migrating repos translate bandit `B###` skips into ruff `S###` ignores in their `[tool.ruff.lint]` config (or `[tool.ruff.lint.per-file-ignores]` for path-scoped skips). The 1:1 numeric correspondence between bandit `B###` and ruff `S###` codes makes this a textual edit, not a re-evaluation. Skips that no longer reflect real false positives should be dropped during migration; skips that still do are preserved with their original rationale.
5. **Per-repo opt-in.** Adopting `S` is repo-by-repo, not flag-day. Each Python repo decides when (and whether) to enable `S` based on its own security posture and timeline. The five sibling repos that currently run no bandit-class analysis are not required to adopt `S` as part of this ADR — they can adopt it any time they choose, and follow-up TDs will be filed per repo when the team is ready. ADR-0009 defines the standard; it does not mandate universal coverage.

The reference implementation is jarvis-financial's `pyproject.toml` (PR #59, commit `68bf7a9`), where `"S"` appears in `[tool.ruff.lint.select]` alongside the rest of the financial ruleset. New adopters copy the relevant pattern from financial.

### Canonical ruff `S` configuration

Repos add the following to their `pyproject.toml`. Each repo tunes the `select` list to its existing rule choices; the load-bearing element is the presence of `"S"`:

```toml
[tool.ruff.lint]
select = ["E", "F", "W", "I", "S"]  # adjust per repo; S is the security ruleset
# If migrating from bandit, carry forward intentional skips here:
ignore = [
    # "S101",  # assert_used — uncomment if your repo intentionally allows asserts
]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101"]  # assert is idiomatic in pytest
```

Repos already on ruff (every JARVIS Python repo today) add `"S"` to the existing `select`; the rest of the existing `[tool.ruff.lint]` block is preserved. The `[tool.ruff.lint.per-file-ignores]` entry for `tests/**` is the recommended baseline because pytest idiomatically uses `assert` and rule `S101` would flag every test.

### Migration pattern (reference)

For a repo migrating off standalone bandit (forge is the only such repo today; the pattern is documented here for posterity):

1. **Add `"S"` to `[tool.ruff.lint.select]`.** No new dependency — ruff already includes the `S` ruleset.
2. **Translate `[tool.bandit].skips`** entry-for-entry into `[tool.ruff.lint.ignore]` by replacing the `B` prefix with `S`. Keep the original comment rationale next to each entry. Example: `B101  # assert_used — used in tests` becomes `"S101",  # assert_used — used in tests`.
3. **Translate path-scoped skips** (`[tool.bandit].exclude_dirs`) into `[tool.ruff.lint.per-file-ignores]` if they are security-rule-specific (`"tests/**" = ["S101"]`), or rely on ruff's existing `extend-exclude` / `.gitignore` for whole-directory exclusions that aren't security-rule-specific.
4. **Remove the `[tool.bandit]` block** from `pyproject.toml` and delete `bandit.yaml` if present.
5. **Remove `bandit` from `[project.optional-dependencies].dev`** (or the equivalent dev-group for repos on PEP 735).
6. **Remove the bandit step from `.github/workflows/ci.yml`.** For forge specifically, this is rolled into the TD-X52 substrate adoption — the bespoke `lint-and-test` job is replaced wholesale by the substrate's five-job shape, and bandit doesn't reappear.
7. **Audit `# nosec` line comments.** Bandit's `# nosec B###` annotations become ruff's `# noqa: S###` (or the broader `# noqa` if multiple rules apply). For example, `# nosec B104` becomes `# noqa: S104`.
8. **Run the migrated config.** `uv tool run ruff check .` should produce no security findings on a clean pass; any new findings are either real issues to fix or skips that need to be added (with a documented rationale).

### Out of scope for this ADR

- **Cross-repo migration mandate.** This ADR sets the standard but does not mandate that the five non-bandit sibling repos adopt `S`. Each repo files its own follow-up TD when ready (or chooses not to). ADR-0008 is the precedent: it set the structlog standard but punted migration timing to TD-X36 + per-repo TDs.
- **Substrate pyproject template.** None exists today (`scripts/_templates/` ships workflow + hooks only). This ADR does not propose creating one. New repos copying financial's `pyproject.toml` as a starting point is the de-facto pattern; codifying it in a substrate template is a separate question that would require its own ADR if it ever became architecturally significant.
- **Pipeline-time security signals.** Forge's `pipeline/claude_runner.py` runs bandit on changed files at feature-build time. Whether to migrate that to a ruff invocation is a forge-internal question, not a JARVIS standards question; TD-X52 will decide it during the substrate port. This ADR governs CI-time PR signal only.
- **Other security tooling.** Semgrep, snyk, pip-audit, trufflehog, dependency CVE scanning — all outside the scope of this decision. ADR-0009 picks ruff `S` as the answer to "which static security analyzer for Python source code"; it does not claim that's the entirety of JARVIS's security posture. detect-secrets remains the substrate's secret-scan tool; pip-audit and friends remain unaddressed and may warrant future ADRs.

## Consequences

### Positive

- **Single tool for lint + format + security.** Ruff already runs in every JARVIS Python repo. Adding `"S"` to `select` makes security analysis a side effect of the existing pass — no new tool to install, no new config file, no new CI step, no new severity threshold to maintain. The cognitive surface for "what runs on my Python PR" shrinks.
- **Faster CI.** One ruff invocation replaces ruff + bandit. Forge specifically saves the `bandit -c pyproject.toml -r server pipeline services memory metrics invariants -ll` step entirely once TD-X52 lands; substrate-wide, the saved time scales with repo size.
- **Cross-repo consistency.** The financial pattern becomes the JARVIS standard, not a one-off. Future repos default into the validated pattern instead of inheriting forge's bespoke bandit-with-eight-skips shape.
- **Lower maintenance.** Ruff `S` evolves with each ruff release; the version pin is whatever pin the repo already has on ruff. There's no separate `bandit==1.9.4` pin to bump in lockstep with security advisories. Astral's release cadence on ruff is faster than PyCQA's on bandit.
- **Migration is mechanical.** Bandit `B###` codes map 1:1 to ruff `S###` codes for every rule ruff covers. The forge migration is a textual edit, not a re-evaluation of which checks matter.
- **Substrate stays small.** The substrate template doesn't accumulate a security-analysis surface. Per-repo configuration in `pyproject.toml` is consistent with how the rest of ruff is configured today (rule selection, formatter style, line length all live in `pyproject.toml`).

### Negative

- **Coverage gap on advanced bandit rules.** Ruff's `S` ruleset is a port, not a copy, and historically lags bandit on a small number of advanced checks (some `B6xx`-series rules around process / IO patterns). The gap is narrow in practice and shrinking with each ruff release. Mitigation: forge's git-log audit shows zero documented production catches in standalone bandit's history, so the practical risk of a coverage gap mattering is low. If a specific rule turns out to be load-bearing for a specific repo, that repo can run bandit alongside ruff for that rule alone — a per-repo deviation, not a JARVIS-wide standard.
- **Forge migration cost.** TD-X52 picks up the work. The migration is mechanical (eight skip translations, one pyproject section deletion, one CI step deletion, possibly one `# nosec` rewrite at `invariants/rules.py:115`). PR #59-style precedent exists for what the resulting `pyproject.toml` block looks like. Estimated lift: well under an hour, gated by the substrate ci.yml port that TD-X52 is doing anyway.
- **`# nosec` annotations need rewriting.** Bandit reads `# nosec` (with optional rule code); ruff reads `# noqa: S###`. Code already annotated for bandit suppressions has to be re-annotated during migration. For forge this is a one-line edit in `invariants/rules.py:115`. The verbosity of `# noqa: S###` over `# nosec B###` is a minor ergonomic regression.
- **One-time PR-time signal disruption.** When forge first turns on `S`, the initial scan may surface findings that bandit's skiplist had hidden. Mitigation: do the migration on a branch, triage findings, decide for each finding whether it's a real issue to fix or a skip to carry forward, and merge with the resulting state. The result is at worst the same coverage as today and at best a strictly larger, validated set.

### Neutral

- **Repos already using ruff `S` need no change.** Financial has been on this pattern since PR #59; no `pyproject.toml` edits are required for it under ADR-0009.
- **Repos that don't run any security analysis stay where they are.** ADR-0009 doesn't mandate that the five non-bandit siblings adopt `S`. They may, when they're ready; they may not, if their security posture today is acceptable. The ADR sets the standard for repos that opt in, not a universal coverage requirement.
- **Substrate `secret-scan` job is unaffected.** detect-secrets-against-baseline is a separate class of tool (secret-strings detection vs. pattern-based code analysis); ADR-0009 does not touch it. Repos continue to maintain `.secrets.baseline` as before.
- **Bandit is not banned.** Repos may run standalone bandit if they have a specific reason (e.g. an unported rule). ADR-0009 just says the JARVIS standard is ruff `S`; opting out is a per-repo choice, not a violation.

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| ruff `S` ruleset (built into `ruff` >= 0.4.0; PyPI) | Tier 4 (third-party Python tool, already a JARVIS-wide dependency for lint + format) | Standalone `bandit` (PyPI) remains a viable fallback if ruff `S` is ever yanked, deprecated by upstream, or proves insufficient on a specific rule. The fallback path is bounded to per-repo `pyproject.toml` edits — no substrate template change required. The conceptual model (declarative `[tool.ruff.lint].select` driving CI behaviour) survives any tool swap. |
| Removed dependency: `bandit==1.9.4` (forge only, removal under TD-X52) | N/A (subtractive) | Re-adding bandit at the same pin is a one-block `pyproject.toml` edit — the legacy `[tool.bandit]` config is preserved in this ADR's Migration pattern as a textual reference for re-introduction if ever needed. |

ruff `S` adds no new external service or network surface beyond the existing PyPI dependency on `ruff`. Every JARVIS Python repo already pulls `ruff` for lint and format; this ADR enables an additional rule namespace inside that existing dependency. Sovereignty footprint is unchanged.

## Alternatives considered

### Option A — Standardize on ruff `S` ruleset (SELECTED)

See Decision section above.

### Option B — Push standalone bandit into the substrate as the JARVIS-wide standard

Add a `bandit` step to `scripts/_templates/workflows/ci.yml`; require every Python repo to install `bandit` and ship a `[tool.bandit]` config. Document forge's existing bandit shape as the reference.

Rejected on multiple grounds. (1) **Coverage replication for no gain.** Five of six non-financial Python repos would adopt a new tool; one of them (financial) already gets bandit-equivalent coverage via ruff `S`, so it would be running both tools — duplicate signal at twice the maintenance cost. (2) **Substrate scope creep.** The substrate's design promise is "uniform Python + uv toolchain, no per-repo infrastructure assumptions." Adding bandit installs a tool whose lifecycle (config, skiplist, severity threshold) is exactly the kind of per-repo divergence the substrate is meant to suppress. (3) **No production validation.** Forge's standalone bandit is the only deployment of this tool in JARVIS, and its eight-commit history shows no documented catch — promoting that as the standard inverts the production-validated rule from ADR-0008. (4) **Maintenance cost moves the wrong way.** Six repos × one bandit pin × one skiplist × one severity threshold = six maintenance surfaces where one would do; the sibling repos haven't asked for this and gain nothing from absorbing the cost.

### Option C — Keep forge-specific bandit as a parallel job; leave rest of JARVIS untouched

Forge keeps its bespoke bandit step alongside the substrate's five jobs after TD-X52; substrate stays untouched. No JARVIS-wide standard.

Rejected. (1) **Encodes drift as policy.** The substrate exists to suppress bespoke per-repo CI shapes; carving forge out signals that any repo can opt into a one-off security tool indefinitely with no architectural reason. (2) **Maintenance cost stays where it is.** Forge's eight skips, two redundant config files (`bandit.yaml` + `[tool.bandit]`), and `# nosec B104` annotation continue to require active triage, with no production-validation history justifying the cost. (3) **Punts the architectural question.** ADR-0009's purpose is to set the JARVIS Python static security analysis standard. "Forge gets a special exception" is not an architectural answer; it's an architectural deferral that the next repo's security question will re-open. (4) **Doesn't generalize.** When alpha or council later asks "should we add bandit?", "forge has it but it's a one-off" is a worse answer than "JARVIS standardized on ruff S in ADR-0009; here's the pattern."

### Option D — Adopt semgrep, CodeQL, or another third-party SAST instead

Wire in semgrep (or GitHub's CodeQL, or a similar SAST tool) as the JARVIS-wide standard.

Rejected as premature and out of scope. The decision in front of us is "what to do with forge's bandit during the TD-X52 substrate port." Semgrep is a different class of tool (richer pattern engine, larger rule corpus, longer runtime, more configuration surface) and a different commitment (often hosted-service-augmented, with billing implications). Choosing it would require a separate ADR with its own evaluation. Ruff `S` is the lower-cost, in-toolchain answer that resolves the immediate question without precluding a future move to a heavier SAST if one is ever justified by a real catch the existing tooling missed.

### Option E — Drop static security analysis entirely; rely on `secret-scan` + code review only

Remove forge's bandit step, do not add ruff `S`, accept that JARVIS Python has no automated pattern-based security analysis in CI.

Rejected. While forge's bandit history shows no documented production catch, "no documented catch yet" is a weaker argument for dropping a tool entirely than for swapping it for a lower-cost equivalent. Ruff `S` adds essentially zero overhead (it runs inside the existing ruff invocation), so the cost-benefit calculation that makes forge's standalone bandit hard to justify does not apply to ruff `S`. Choosing the zero-cost option is the right move; choosing zero coverage is unnecessary.

## Reversal conditions

Revisit this ADR if any of the following occur:

1. **A class of security finding surfaces that ruff `S` cannot detect but bandit (or another tool) can.** A documented real-world catch on standalone bandit in any JARVIS repo, or a rule that bandit covers and ruff `S` does not, is grounds to either (a) re-evaluate the gap and accept it explicitly, (b) add a second tool for that specific rule class as a per-repo deviation, or (c) re-open the question of whether ruff `S` should remain canonical.
2. **Astral deprecates the `S` ruleset or stops maintaining the flake8-bandit port.** ruff's commitment to `S` rule maintenance is currently strong (active issue tracker, tracked alongside other rulesets in changelog), but a future deprecation would force a fallback. The Sovereignty First fallback to standalone bandit is bounded to per-repo `pyproject.toml` edits per the table above.
3. **JARVIS adopts a heavier SAST (semgrep, CodeQL, etc.) for richer coverage.** If the security posture evolves to require a tool with a richer pattern engine than ruff `S` provides, this ADR is amended or superseded with the new standard. ruff `S` is a baseline; it doesn't preclude a future stack.
4. **Annual review.** Re-read this ADR at the next yearly standards review (target Q2 2027). Static security analysis tooling moves; the cost-benefit between in-toolchain rules (ruff `S`), dedicated tools (bandit, semgrep), and language-server / IDE-shipped rules will look different in a year. Explicit review prevents silent rot.

## References

- jarvis-financial PR #59 (reference implementation): <https://github.com/kphaas/jarvis-financial/pull/59>
- jarvis-financial commit `68bf7a9` (ruff `S` configuration in `pyproject.toml`)
- ruff rule reference (flake8-bandit `S` codes): <https://docs.astral.sh/ruff/rules/#flake8-bandit-s>
- bandit documentation: <https://bandit.readthedocs.io/>
- TD-X52 / [jarvis-standards#35](https://github.com/kphaas/jarvis-standards/issues/35) — substrate ci.yml propagation to forge (executes the bandit-→-ruff-S migration on the forge side)
- `jarvis-forge/docs/audits/discovery_2026-05-08_X52_bandit.md` — discovery doc with the cross-repo bandit census, forge git-log audit, and option analysis
- `scripts/_templates/workflows/ci.yml` (this repo) — substrate workflow that the `S` rules run inside
- ADR-0005 (this repo) — multi-writer model; informs per-repo migration phasing
- ADR-0008 (this repo) — structlog precedent for "set the standard, defer migration to per-repo TDs"
