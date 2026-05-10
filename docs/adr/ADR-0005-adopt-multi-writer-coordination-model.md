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

## Amendments

### 2026-05-05 — Force-push semantics on agent branches (§6.1.1)

**Issue surfaced.** Phase 3 substrate propagation (jarvis-family PR #15) was blocked when the family ruleset's `non_fast_forward` rule on `claude-code/**` rejected a routine rebase-and-fix push on the PR's own branch. Other JARVIS repos (alpha, financial, council, print-copilot, data-sources, standards) lacked the equivalent ruleset and were silently *out of compliance with the literal §6.1 wording*, while inconsistently *aligned with the rule's intent*. The literal wording overshot.

**Carve-out.** The Layer 1 prohibition on force-push targets unreviewed merges to default branches. It does NOT prohibit in-flight history rewrites on the owner's own unmerged feature or agent branches. Specifically: the repo owner MAY force-push to `claude-code/**`, `cursor/**`, `copilot/**`, `forge/**`, and `bot/**` branches when (a) the branch has an open PR, (b) the rewrite preserves the PR's stated purpose, and (c) PR review still gates the merge into `main`. Force-pushing to `main`, force-pushing to a branch under another agent's namespace, or using force-push to circumvent PR review remain prohibited.

**Example.** Cursor on Air pushes `claude-code/td-x34-foo` with three commits. CI finds a mypy error. Cursor fixes the error and `git push --force-with-lease` to rewrite the branch tip. This is allowed: the PR is open, the rewrite preserves the PR's purpose (TD-X34), and the PR review will still happen pre-merge. Compare: Cursor force-pushes to `main` to "fix" history — prohibited in all cases. Or: a different agent force-pushes over Claude Code's `claude-code/**` branch — prohibited (cross-namespace overwrite).

**Operational implementation.** The canonical implementation lives in `docs/policy/RULESET_CANONICAL.md` v2. Two ruleset slots per repo: (1) a `main` ruleset carrying every gate — `pull_request`, `required_status_checks`, `required_linear_history`, `non_fast_forward`, `deletion`; (2) NO ruleset on agent-branch patterns. The §6.1.1 carve-out is realized by the *absence* of any rule on agent branches — force-push works because nothing prohibits it, while merge to `main` remains gated by the `main` ruleset.

**Trade-off accepted.** Agent branches have zero server-side enforcement under this architecture. Anyone with push access can rewrite, force-push, or delete an agent branch freely. Acceptable because (a) only the repo owner has push access to JARVIS repositories today, (b) the `main` ruleset blocks any unreviewed or unchecked change from reaching `main` regardless of what happens on agent branches first. If push access broadens, revisit via ADR amendment — see `RULESET_CANONICAL.md` §D for the path forward (`pull_request`-only ruleset on agent branches with `do_not_enforce_on_create: true` to gate merges *into* agent branches by non-owner actors).

**Discovery during rollout (2026-05-05).** A first-pass implementation (TD-X34 v1) applied a single ruleset *targeting* agent-branch namespaces with `pull_request`, `required_linear_history`, and `required_status_checks` rules. That implementation was rolled out to all 8 JARVIS repos and reverted within the same session after two design errors surfaced:

1. `required_status_checks` defaults `do_not_enforce_on_create: false`, blocking the initial push that creates a new branch matching the pattern. Patched live to set the flag `true`.
2. `pull_request` and `required_status_checks`, when applied to a ruleset *targeting* agent branches, mean "to merge changes INTO an agent branch, you need a PR / passing checks." Every direct push to `claude-code/foo` was treated as a "merge into the protected branch" requiring a PR — blocking the very iteration loop the carve-out was supposed to enable. Rules were applied to the wrong target.

The intent — *"agent commits go through PR before reaching `main`"* — is a `main`-branch invariant, not an agent-branch invariant. v2 (above) corrects the architecture: gates on `main`, no rules on agent branches. The eight v1 rulesets (IDs `15994778`, `15994780`, `15994782`, `15994783`, `15994784`, `15994793`, `15994794`, `15844036`) were DELETED before this amendment was finalized. v1 left no audit trail in `main` history because the spec PR (TD-X34 v1) was merged, not reverted; v2 revises the spec in place rather than spawning ADR-0005 Amendment v2. Lesson logged: when applying a new ruleset spec, immediately self-test by pushing a fresh branch to one of the affected repos. Silent drift between operational reality and a written spec is the failure mode this discipline is designed to prevent.

**Discovery 2026-05-05 (post-rollout, v2.1).** After TD-X38 v2 applied the `jarvis-main` ruleset to all 8 repos, PR #25 (the rollout handoff itself) was unmergeable: GitHub blocked it with "New changes require approval from someone other than the last pusher." `require_last_push_approval: true` (in §A1 `pull_request` parameters) is a separation-of-duties guard meaningful for teams — *the last pusher cannot be the only approver* — but vacuous for solo dev. Ken is both the last pusher and the only authorized approver on every JARVIS PR, so set to `true` the rule blocks every merge unconditionally. Flipped to `false` in v2.1 (TD-X43); all 8 rulesets PUT in place with the corrected payload (IDs preserved). Trade-off: the rule's anti-spoof intent is dropped; acceptable because solo dev. Per `RULESET_CANONICAL.md` §D, flip back to `true` when collaborators are added — at that point the rule recovers its meaning.

## §10 — Examples: `jarvis_branch` and `jarvis_pr` invocations

The Layer 3 branch namespace (above) and `scripts/jarvis_branch` together make the prefix the load-bearing signal for Layer 1 enforcement. Examples below cover the four valid prefixes, the error path, and where `jarvis_branch` fits relative to per-repo wrappers.

### Correct invocation per actor

```sh
# Agent work — JARVIS_AGENT=claude-code in the environment
jarvis_branch claude-code/<descriptor>
# Examples:
jarvis_branch claude-code/td-x33-trait-completion
jarvis_branch claude-code/fix/rls-audit-tail
jarvis_branch claude-code/slab4-rls-context-fleet

# Human-driven feature work
jarvis_branch feature/<descriptor>
jarvis_branch feature/m3-day-trading-agent

# Production fix — either actor
jarvis_branch hotfix/<descriptor>
jarvis_branch hotfix/auth-token-expiry-2026-05-08

# Non-feature maintenance — either actor
jarvis_branch chore/<descriptor>
jarvis_branch chore/bump-pyproject-deps
```

`jarvis_branch` enforces a clean working tree, switches to `main`, pulls `origin/main`, creates the new branch from main, and pushes with `-u origin`. After branch creation: edit, commit, then `jarvis_pr` (or `gh pr create`).

### Error path: missing prefix

A bare descriptor with no prefix is rejected:

```sh
$ jarvis_branch slab4-rls-context-fleet
ERROR: Branch name 'slab4-rls-context-fleet' must start with one of: feature/ claude-code/ hotfix/ chore/
$ echo $?
4
```

Exit code `4` is the prefix-rejection signal; per-repo wrappers (e.g. `jarvisalpha_commit.sh`) reuse the same code so callers can trap it uniformly.

### Trait-aware enforcement: P-trait must PR, F-trait can push direct

Layer 3 prefixes apply uniformly, but the consequence of skipping the branch step depends on the repo's traits:

| Trait | Repos | Direct push to `main` allowed? | Branch + PR required? |
|---|---|---|---|
| `F` Fan-out (alone) | (none currently) | Yes (humans only) | No |
| `B` Branch-safety | `jarvis-family`, `jarvis-council`, `jarvis-print-copilot` | No | Yes (Layer 1 / DEBT-027) |
| `F` + `B` | `jarvis-alpha`, `jarvis-forge` | No (Sandbox + agents) | Yes; fan-out runs **after** PR merge |
| `P` PR-only | `jarvis-financial`, `jarvis-standards` | No (everyone) | Yes; PR review IS the gate |
| `P` + `D` | `jarvis-data-sources` | No | Yes; consumers pin to merged SHA |

For F+B repos, agents must branch (Layer 1) AND fan-out is gated behind PR merge — the post-merge `*_deploy.sh` script enforces "on main + clean + HEAD == origin/main" before SSH'ing to nodes. For P-trait repos, no fan-out exists; the GitHub PR review IS the only deployment gate.

### Per-repo wrappers

Repos with custom commit pipelines (Ruff, UI build, fan-out) wrap `jarvis_branch` indirectly. Example: `jarvisalpha_commit.sh` does not call `jarvis_branch` itself — the human runs `jarvis_branch` once at the start of work, then `jarvisalpha_commit.sh` is invoked on the resulting prefixed branch. The wrapper's branch-guard re-checks the same prefix list and exit code (`4` for bad prefix, `1` for `main`) so the rule remains uniform whether enforced at branch-creation time or commit time. Fan-out is split out into the post-merge `jarvisalpha_deploy.sh` so the F-trait fan-out cannot run on an unreviewed commit.

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
