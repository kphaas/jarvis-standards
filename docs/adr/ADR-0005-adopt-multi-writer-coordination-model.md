# ADR-0005: Adopt multi-writer coordination model

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** Ken
- **Supersedes:** N/A
- **Related:** `DEPLOYMENT.md` (operational details — branch protection settings, commit-script trait switches, propagate.config schema, per-repo runbook); ADR-0001 (Docker adoption); ADR-0002 (state native, compute containerized); ADR-0003 (progressive secrets); DEBT-027 (jarvis-family Sandbox branch flow); TD-88 (jarvis-alpha multi-node fan-out, commit `35d34fc`); PR #2 in this repo (template propagation, squash `04c898b`)

---

## Context

JARVIS now spans **eight repositories** — `jarvis-alpha`, `jarvis-forge`, `jarvis-family`, `jarvis-financial`, `jarvis-standards`, `jarvis-council`, `jarvis-data-sources`, `jarvis-print-copilot` — with multiple writer identities operating against `main`:

- **Air** — Ken via Cursor IDE (`Ken Haas <kennethphaas@gmail.com>`)
- **Sandbox** — Ken via Cursor (same identity) AND Claude Code agent (different actor, same machine, same OS user `jarvissand`)
- **forge pipeline** — agent writes via planner / runner / reviewer
- **GitHub Actions** — automation writes for releases, version bumps

At the git layer today, Sandbox-Cursor (Ken driving) and Sandbox-Claude-Code (agent driving) are indistinguishable: same OS user, same hostname, same default git author. The bb37103 incident in Session #09 (jarvis-family) surfaced this when a Sandbox direct-to-`main` push by Claude Code violated the family DEBT-027 rule and was caught only because the machine-default `Ken Phaas` author identity didn't match the rest of `main`'s history (`Ken Haas`). Lucky catch, not architectural.

Without a coordination model, four problems compound:

1. **No safety boundary.** Agents can push directly to `main` on any repo where the commit script doesn't enforce branching.
2. **No provenance.** Six months later, `git log` cannot distinguish human-on-Sandbox from agent-on-Sandbox.
3. **No DRY.** Each repo invents its own commit-script conventions; eight commit scripts diverge over time.
4. **Stale standards.** `DEPLOYMENT.md` references retired machines (`forge`, `infra`); no canonical reference for the current 5-machine reality.

Three patterns are already shipped in adjacent ADRs and prior work:

- **DEBT-027** (jarvis-family) — Sandbox cannot push to `main`; must use `sandbox/<topic>` branch + Air merge via `familyvault_merge_branch.sh`. Validated through Session #08–#09 audit work.
- **TD-88** (jarvis-alpha) — multi-node fan-out commit script with halt-on-fail, Brain → Gateway → Endpoint → Sandbox order. Seven clean deploys, zero failures since shipping.
- **Template propagation** (this repo, PR #2) — `_templates/` source-of-truth, `propagate_scripts.sh` engine, `@@VAR@@` placeholders, `# GENERATED FROM jarvis-standards` overwrite-safety header. Family pilot squash `df66988`.

Industry direction (validated 2026-05-01 via web search):

- **Trunk-based development** is the universal big-tech standard — short-lived branches, branch protection on `main`, every commit deployable. References: <https://trunkbaseddevelopment.com/>, <https://www.atlassian.com/continuous-delivery/continuous-integration/trunk-based-development>.
- **AI agent commit attribution via dedicated trailers** is the 2026 emerging convention — Codex CLI [PR #11617 (Feb 2026)](https://github.com/openai/codex/pull/11617), Aider's `(aider)` author, OpenCode. Critique of `Co-Authored-By` overload: [Bence Ferdinandy (Dec 2025)](https://bence.ferdinandy.com/2025/12/29/dont-abuse-co-authored-by-for-marking-ai-assistance/), [Fabio Rehm (Mar 2026)](https://fabiorehm.com/blog/2026/03/02/our-coding-agent-commits-deserve-better-than-co-authored-by/) — `Co-Authored-By` was designed for humans who exchanged drafts; using it for AI agents adds fake email addresses and pollutes contributor graphs.

The decision must address all four problems and align with these patterns.

## Decision

JARVIS adopts a **three-layer multi-writer coordination model** across all repositories: humans may merge to `main` from any machine, agents must always work via prefixed branches with PR review, and all commits carry uniform author identity with provenance encoded in dedicated `X-Machine` and `AI-*` trailers. A **trait system** maps each repository to a deployment pattern (`F` Fan-out, `B` Branch-safety, `P` PR-only, `D` Submodule-consumed); the three universal layers apply regardless of trait.

### Layer 1 — coordination

Humans and agents have asymmetric permissions on `main`:

| Actor | Allowed on `main` | Path required |
|---|---|---|
| Ken on Air (Cursor) | Direct push or PR | Either |
| Ken on Sandbox (Cursor) | Direct push or PR | Either |
| Claude Code on Sandbox | **Never direct** | Branch + PR + human merge |
| forge agent pipeline | **Never direct** | Branch + PR + human merge |
| GitHub Actions | Declared workflows only | Bot identity, signed commits |

Enforcement is layered — branch protection rules (GitHub), commit-script context detection (env var `JARVIS_AGENT`), and CI trailer validation (status check) — so no single bypass route is fatal.

### Layer 2 — provenance

All commits use uniform git author identity `Ken Haas <kennethphaas@gmail.com>` regardless of machine. Origin is encoded via dedicated trailers in the commit body:

```
<commit subject>

<body>

X-Machine: sandbox
AI-Agent: claude-code
AI-Model: claude-opus-4-7
```

Trailer schema:

| Trailer | Required | Values | Purpose |
|---|---|---|---|
| `X-Machine` | Always | `air` \| `sandbox` \| `brain` \| `gateway` \| `endpoint` | Origin machine |
| `AI-Agent` | If agent committed | `claude-code` \| `forge-pipeline` \| `cursor-composer` \| `github-actions` | Tool identity |
| `AI-Model` | If `AI-Agent` present and known | e.g. `claude-opus-4-7`, `claude-sonnet-4-6` | Model identity |

`Co-Authored-By` is **not used** for agent attribution (per industry critique cited in Context). Trailers survive rebase, squash, and cherry-pick — they are commit-body content, not metadata.

### Layer 3 — branch namespace

| Origin | Pattern | Example |
|---|---|---|
| Human | `feature/<topic>` `fix/<topic>` `chore/<topic>` `audit/<topic>` `docs/<topic>` | `feature/multi-writer-arch` |
| Claude Code | `claude-code/<purpose>/<topic>` | `claude-code/fix/rls-audit` |
| forge pipeline | `forge/<purpose>/<topic>` | `forge/build/f-046-deployment` |
| GitHub Actions | `bot/<workflow>/<topic>` | `bot/release/v1.2.3` |

Branch protection rule applied uniformly to every repository: pattern `claude-code/** | forge/** | bot/**` requires PR + 1 approving review + status checks + linear history before merge to `main`. `main` itself blocks force-push and deletion; humans may direct-push (preserves Layer 1). Exact GitHub UI settings live in `DEPLOYMENT.md`.

### Trait system

Four traits classify repositories. Each repo has zero or more.

| Trait | Code | Meaning |
|---|---|---|
| Fan-out | `F` | Commit script auto-deploys to multiple nodes via SSH |
| Branch-safety | `B` | Sandbox / agents must branch (DEBT-027 pattern) |
| PR-only | `P` | No local commit script; GitHub PR review IS the gate |
| Submodule-consumed | `D` | Pinned to commit SHA by consumers |

Per-repo assignment:

| Repo | Traits |
|---|---|
| `jarvis-alpha` | F + B |
| `jarvis-forge` | F + B |
| `jarvis-family` | B |
| `jarvis-council` | B |
| `jarvis-print-copilot` | B |
| `jarvis-financial` | P |
| `jarvis-standards` | P |
| `jarvis-data-sources` | P + D |

Traits are independent, additive, and may be added via ADR amendment as new repos arise.

## Consequences

### Positive

- **Defense in depth.** Layer 1 enforced at three independent layers (branch protection, commit script, CI trailer check) — no single point of failure.
- **Forensic capability.** `git log --grep="^X-Machine: sandbox"` and `git log --grep="^AI-Agent:"` give one-command provenance queries that survive rebase / squash / cherry-pick.
- **DRY at the script layer.** Existing template propagation system in this repo generates per-repo commit scripts from a single source of truth; eliminates eight-way drift.
- **Industry-aligned.** Trailer scheme matches the 2026 direction set by Codex CLI / Aider / OpenCode. Branch namespace matches Codex's `codex/<session-id>` convention.
- **Future-proof.** Adding a new agent (Cursor Composer, GitHub Copilot Agent) requires only a new `AI-Agent` value and branch-namespace prefix — no architectural change.
- **Closes provenance gap.** Sandbox-Claude-Code and Sandbox-Cursor (same OS user) become distinguishable at the commit level via `AI-Agent` trailer.

### Negative

- **GitHub UI loss.** Dedicated `AI-*` trailers do not surface as avatars in PR contributors view. JARVIS audit trail lives in `git log`, not in PR UI.
- **Migration cost.** Existing commit scripts in alpha + forge + family must be re-generated from new template. Pilot in jarvis-family validates the approach before broader rollout.
- **Trailer enforcement is not git-native.** If an agent bypasses the commit script (raw `git commit`), the trailer is missing. Mitigated by CI status check on PRs, not eliminated.
- **Branch protection rule sprawl.** Every repo needs the identical rule configured by hand in GitHub UI; risk of drift. Mitigated by documenting exact settings in `DEPLOYMENT.md` with a manual audit checklist.

### Neutral

- **Implementation paced over multiple sessions.** This ADR ships with a jarvis-family pilot only; alpha + forge + financial + standards + council + print-copilot + data-sources adopt the model in subsequent sessions. Each adoption is a small PR following the same template.
- **Trait list is open.** New traits may be added via ADR amendment. Current four cover known cases.
- **Operational details live elsewhere.** Exact GitHub branch protection settings, commit-script trait switches, propagate.config layout are in `DEPLOYMENT.md` — not duplicated here. This ADR establishes WHAT is decided; the runbook explains HOW to apply it.

## Sovereignty First compliance

This ADR introduces no new external dependencies. All tools referenced are already in the JARVIS stack at their existing tier:

| Component | Tier | Fallback |
|---|---|---|
| Git | Tier 1 (native) | None needed — local-first |
| GitHub | Tier 3 (external SaaS) | Local-only via `git format-patch` + email; or self-hosted forge (Gitea / Forgejo) on Unraid |
| Cursor | Tier 3 (external SaaS) | vim + Claude API direct, or Helix |
| Claude Code | Tier 3 (external SaaS) | Manual coding via Cursor or vim; Aider as alternate agent |

The model itself **increases** sovereignty: it removes reliance on machine-specific git author identities (the only provenance signal pre-ADR) and replaces them with portable trailers that survive any git server. If GitHub is replaced or unavailable, the trailer-based provenance still works on a self-hosted forge.

## Alternatives considered

### Option A — Air-only merges (extend DEBT-027 to all repos)

Force every merge to come from Air. Rejected: forces context-switch to Air for every merge across all eight repos. Conflicts with stated direction of more Sandbox-driven work (Session #09). Air becomes a bottleneck and adds friction to actual workflow.

### Option B — Per-machine git author identity (status quo from bb37103)

Use `Ken Haas` on Air, `Ken Phaas` on Sandbox, etc. Rejected: distinguishes machines, not actors. `jarvissand`-on-Sandbox-via-Cursor and `jarvissand`-on-Sandbox-via-Claude-Code remain indistinguishable at the git author layer. Provenance gap unresolved.

### Option C — `Co-Authored-By: Claude Code <noreply@anthropic.com>` trailer

Use git's existing `Co-Authored-By` for AI agents. Rejected: per Bence Ferdinandy and Fabio Rehm critiques (cited in Context), this is abuse of `Co-Authored-By` semantic; fake-email risk is documented incident; pollutes contributor graphs. Industry trajectory (Codex CLI 2026, Aider, OpenCode) is dedicated `AI-*` trailers.

### Option D — Rigid four-class system (Fan-out / Branch-safety / PR-only / Submodule)

Each repo belongs to exactly one class. Rejected: some repos require multiple combined attributes (alpha needs both Fan-out AND Branch-safety; data-sources needs both PR-only AND Submodule). A class system forced unnatural single-class assignments. Trait model accommodates combinations naturally.

### Option E — Bespoke commit scripts per repo (no template)

Hand-write each commit script. Rejected: the `propagate_scripts.sh` engine in this repo (PR #2) was built exactly for this case. Bypassing it would re-create the eight-way divergence problem this ADR exists to solve.

### Option F — ADR is principles only; per-repo `CONTRIBUTING.md` applies them differently

Rejected: most flexible but weakest enforcement. Eight `CONTRIBUTING.md` files would diverge over time and re-create the DRY problem at a higher abstraction layer. Centralized model with template-driven implementation is stronger.

## Reversal conditions

Revisit this ADR if any of the following occur:

1. **Trailer scheme reversal in industry.** If the AI ecosystem converges on a different convention (e.g. RFC-standardized `AI-Assisted` header, GitHub-native API for agent identity), migrate trailer keys to match. Trailers are append-only — additive migration, no breaking change to existing logs.
2. **Branch protection enforcement gap.** If three or more agent commits land on `main` via missed branch-protection rules within any 90-day window, escalate enforcement (signed commits required, pre-receive hooks, agent-specific GPG keys).
3. **Trait model insufficient for new repo.** If a new repository requires behavior outside the four current traits AND the gap cannot be addressed by adding a fifth trait, reconsider whether the trait abstraction is the right shape.
4. **Provenance forensics fails in real incident.** If a commit-attribution question arises in a security or operational incident and `git log --grep` queries cannot resolve it, the trailer scheme is incomplete and must be amended.
5. **Template propagation friction exceeds bespoke-script cost.** If maintaining the template + propagation engine takes more time than maintaining eight bespoke commit scripts would, re-evaluate.

## References

- `DEPLOYMENT.md` (this repo) — operational runbook: branch protection settings, commit-script trait switches, propagate.config schema, per-repo adoption procedure
- `scripts/_templates/` (this repo) — template source of truth
- `scripts/propagate_scripts.sh` (this repo) — propagation engine
- `ADR-0001-adopt-docker-deployment.md` (this repo)
- `ADR-0002-state-native-compute-containerized.md` (this repo)
- `ADR-0003-progressive-secrets-management.md` (this repo)
- `ADR-0004-alpha5-execution-standards.md` (this repo)
- `DEVELOPMENT_PROCESS.md` (this repo) — Sovereignty First principle
- DEBT-027 (jarvis-family) — Sandbox branch flow enforcement
- TD-88 (jarvis-alpha) — Multi-node fan-out commit script (commit `35d34fc`)
- PR #2 (this repo) — Template propagation system (squash `04c898b`)
- Session #09 handoff (jarvis-family) — bb37103 incident analysis
- Trunk-Based Development canonical site: <https://trunkbaseddevelopment.com/>
- Atlassian — Trunk-based development reference: <https://www.atlassian.com/continuous-delivery/continuous-integration/trunk-based-development>
- Bence Ferdinandy — "Don't abuse Co-authored-by for marking AI assistance" (Dec 2025): <https://bence.ferdinandy.com/2025/12/29/dont-abuse-co-authored-by-for-marking-ai-assistance/>
- Fabio Rehm — "Our coding agent commits deserve better than Co-Authored-By" (Mar 2026): <https://fabiorehm.com/blog/2026/03/02/our-coding-agent-commits-deserve-better-than-co-authored-by/>
- Codex CLI commit attribution PR #11617 (merged Feb 2026): <https://github.com/openai/codex/pull/11617>
- git SubmittingPatches — `Co-Authored-By` semantic guidance: <https://git-scm.com/docs/SubmittingPatches>
- GitHub branch protection rules documentation: <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches>
