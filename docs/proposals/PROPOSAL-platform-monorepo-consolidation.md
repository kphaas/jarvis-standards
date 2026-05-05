# PROPOSAL: jarvis-platform monorepo consolidation

**Status:** Proposed
**Date:** 2026-05-02
**Proposer:** Ken (locked during 2026-05-02 Saturday architecture session)
**Target ADRs:** TBD (likely 2-3 new ADRs in jarvis-standards/docs/adr/)
**Estimated effort:** 1 weekend big-bang migration + 1-2 weeks of agent-driven cleanup

---

## Problem

Solo developer maintaining 8 polyrepos across 5 machines (Air, Brain, Gateway, Endpoint, Sandbox) with both human and AI agents editing. Pain points surfaced during 2026-05-02 Saturday session:

1. **Drift across repos** — README/CI/dependabot in jarvis-financial pointed at deleted apps/web while CI built services/web. ADR-0005 referenced paths that never existed. Discovered only when investigating unrelated work.
2. **Sync coordination** — "Did I update X repo too?" is constant mental overhead. Sandbox push rejected today because Air had committed to standards in a separate flow.
3. **Cross-cutting standards** — jarvis-standards is the single source of truth for conventions, but propagating changes to N repos is manual. Not enforced. Drift accumulates silently.
4. **AI agent context fragmentation** — agents see one repo at a time. Cross-repo refactors require N coordinated sessions. Agents miss context that exists across repo boundaries.
5. **Infrastructure vs features** — solo dev time is consumed by per-repo CI maintenance, propagation, sync, and standards enforcement instead of shipping product features.

The pattern from session lessons: **polyrepo enforcement infrastructure is half-built**. Finishing it requires more infrastructure work. Hybrid monorepo collapses 4 of those repos into 1 coordination unit, eliminating 75% of the cross-repo coordination problem at the source.

---

## Decision

Adopt hybrid Google-style architecture:

### Monorepo: `jarvis-platform` (new repo)

Internal layout follows industry standard `apps/` + `packages/` convention:
jarvis-platform/
├── apps/
│   ├── alpha/         (was kphaas/jarvis-alpha)
│   ├── forge/         (was kphaas/jarvis-forge)
│   └── council/       (was kphaas/jarvis-council)
├── packages/
│   └── standards/     (was kphaas/jarvis-standards)
├── pyproject.toml     (root: uv workspace declaration)
├── uv.lock            (root: lockfile for entire workspace)
├── Makefile           (root: cross-app commands)
├── docs/
│   ├── adr/           (consolidated from jarvis-standards/docs/adr/)
│   └── proposals/     (this file moves here post-migration)
├── scripts/
│   └── _templates/    (shell templates from jarvis-standards/scripts/_templates/)
└── .github/
└── workflows/     (per-app CI gates with paths: filters)

### Separate repos (5 total — consume standards via package + propagation)

- `jarvis-financial` (P trait — PR-only)
- `jarvis-family` (B trait — branch-safety)
- `jarvis-print-copilot` (B trait — branch-safety, pending MS1 kickoff)
- `jarvis-data-sources` (P+D trait — submodule-consumed by multiple modules per Sunday Q-B answer)

### Standards distribution: hybrid

| Type | Mechanism | Consumer pattern |
|---|---|---|
| Python standards (configs, types, middleware, validators, structlog wrapper, get_secret() canonical impl) | Versioned package | `uv add jarvis-standards@1.2.0` from `packages/standards/` published to private index |
| Shell templates (commit_core, check_sync, ruff_detect) | Generated propagation | Existing `propagate_scripts.sh` pattern — runs from monorepo, writes generated files into separate repos |
| ADRs / docs / patterns | Reference-only | Separate repos link to specific commit URLs in own ADRs |

### Standards inheritance

- All separate repos inherit JARVIS core standards (logging, secrets, get_secret, node_addresses)
- Each separate repo can layer domain-specific standards (financial = SEC/FINRA-flavored, family = privacy/COPPA-flavored, council = TBD)
- Domain standards live in the separate repo's own `docs/adr/` and never override core standards

### Build tool: uv workspace + Makefile

No Nx, Turborepo, Bazel. Reasoning per session lens-check:

- Solo dev with Python-primary stack
- AI agents native to uv tooling
- Reversible — outgrowing uv workspace later is straightforward
- Boring tooling > new tooling for shipping features
- Big-tech tools (Bazel, Nx) are taxes that pay off at 100+ engineer scale

---

## Migration approach: big-bang

Single-weekend migration with agent-driven cleanup follow-on. Tag-and-archive history strategy: old 4 repos preserved as read-only archives, monorepo starts fresh, agents fix any broken cross-references discovered post-migration.

---

## Pre-migration checklist

Must be true before execution begins:

- [ ] All 4 source repos have clean working trees on every machine that has them
- [ ] All in-flight PRs in source repos either merged or explicitly abandoned
- [ ] Sandbox cert renewal not imminent (next renewal date >= 7 days out per `forge.cert-renew` LaunchAgent schedule)
- [ ] No active LaunchAgent dependencies on source repo paths during migration window
- [ ] Backup created: full tarball of all 4 source repos at known SHA
- [ ] CI is green on main of all 4 source repos (proves baseline before move)
- [ ] No active session (forge pipeline, dream mode, etc.) running during migration window
- [ ] Sunday brainstorm complete (Q-D web tile topology decided — affects financial only but worth confirming first)
- [ ] jarvis-alpha at a Slab boundary (no in-flight RLS migration — Slab 6 must be either complete or not started)
- [ ] Full LaunchAgent plist backup captured per node (Brain, Gateway, Endpoint, Sandbox) — tarball under `~/jarvis-platform-migration/plists-backup-<node>.tar.gz`

---

## Migration sequence (big-bang weekend)

### Phase 0 — Setup (30 min)

1. Create `kphaas/jarvis-platform` empty repo on GitHub
2. Clone to Air at `~/jarvis-platform/`
3. Initialize uv workspace skeleton
4. Initialize `apps/` and `packages/` directories
5. Initialize root pyproject.toml with workspace declaration
6. Create initial Makefile with placeholder targets
7. Initial commit: scaffold

### Phase 1 — Migrate jarvis-standards → packages/standards/ (60-90 min)

Smallest, no consumers pinned to file paths yet.

1. Tag `kphaas/jarvis-standards` at current HEAD: `final-standalone-2026-05-XX`
2. Copy files (not git history) into `jarvis-platform/packages/standards/`
3. Restructure as Python package (add `pyproject.toml`, `src/jarvis_standards/__init__.py`)
4. Move `docs/adr/` to monorepo root `docs/adr/`
5. Move `docs/proposals/` to monorepo root `docs/proposals/`
6. Move `scripts/_templates/` to monorepo root `scripts/_templates/`
7. Move `WORKFLOWS/` to monorepo root `docs/workflows/`
8. Move `DEVELOPMENT_PROCESS.md` to monorepo root
9. Set up package publishing (private index — likely GitHub Releases for v0)
10. Smoke test: `uv build packages/standards`
11. Commit: "Phase 1 — standards migrated to packages/standards/"

### Phase 2 — Migrate jarvis-alpha → apps/alpha/ (2-3 hours)

Biggest, most coupled. Done second so pattern is proven on standards first.

1. Tag `kphaas/jarvis-alpha` at current HEAD: `final-standalone-2026-05-XX`
2. Copy files into `apps/alpha/`
3. Update `apps/alpha/pyproject.toml` to declare uv workspace membership and depend on `jarvis-standards` from local workspace
4. Update import paths if any moved (none expected — alpha doesn't import from standards as a package today; it copies)
4.5. Path-reference sweep — `grep -r "~/jarvis-alpha/\|/Users/.*/jarvis-alpha/" docs/adr/ALPHA5_*` and update every match to `~/jarvis-platform/apps/alpha/` or the equivalent monorepo path. ADRs 0001-0006 (Alpha-5) were written with polyrepo paths; they MUST be updated as part of this phase, not deferred.
5. Migrate `~/jarvis-alpha/scripts/jarvisalpha_commit.sh` to `apps/alpha/scripts/` and update for new path
6. Migrate Brain/Gateway/Endpoint/Sandbox per-machine plist templates
7. Update LaunchAgent paths on all 4 nodes that run alpha services
8. Smoke test: bring up alpha brain locally, verify imports + DB connection
9. Commit: "Phase 2 — alpha migrated to apps/alpha/"

⚠ **Risk in Phase 2:** Alpha's LaunchAgent paths change → all 4 nodes need plist re-install. Per current LaunchAgent diagnostic protocol (verify program path, etime, log mtimes before bootout), realistic is 45-60 min per node. Budget 3-4 hours total across Brain/Gateway/Endpoint/Sandbox. Do not start Phase 2 without the plist backup tarballs from the pre-migration checklist.

### Phase 3 — Migrate jarvis-forge → apps/forge/ (60-90 min)

Sandbox-only, low blast radius.

1. Tag `kphaas/jarvis-forge` at current HEAD: `final-standalone-2026-05-XX`
2. Copy files into `apps/forge/`
3. Update Sandbox LaunchAgents (`com.jarvis.forge.dashboard`, `com.jarvis.forge.cert-renew`) for new paths
4. Migrate `jarvisforge_commit.sh` to `apps/forge/scripts/`
5. Update SQLite path if it referenced old repo path
6. Smoke test: forge dashboard loads on https://jarvis-sandbox:5001
7. Commit: "Phase 3 — forge migrated to apps/forge/"

### Phase 4 — Migrate jarvis-council → apps/council/ (60 min)

Just kicked off May 1 2026 — minimal code accumulated, easy to relocate.

1. Tag `kphaas/jarvis-council` at current HEAD: `final-standalone-2026-05-XX`
2. Copy files into `apps/council/`
3. Update pyproject.toml for uv workspace membership
4. Smoke test: any existing council tests pass
5. Commit: "Phase 4 — council migrated to apps/council/"

### Phase 5 — Repoint separate repos to consume new standards package (2-3 hours)

1. For each of `jarvis-financial`, `jarvis-family`, `jarvis-print-copilot`, `jarvis-data-sources`:
   - Update `pyproject.toml` to declare dependency on `jarvis-standards` package (now from new private index)
   - Replace any vendored standards code with package imports
   - Re-run `propagate_scripts.sh` from monorepo to refresh shell templates
   - Commit per repo
2. Verify CI still green on all 4 separate repos
3. Verify no lingering imports from old standards paths

### Phase 6 — Archive old 4 source repos (30 min)

1. For each of `kphaas/jarvis-alpha`, `kphaas/jarvis-standards`, `kphaas/jarvis-forge`, `kphaas/jarvis-council`:
   - Add ARCHIVED marker README at root
   - Tag final state if not already tagged
   - GitHub Settings → Archive (read-only)
2. Update DEPLOYMENT.md and DEVELOPMENT_PROCESS.md path references in monorepo
3. Update all CLAUDE.md files in monorepo to reflect new layout

### Phase 7 — Sandbox + Brain + Gateway + Endpoint cleanup (60 min)

1. Each machine: clone `jarvis-platform` to `~/jarvis-platform/`
2. Update or remove old `~/jarvis-alpha/`, `~/jarvis-forge/`, `~/jarvis-council/` clones (rename to `.archived` for safety, delete after 30 days)
3. Update shell aliases in `~/.zshrc` (Air) — broken `jarvis` alias gets updated/deleted
4. Verify all LaunchAgents on each machine point to correct new paths
5. Verify `tailscale serve` configs (Sandbox forge :5001) still work after path changes

---

## Rollback strategy per phase

Each phase is independently revertable until Phase 6 (archival). Until Phase 6:

- Old repos still exist on GitHub at their original URLs
- Old clones still exist on machines (can be reactivated)
- Old LaunchAgent plists archived as `.bak` files before modification
- New monorepo can be deleted and old paths re-pointed if any phase fails

After Phase 6 (archival), rollback requires un-archiving GitHub repos (still possible — archive is reversible) and reverting machine paths. ~1 hour of work to undo if needed.

---

## Provenance preservation

Each migrated app's `apps/<name>/README.md` includes header section:

Migrated from kphaas/<name> at SHA <full-sha> on 2026-05-XX.
Original repository: https://github.com/kphaas/<name> (archived)
History prior to this migration: see archived repo.


Original ADRs in standards reference original repo URLs at specific SHAs — those URLs remain valid because GitHub archived repos are still readable.

---

## Standards inheritance — going forward

### When a separate repo (e.g. financial) needs new standards behavior

1. Open PR in `jarvis-platform` against `packages/standards/`
2. Bump version (semver: minor for additive, major for breaking)
3. Publish new version to private index
4. Open PR in separate repo to `uv add jarvis-standards@<new-version>`
5. Merge separate repo PR when ready

### When a separate repo needs domain-specific standard (e.g. financial = SEC requirements)

1. Add ADR to separate repo's own `docs/adr/`
2. ADR explicitly states "extends jarvis-standards X — does not override"
3. Domain-specific implementation lives in separate repo only

### When a shell template changes (commit_core, check_sync)

1. Update template in `jarvis-platform/scripts/_templates/`
2. Run `bash scripts/propagate_scripts.sh` from monorepo root
3. Propagation script writes generated files into all separate repos that consume it
4. Each separate repo gets a PR (or commit, depending on its trait)
5. Per-repo CI validates the regenerated script

---

## Sync enforcement (post-migration)

The hybrid distribution model in §"Standards distribution" defines *what* gets distributed. This section defines *how* drift gets caught when a step is missed.

### Enforcement layers

| Layer | Mechanism | Enforcement |
|---|---|---|
| Python standards | `uv add jarvis-standards@X.Y.Z` exact pin in downstream `pyproject.toml` | GHA opens PR on new release with bumped pin |
| Shell templates | `propagate_scripts.sh` runs in monorepo CI on template change | GHA opens PR per downstream repo with regenerated files |
| Drift detection | `check_sync.sh` runs in every downstream repo CI | Required status check on PR + scheduled weekly run on main |
| Version sync ledger | `packages/standards/CONSUMERS.md` lists each downstream repo + last-synced version | Updated by propagation GHA |

### Trigger flow
Monorepo PR touches packages/standards/** or scripts/_templates/**
↓
CI: bump version, build package, publish to private index (GitHub Releases)
↓
CI: run propagate_scripts.sh against each downstream repo
↓
For each downstream repo: open PR with

bumped jarvis-standards pin in pyproject.toml
regenerated shell scripts
X-Machine: github-actions trailer (per ADR-0005)
↓
Downstream CI runs check_sync.sh + repo-specific tests
↓
B-trait repos (family, print-copilot): auto-merge if green
P-trait repos (financial, data-sources): wait for Ken review


### Pinning policy

Downstream repos pin `jarvis-standards` to an **exact version** (not floating semver range). Floating defeats the audit trail — the propagation PR is the explicit signal "this repo accepted this standards version on this date."

### Drift as a CI failure, not a discovery

Today: drift surfaces during unrelated debugging (the 2026-05-02 pattern that forced this proposal).
Post-migration: `check_sync.sh` is a required status check. Drift fails CI on the next PR touching the downstream repo. No silent accumulation.

---

## Open questions before execution

1. ~~**Private package index for jarvis-standards**~~ **RESOLVED 2026-05-02:** GitHub Releases + tag-based install: `uv add "jarvis-standards @ git+https://github.com/kphaas/jarvis-platform.git@<tag>#subdirectory=packages/standards"`. Zero new infra. Signed tags via GitHub. Promote to Gemfury / CodeArtifact only if outgrown (e.g. >10 consumers, sub-second install required, or external contributor model).
2. ~~**uv workspace + per-app Docker images**~~ **RESOLVED 2026-05-02:** Real risk. Alpha-5 ADRs (0001-0006) reference polyrepo paths (`~/jarvis-alpha/...`). Path-reference sweep is a MANDATORY Phase 2 step (see Phase 2 step 4.5), not deferred follow-on work. Migration weekend cannot complete Phase 2 with stale Alpha-5 ADR paths.
3. **Provenance trailers** — ADR-0005 mandates X-Machine, AI-Agent, AI-Model trailers on commits. Migration commits will need these — establishes the new pattern from day one of monorepo.
4. ~~**CI workflow consolidation**~~ **RESOLVED 2026-05-02:** Per-app workflow file under `.github/workflows/<app>-ci.yml` with `paths: apps/<app>/**` filter. NOT unified matrix. Matrix workflows fail confusingly when one app's dependencies shift independently of others; per-app keeps blast radius contained. Matches Google / Stripe / Shopify monorepo CI pattern.
5. **Branch protection on main of monorepo** — recommend adopt strictly: linear history, require PR, status checks on all app CIs that touched files. Follows ADR-0005 §6.2 P-trait pattern.
6. **What happens to the `jarvis-alpha-financial-coordination` if any cross-repo refactors are in flight on the migration weekend?** — must be either complete or paused.

---

## Estimated effort

| Phase | Effort |
|---|---|
| Setup | 30 min |
| Standards migration | 60-90 min |
| Alpha migration | 2-3 hours |
| Forge migration | 60-90 min |
| Council migration | 60 min |
| Repoint separate repos | 2-3 hours |
| Archive old repos | 30 min |
| Machine cleanup | 60 min |
| **Total weekend** | **9-12 hours** |
| **Agent-driven cleanup follow-on** | **1-2 weeks of small fixes** |

---

## Success criteria

Migration is "done" when:

1. All 4 apps run from monorepo paths
2. All LaunchAgents on all machines reference monorepo paths
3. All separate repos consume standards via package and CI green
4. Old 4 repos archived on GitHub
5. README at monorepo root explains the layout for any new contributor (or new agent session)
6. CLAUDE.md at monorepo root + per-app CLAUDE.md files reference each other correctly
7. First post-migration PR cycle for any change works end-to-end without manual intervention

---

## Why this is the right move (lens summary)

**Big tech:** Google's pattern — core platform monorepo + product repos. Same for Stripe, Shopify, Microsoft Office.

**Big finance:** Audit posture improves — one branch protection config, one CI gate, one secret rotation pipeline for the platform layer. Per-domain repos retain compliance isolation (financial's PCI surface stays separate from family's COPPA surface).

**Top designer (Linear, Vercel):** "The fastest way to ship features is to remove the things that aren't features." Cross-repo coordination is not a feature. Eliminating it is the goal.

**CIO:** Solo dev × infra fatigue × AI agents needing context → hybrid monorepo is the obvious right answer. Going polyrepo for everything was correct in 2024 when AI agents were single-repo. In 2026 with monorepo-aware agents, the calculus flipped.

---

## Decision log

- 2026-05-02 Saturday session — architecture locked
- Q1 (final architecture): hybrid monorepo + product repos
- Q5b (data-sources): stays separate (P+D trait, multiple consumers expected)
- Q6 (standards distribution): hybrid (package for Python, propagation for shell)
- Q7 (monorepo layout): apps/ + packages/ industry standard
- Q8 (build tool): uv workspace + Makefile (no Nx/Turborepo/Bazel)
- Q9 (migration approach): big-bang weekend
- Q11 (name): jarvis-platform
- Q12 (history): tag-and-archive (clean start)
- Q13 (GitHub): create new repo, archive old 4
