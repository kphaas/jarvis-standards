# PROPOSAL: Cross-Repo Drift Detection Framework

**Status:** Proposed
**Date:** 2026-05-02
**Proposer:** Ken (raised during jarvis-financial Saturday cleanup session)
**Target ADR:** TBD (next available number in jarvis-standards/docs/adr/)

---

## Problem

Across 5 active JARVIS repos (jarvis-alpha, jarvis-forge, jarvis-financial, jarvis-family, jarvis-data-sources), config and code drift silently. The 2026-05-02 jarvis-financial Saturday session surfaced five distinct drift bugs in a single afternoon:

1. **Repo had two web roots** — `apps/web/` (legacy) and `services/web/` (M2 deliverable). README, CLAUDE.md, dependabot, and one CI workflow pointed at `apps/web/`. Real CI (`web-ci.yml`, `e2e-ci.yml`) targeted `services/web/`. Nobody noticed for ~2 weeks.

2. **ADR-0005 referenced paths that never existed** — claimed `apps/web/app/tile/page.tsx` was implemented; neither `apps/web` nor `services/web` ever had a `/tile` route.

3. **Cross-config inconsistency** — README/CLAUDE.md/dependabot.yml/MILESTONE-2-PLAN.md all named `apps/web` while CI built `services/web`.

4. **Env var alignment risk** — `.env` and `.env.example` could drift silently. Caught only because Claude Code ran an ad-hoc diff during verification.

5. **CI references non-existent files** — Risk Engine 100% coverage gate uses `tests/unit/test_risk_*.py` glob; no such files exist. Check has been failing on every PR for unknown duration.

Every one of these is a drift bug. Each took human investigation to surface.

## Hypothesis

A cross-repo drift detection framework, run in CI on every PR for every JARVIS repo, would catch these classes of drift at commit time. Time investment: ~1-2 days to build the framework + per-repo config. Time saved: hundreds of hours over JARVIS lifetime.

## Drift categories observed so far

| Category | Example | Detection method |
|---|---|---|
| Doc-vs-filesystem | ADR references non-existent path | Walk all `.md` for path-like strings, verify exist |
| Cross-config drift | README, CI, dependabot disagree on web root | Define source-of-truth, diff others against it |
| Env var alignment | `.env` keys ≠ `.env.example` keys | grep+sort+diff per pair |
| Code-vs-config | CI glob points to non-existent files | Run `find` for each glob in `.github/workflows/*.yml` |
| ADR implementation | ADR claims "Accepted" but unbuilt | Convention: ADR has Implementation Status section |

This list will grow. Categories are additive over time.

## Proposed shape (sketch — to be locked in ADR)

- **Owner:** `jarvis-standards` repo
- **Form:** Python CLI tool, e.g., `jarvis-drift check --repo .`
- **Config:** Per-repo `.jarvis-drift.yml` declares which checks apply, source-of-truth files, exemptions
- **Distribution:** Installable from jarvis-standards (uv tool? pip? GitHub Action published?)
- **CI integration:** GitHub Action that wraps the CLI; required check on each repo
- **Failure mode:** Hard fail on drift; warnings allowed for known exemptions

## Open questions

1. CLI vs library vs GitHub Action — which is the primary form?
2. How does jarvis-standards version (submodule pin? package version? Action SHA pin?)
3. What's the upgrade path when a new check is added — opt-in or auto-enabled?
4. False-positive policy — warn-once vs hard-fail?
5. Do we use this on jarvis-standards itself? (recursive bootstrap question)

## Next steps

1. **Sunday 2026-05-03 brainstorm** — fits inside the planned ADR audit. Read existing ADRs, document drift found, refine drift category list.
2. **Monday/Tuesday** — write ADR formalizing the framework decision.
3. **M3+** — implement, starting with one repo (likely jarvis-financial) and one check (likely env var alignment).
4. **Iterate** — add a check per week until coverage is broad.

## Related

- jarvis-financial 2026-05-02 Saturday session (5 drift bugs surfaced)
- ADR-0005 amendment (Implementation Status section pattern — already a partial drift solution)
- TD-X11 main branch protection (drift checks become more valuable when required)
- TD-X15 (this proposal's tracking ID in jarvis-financial's TD list)
