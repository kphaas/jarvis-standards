# DEPLOYMENT — operational runbook

How JARVIS services are packaged, deployed, and run; how repositories enforce the multi-writer coordination model.

**Last reviewed:** 2026-05-01 · **Review trigger:** every 4 sessions, when topology changes, or when an ADR amends this doc

**Implements:**
- ADR-0001 (Adopt Docker for service deployment)
- ADR-0002 (State native, compute containerized)
- ADR-0003 (Progressive secrets management)
- ADR-0004 (Alpha-5 execution standards)
- ADR-0005 (Adopt multi-writer coordination model)

**Audience:** primary reader is Ken (operator). Secondary reader is future-collaborator-or-future-Ken landing cold. Daily ops up top; first-time setup near the bottom.

---

## 1. 30-second summary

- **Eight repositories** spanning JARVIS: alpha (runtime), forge (dev pipeline), family, financial, council, print-copilot, standards, data-sources
- **Five machines** active: Brain (orchestrator), Gateway (cloud egress), Endpoint (UI), Sandbox (dev/forge runner), Air (dev only — never service node). Plus Unraid for stateful tier
- **Multi-writer coordination model** (ADR-0005): humans merge from any machine, agents always branch; uniform git author identity + dedicated `X-Machine` / `AI-*` trailers; agent-prefix branch namespace + GitHub branch protection
- **Trait system** maps each repo to a deployment pattern: `F` Fan-out, `B` Branch-safety, `P` PR-only, `D` Submodule-consumed
- **Docker for compute, native for state** (ADR-0002). Stateful services on Unraid; stateless app services on Macs via OrbStack
- All cross-machine addressing via Tailscale magic DNS — never hardcoded IPs
- All secrets via `get_secret()` reading from `~/jarvis/.secrets` (chmod 600, never committed)

---

## 2. Daily ops quick reference

One-screen reference for the most common tasks. Assumes machines + repos already set up (see §13 First-time setup if cold).

### 2.1 Commit a change

| Repo | Trait | How to commit |
|---|---|---|
| `jarvis-alpha` | F + B | Air: `bash ~/jarvis-alpha/scripts/jarvisalpha_commit.sh "msg"` (fan-out auto-deploys to Brain + Gateway + Endpoint + Sandbox). Sandbox-Claude-Code: branch + PR via `gh pr create` |
| `jarvis-forge` | F + B | Air: `bash ~/jarvis-forge/scripts/jarvisforge_commit.sh "msg"` (Sandbox auto-pull). Sandbox-Claude-Code: branch + PR |
| `jarvis-family` | B | Air: `bash ~/jarvis-family/scripts/familyvault_commit.sh "msg"`. Sandbox-Claude-Code: branch + push, then `bash ~/jarvis-family/scripts/familyvault_merge_branch.sh <branch>` from Air |
| `jarvis-council` | B | Same pattern as family (when scaffolded) |
| `jarvis-print-copilot` | B | Same pattern as family (when MS1 begins) |
| `jarvis-financial` | P | Always GitHub PR + `gh pr create` from any machine; merge via web UI or `gh pr merge` |
| `jarvis-standards` | P | Same as financial — GitHub PR flow |
| `jarvis-data-sources` | P + D | Same as standards — PR flow; consumers always pin to commit SHA |

### 2.2 Source environment for any session

```bash
source ~/jarvis/infra/env/.node_addresses
source ~/jarvis/.secrets
```

Run this at the top of any shell session that needs to talk to JARVIS nodes.

### 2.3 Common Docker operations

```bash
cd ~/jarvis/infra
docker compose -f compose/<machine>.yml up -d        # start
docker compose -f compose/<machine>.yml ps           # what's running
docker compose -f compose/<machine>.yml logs -f svc  # tail logs
docker compose -f compose/<machine>.yml exec svc sh  # shell in
docker compose -f compose/<machine>.yml down         # stop (volumes persist)
docker compose -f compose/<machine>.yml down -v      # ⚠️ destroys volumes
```

### 2.4 Common verification checks

```bash
# Health of a Brain service
curl -sk https://${BRAIN_HOST}:8186/health | python3 -m json.tool

# All five JARVIS machines reachable?
for h in BRAIN GATEWAY ENDPOINT SANDBOX UNRAID; do
  v="${h}_HOST" ; nc -zv "${!v}" 22 2>&1 | head -1
done

# Trailer parsing on a commit
git log -1 --format=%B | git interpret-trailers --parse
```

### 2.5 Common branch + PR flow

```bash
# Human-driven feature
git checkout -b feature/<topic>
# ... work ...
git push -u origin feature/<topic>
gh pr create --base main --title "..." --body-file <bodyfile>

# Agent-driven (Claude Code on Sandbox)
git checkout -b claude-code/<purpose>/<topic>
# ... work ...
git push -u origin claude-code/<purpose>/<topic>
gh pr create --base main --title "..." --body-file <bodyfile>
# Branch-protection rule will require human review before merge
```

### 2.6 Source of truth — where to look

| Question | Where |
|---|---|
| What's the current decision on X? | `docs/adr/ADR-NNNN-*.md` |
| How do I deploy / commit / configure? | This file |
| What's the schema of the prompt library / templates? | `scripts/README.md` + `scripts/_templates/` |
| What's the dev process (review, PR, etc.)? | `DEVELOPMENT_PROCESS.md` |

---

## 3. Topology — current 5-machine reality

```
┌────────────────────────────────────────────────────────────────┐
│  UNRAID — STATEFUL TIER (the pet)                              │
│  Postgres 16 + pgvector + TimescaleDB · NATS JetStream · Redis │
│  Loki + Grafana · Portainer · Backup target · Obsidian vault   │
│  (Some services still on Brain native today — see ADR-0002     │
│   for the state-native vs compute-containerized split)         │
└────────────────────────────────────────────────────────────────┘
                           ↕  Tailscale mesh
       ┌──────────┬──────────────┬──────────────┐
       │          │              │              │
   ┌───┴───┐ ┌────┴────┐  ┌──────┴──────┐ ┌─────┴─────┐
   │ BRAIN │ │ GATEWAY │  │  ENDPOINT   │ │  SANDBOX  │
   │       │ │         │  │             │ │           │
   │ alpha │ │ cloud   │  │ nginx :4100 │ │ jarvis-   │
   │ brain │ │ adapter │  │ React UI    │ │ forge     │
   │ :8186 │ │ :8283   │  │ (alpha UI)  │ │ :5001     │
   │       │ │ Claude  │  │             │ │           │
   │ post- │ │ Perplx  │  │             │ │ Claude    │
   │ gres  │ │ Gemini  │  │             │ │ Code +    │
   │ ollama│ │ UDM Pro │  │             │ │ CI runner │
   │ tempo-│ │ proxy   │  │             │ │           │
   │ ral   │ │         │  │             │ │           │
   └───────┘ └─────────┘  └─────────────┘ └───────────┘
                                                ↕
                                          ┌─────┴─────┐
                                          │    AIR    │
                                          │           │
                                          │ Cursor +  │
                                          │ commits   │
                                          │           │
                                          │ NEVER a   │
                                          │ service   │
                                          │ node      │
                                          └───────────┘
```

| Machine | Hardware | User | Tailscale | Role |
|---|---|---|---|---|
| Brain | Mac Studio M2 Ultra 192GB | `jarvisbrain` | `100.64.166.22` / `brain.${TAILNET}` | Orchestrator: FastAPI :8186, Postgres `jarvis_alpha`, Ollama, Temporal |
| Gateway | Mac Mini M4 16GB | `gate` | `100.98.18.51` / `gateway.${TAILNET}` | Cloud adapter: Claude / Perplexity / Gemini on :8283; UDM Pro proxy |
| Endpoint | Mac Mini M1 24GB | `jarvisendpoint` | `100.87.223.31` / `endpoint.${TAILNET}` | UI :4100 via nginx |
| Sandbox | Mac Mini M4 16GB | `jarvissand` | `100.69.178.17` / `sandbox.${TAILNET}` | Dev / forge runner :5001, Claude Code execution, CI |
| Air | MacBook Air | `swetagurnani` | (laptop, not always-on) | Dev only — Cursor IDE, commits. Never a service node |
| Unraid | NAS | — | `100.x.x.x` / `unraid.${TAILNET}` | Stateful tier (planned per ADR-0002 Phase 5.1) |

### 3.1 Recent topology changes — what's stale to be aware of

- **2026-04-20** Gateway hardware swap M1 → M4. User was `infranet`, now `gate`. IP changed from `100.112.63.25` to `100.98.18.51`. Old port `:8282` retired in favor of `:8283`.
- **2026-04-21** Sandbox IP drift to `100.69.178.17`. **Magic DNS `sandbox.${TAILNET}` is preferred** over IP in configs — survives any future hardware swap.
- **2026-04-28** Sandbox migration: hostname changed from `jarvis-forge` (machine-name) to `jarvis-sandbox`. Some commit scripts referenced old hostname; fixed in jarvis-family Session #09 (commit `f0c6789`). Other repos may have similar drift — see §15 forbidden patterns / drift sweep.

---

## 4. Writer roles & coordination model

Implements ADR-0005 in operational terms. See ADR-0005 for the architectural reasoning.

### 4.1 Who writes from where

| Writer | Identity at git layer | Allowed on `main` directly | Path required |
|---|---|---|---|
| Ken on Air | `Ken Haas <kennethphaas@gmail.com>` | Yes | Either |
| Ken on Sandbox (Cursor) | `Ken Haas <kennethphaas@gmail.com>` | Yes | Either |
| Ken on Brain / Gateway / Endpoint (rare ops) | `Ken Haas <kennethphaas@gmail.com>` | Discouraged but allowed | Either |
| Claude Code on Sandbox | `Ken Haas <kennethphaas@gmail.com>` | **Never direct** | Branch + PR + human merge |
| forge agent pipeline | `Ken Haas <kennethphaas@gmail.com>` | **Never direct** | Branch + PR + human merge |
| GitHub Actions | bot identity | Workflow-defined | Signed commits, declared workflows |

**The asymmetry is the point.** Humans-merge-anywhere preserves Ken's workflow flexibility (Sandbox-heavy as work shifts that direction). Agents-always-branched preserves the safety boundary that bb37103 surfaced as missing.

### 4.2 Trailer scheme

Every commit carries provenance via dedicated trailers in the commit body. The git author identity is uniform (`Ken Haas <kennethphaas@gmail.com>`); the trailers carry origin.

```
<commit subject>

<body>

X-Machine: sandbox
AI-Agent: claude-code
AI-Model: claude-opus-4-7
```

| Trailer | When | Values |
|---|---|---|
| `X-Machine` | Always | `air` \| `sandbox` \| `brain` \| `gateway` \| `endpoint` |
| `AI-Agent` | Only if an agent invoked `git commit` | `claude-code` \| `forge-pipeline` \| `cursor-composer` \| `github-actions` |
| `AI-Model` | Only if `AI-Agent` is set and model is known | e.g. `claude-opus-4-7`, `claude-sonnet-4-6` |

**`AI-Agent` is for the actor of the commit, not the source of the content.** If you (human) paste agent-drafted content and run `git commit` yourself, the agent did NOT commit — only you did. Don't add `AI-Agent` in that case. Mention the agent in the commit body as narrative attribution if helpful, but trailers are reserved for actor-of-commit.

**Why not `Co-Authored-By`:** see ADR-0005 §2.2. Industry critique converged on dedicated `AI-*` trailers in 2026 (Codex CLI PR #11617, Aider, OpenCode).

### 4.3 Branch namespace

| Origin | Pattern | Example |
|---|---|---|
| Human | `feature/<topic>` `fix/<topic>` `chore/<topic>` `audit/<topic>` `docs/<topic>` | `feature/multi-writer-arch` |
| Claude Code | `claude-code/<purpose>/<topic>` | `claude-code/fix/rls-audit` |
| forge pipeline | `forge/<purpose>/<topic>` | `forge/build/f-046-deployment` |
| GitHub Actions | `bot/<workflow>/<topic>` | `bot/release/v1.2.3` |

`<purpose>` matches the human verb categories: `feature`, `fix`, `chore`, `audit`, `docs`. `<topic>` is short kebab-case description.

### 4.4 Verification commands

```bash
# Parse trailer on most recent commit
git log -1 --format=%B | git interpret-trailers --parse

# Find all agent commits
git log --grep="^AI-Agent:" --format="%h %ai %s"

# Find all commits from a specific machine
git log --grep="^X-Machine: sandbox" --format="%h %ai %s"

# Find all human commits (no agent trailer)
git log --grep="^AI-Agent:" --invert-grep --format="%h %ai %s"
```

---

## 5. Repository trait map

### 5.1 The four traits

| Trait | Code | Meaning | Operational impact |
|---|---|---|---|
| Fan-out | `F` | Commit script auto-deploys to multiple nodes via SSH | Multi-node SSH, halt-on-fail, deploy plan banner, `JARVIS_SKIP_<NODE>=1` env flags |
| Branch-safety | `B` | Sandbox / agents must branch (DEBT-027 pattern) | Host detection in commit script, drift check, merge helper script |
| PR-only | `P` | No local commit script; GitHub PR review IS the gate | Branch protection rules + status checks; `gh` CLI is the operator |
| Submodule-consumed | `D` | Pinned to commit SHA by consumers; never `main` | `CONSUMERS.md` documents who pins what; CI checks consumer pins quarterly |

### 5.2 Per-repo assignment

| Repo | Traits | Adoption status (as of 2026-05-01) |
|---|---|---|
| `jarvis-alpha` | F + B | F shipped (TD-88, commit `35d34fc`); B pending Session #11 |
| `jarvis-forge` | F + B | F shipped; B pending Session #12 |
| `jarvis-family` | B | **SHIPPED Session #10** — PR #12 squash `0d50e53`; first repo adopting `commit_core` template; pilot caught 3 latent bugs (jarvis-standards PRs #6, #7, #8) |
| `jarvis-council` | B | Pending — adopt B from day one when MS1 begins |
| `jarvis-print-copilot` | B | Pending — adopt B from day one when MS1 begins |
| `jarvis-financial` | P | GitHub PR + `gh` CLI active; branch protection rules pending Session #13 |
| `jarvis-standards` | P | This PR + branch protection rules pending Session #14 |
| `jarvis-data-sources` | P + D | Branch protection + `CONSUMERS.md` pending Session #17 |

### 5.3 What "adopting" a trait means

- **F**: repo has `<repo>_commit.sh` generated from `commit_core.template.sh` with `@@HAS_FANOUT@@=true`, plus per-node SSH targets configured in `propagate.config`
- **B**: repo has DEBT-027 host check in commit script + branch protection rule on `claude-code/**` / `forge/**` / `bot/**` patterns
- **P**: repo has branch protection rule on `main` (no force-push, linear history) + status checks (lint, test, trailer-validation)
- **D**: repo has `CONSUMERS.md` listing all known consumer pins + quarterly drift audit GitHub Action

---

## 6. GitHub branch protection — exact settings

Apply this to **every** JARVIS repository. Branch protection is the GitHub-layer enforcement of ADR-0005's Q1 + Q3.

### 6.1 Agent branches — no ruleset (per RULESET_CANONICAL v2)

Apply **no** branch protection rule or ruleset to any of the agent-branch patterns:

```
refs/heads/claude-code/**
refs/heads/cursor/**
refs/heads/copilot/**
refs/heads/forge/**
refs/heads/bot/**
```

The absence of rules is the policy. Agents push directly, force-push to rewrite history mid-PR, and delete branches at merge time without server-side friction. The PR-review and status-check gates required by ADR-0005 Layer 1 are enforced at the **`main` boundary** (see §6.2), not on the agent-branch namespace itself — that boundary is where agent commits actually try to reach `main`, so it is where the gates belong.

This corrects the v1 design (TD-X34 v1, rolled out and reverted 2026-05-05) which placed PR-review and status-check rules on the agent-branch namespace. Those rules, when applied to a ruleset *targeting* agent branches, mean "to merge changes INTO an agent branch, you need a PR / passing checks" — which blocks the very direct-push iteration loop the rules were supposed to enable. See ADR-0005 Amendment §6.1.1 → "Discovery during rollout (2026-05-05)" for the post-mortem.

### 6.1.1 Force-push semantics on agent branches **[per ADR-0005 Amendment 2026-05-05]**

Force-push to agent branches is permitted because §6.1 places no rule that would block it. This realizes the §6.1.1 amendment carve-out automatically: the carve-out's intent ("force-push allowed on agent branches with open PRs, preserving PR purpose, PR review still gates merge to `main`") is satisfied because nothing prohibits it server-side, and the `main` ruleset (§6.2) blocks any unreviewed change from reaching `main`.

`main` keeps full force-push prohibition per §6.2 — the carve-out applies to agent branches only.

The canonical ruleset spec is in `docs/policy/RULESET_CANONICAL.md` v2. Apply it via the rollout runbook (TD-X38 v2 follow-up).

### 6.2 Rule 2 — `main` branch invariants

```
Branch name pattern: main
```

| Setting | Value | Why |
|---|---|---|
| Require a pull request before merging | **OFF for F/B trait repos**, **ON for P trait repos** | Q1 humans-merge-anywhere for F/B; P repos use PR review as the gate |
| Restrict deletions | ✓ | `main` cannot be deleted |
| Require linear history | ✓ | No merge commits — squash or rebase only |
| Block force pushes | ✓ | Prevents history rewrite |
| Require signed commits | OFF (until Phase 5c per ADR-0003) | Future enhancement |

The asymmetry is deliberate. F/B trait repos (alpha, forge, family, council, print-copilot) have local commit scripts that enforce safety; `main` is open to direct push by humans. P trait repos (financial, standards, data-sources) have no commit script, so the GitHub PR review is the only gate.

### 6.3 Audit checklist — quarterly

Branch protection drift (someone disables a rule in a panic) is the #1 way ADR-0005 silently breaks. Audit every quarter:

```bash
# For each JARVIS repo, run:
gh api repos/kphaas/<repo>/branches/main/protection --jq '
  {
    requires_linear_history: .required_linear_history.enabled,
    blocks_force_push: .allow_force_pushes.enabled | not,
    requires_pr: (.required_pull_request_reviews // null) != null,
    required_status_checks: (.required_status_checks.contexts // [])
  }'
```

Compare against expected values per repo trait. Any drift is a P1 to fix.

### 6.4 Rule creation procedure (manual, GitHub web UI)

1. Open repo → **Settings** (top right)
2. Left sidebar → **Branches**
3. Click **Add classic branch protection rule** (or **Add ruleset** if you prefer Rulesets — both work)
4. Enter pattern from §6.1 or §6.2
5. Check the boxes per the table
6. Scroll down → **Create**
7. Verify by attempting a direct push to a `claude-code/` branch as an admin — should be blocked

Repeat per repo. There is no GitHub-native bulk apply for branch protection across repos; you set this up once per repo. Time per repo: ~3 min.

---

## 7. Per-repo adoption procedure

Use this when adopting ADR-0005 in a repo for the first time.

### 7.1 Steps

1. **Verify trait assignment** in §5.2. Is this repo F + B, B-only, P, or P + D?
2. **Configure GitHub branch protection** per §6.1 and §6.2. Time: ~3 min.
3. **Generate commit script from template** (for F or B trait):
   ```bash
   cd ~/jarvis-standards
   bash scripts/propagate_scripts.sh --target <repo>
   ```
   This generates `<repo>_commit.sh` from `commit_core.template.sh` with the right `@@VAR@@` substitutions.
4. **Smoke-test the new commit script** locally before any push:
   ```bash
   cd ~/<repo>
   git checkout -b feature/adopt-adr-0005-commit-script
   bash scripts/<repo>_commit.sh "test: smoke ADR-0005 commit script"
   git log -1 --format=%B | git interpret-trailers --parse
   # Expected: X-Machine: <machine>
   ```
5. **Open PR adopting the script** — humans review the diff
6. **Merge to main**
7. **Verify trailer parses on the merged commit** (proves end-to-end)
8. **Document adoption in repo `CHANGELOG.md` or handoff** — date, ADR reference, smoke-test result

### 7.2 Smoke-test checklist

Before considering adoption complete, run:

- [ ] `git log -1 --format=%B | git interpret-trailers --parse` outputs the expected trailers
- [ ] Branch protection rule blocks a test direct push to `claude-code/test-block`
- [ ] Branch protection rule allows a human direct push to `feature/test-allow` (for F/B trait repos)
- [ ] Existing CI (lint, test) still passes against the new commit script
- [ ] Old commit script is removed or marked deprecated
- [ ] `propagate.config` lists this repo with the right trait

### 7.3 Rollback procedure

If the new script breaks something post-merge:

1. **Immediate:** revert the merge commit (`gh pr revert <pr-number>` or web UI)
2. **Restore old commit script** from git history (`git checkout <pre-adoption-sha> -- scripts/<repo>_commit.sh`)
3. **File issue** in `kphaas/jarvis-standards` with title `[adoption regression] <repo> ADR-0005`
4. **Pause adoption rollout** for other repos until root cause identified
5. **Fix in template, not in repo** — update `commit_core.template.sh` and re-propagate

Do NOT patch the per-repo script directly. It's generated; manual edits will be overwritten on next propagation.

### 7.4 Lessons from family pilot (Session #10)

`jarvis-family` was the first repo to adopt the new `commit_core` template (PR #12 squash `0d50e53`). The pilot was deliberately careful: read the existing hand-written script, compare to generated output, smoke test before commit, verify trailer parsing, etc.

**The pilot caught three real bugs in jarvis-standards itself:**

| PR | Bug | Why it matters |
|---|---|---|
| `#6` (squash `2a936c9`) | Engine couldn't iterate empty `extras[@]` array under `set -u` | Would have broken every consumer using the original 6-field schema |
| `#7` (squash `8798f63`) | `check_sync.template.sh` hostname guard stale (Apr 28 Sandbox migration) | Would have silently regressed Sandbox commits on family |
| `#8` (squash `179c6ef`) | Engine's blank-line-based meta-block stripping destroyed PR #7's docstring | Documentation contract was load-bearing whitespace; replaced with explicit count-based stripping |

Each bug looked fine in template review and would have shipped silently if family had adopted via a quick "run the engine, commit the output" flow. Slowing down for verification is what the pilot was for.

**Recommended pattern for future adoptions** (alpha Session #11, forge Session #12, council/print-copilot when scaffolded):

1. Read the existing hand-written commit script line-by-line. Catalog every behavior.
2. Diff vs the would-be-generated output. Flag every behavioral gap.
3. If gaps are real (not cosmetic): fix the template in jarvis-standards FIRST, merge, re-propagate. Do not patch the consumer.
4. Smoke test the generated script (invoke without args; verify USAGE message + exit 1).
5. Then stage + commit + push the adoption PR.

This is slower than "trust and ship" but cheaper than "ship and roll back across multiple repos."

**Anti-pattern to avoid:** running `propagate_scripts.sh --initial` against multiple repos in one go. The flag overrides the GENERATED-header safety guard for ALL targets, not just the one you're adopting. During Session #10 family pilot, this caused alpha + forge to receive partial scaffolding (`scripts/_lib/` + `scripts/check_sync.sh`) that had to be manually cleaned up. Recommendation: add a `--target <repo>` flag to the engine to scope `--initial` to one repo at a time. Filed as DEBT-054 (non-blocking; manual cleanup is fast).

---

## 8. Commit scripts & template propagation

### 8.1 Architecture

```
jarvis-standards/scripts/
├── _templates/                          ← source of truth
│   ├── commit_core.template.sh          ← unified commit script (NEW, this PR)
│   ├── check_sync.template.sh           ← pre-commit drift validator
│   └── ruff_detect.template.sh          ← sourceable lib for ruff resolution
├── propagate_scripts.sh                 ← propagation engine
├── propagate.config                     ← per-repo template + trait mapping
└── README.md
```

Templates use `@@VAR@@` placeholder syntax. `propagate_scripts.sh` substitutes vars per repo defined in `propagate.config`, writes the result to the consumer repo with a `# GENERATED FROM jarvis-standards` header for overwrite-safety.

### 8.2 `propagate.config` schema

Pipe-delimited mapping. Fields 1–6 are required and positional. Fields 7+ are optional `KEY=VALUE` pairs (no `@@` wrapping in the config file — just the variable name) that become `@@KEY@@` substitutions in the template body.

```
template|target_repo|target_subpath|REPO_NAME|REPO_PATH|MAIN_BRANCH[|KEY=VALUE...]
```

Required fields:

- `template` — filename in `_templates/`
- `target_repo` — directory name under `$HOME`
- `target_subpath` — relative path within the consumer repo
- `REPO_NAME` — repo display name (substituted as `@@REPO_NAME@@`)
- `REPO_PATH` — absolute path; **must use `$HOME/...` not `/Users/...`** (consumer repos run on multiple nodes with different usernames)
- `MAIN_BRANCH` — typically `main`

Example rows:

```
check_sync.template.sh|jarvis-family|scripts/check_sync.sh|jarvis-family|$HOME/jarvis-family|main

commit_core.template.sh|jarvis-family|scripts/familyvault_commit.sh|jarvis-family|$HOME/jarvis-family|main|COMMIT_SCRIPT_NAME=familyvault_commit.sh|HAS_FANOUT=false|HAS_BRANCH_SAFETY=true|HAS_UI_BUILD=true|HAS_SMOKE_CHECK=true|HAS_AUTO_BRANCH=true|FANOUT_NODES=|SMOKE_CHECK_CMD=scripts/smoke_health.sh|MERGE_HELPER_SCRIPT_NAME=familyvault_merge_branch.sh
```

The first row uses no extras (existing 6-field rows continue to work — backward compat). The second row sets all trait switches for the family pilot. See §8.3 for the full switch catalog.

### 8.3 Trait switches in `commit_core.template.sh`

The template uses bash conditionals on trait values, allowing one source of truth across F-trait, B-trait, and F+B-trait repos.

| Switch | Type | Behavior |
|---|---|---|
| `HAS_FANOUT` | F-trait | SSH-fan-out to `FANOUT_NODES` after push (halt-on-fail per TD-88) |
| `HAS_BRANCH_SAFETY` | B-trait | Agent on `main` → hard refusal; humans on `main` from non-Air → warn (or auto-branch if `HAS_AUTO_BRANCH=true`) |
| `HAS_UI_BUILD` | repo-specific | Run `npm run build` in `ui/` before commit |
| `HAS_SMOKE_CHECK` | repo-specific | Run `SMOKE_CHECK_CMD` (e.g. `scripts/smoke_health.sh`) as pre-commit health check |
| `HAS_AUTO_BRANCH` | repo-specific | On `main` from non-Air machine, auto-create `feature/<date>-<slug>` branch + return to `main` after push (preserves family's pre-ADR-0005 workflow UX) |

Companion vars (used only when their corresponding switch is `true`):

- `FANOUT_NODES` — space-separated node list (e.g. `"brain gateway endpoint sandbox"`)
- `SMOKE_CHECK_CMD` — path to smoke check script, relative to repo root
- `MERGE_HELPER_SCRIPT_NAME` — name of merge helper script (printed in instructions after auto-branch)
- `COMMIT_SCRIPT_NAME` — name of the generated commit script itself (used in self-references)

Example template logic:

```bash
if [[ "$HAS_FANOUT" == "true" ]]; then
  # Run fan-out logic — SSH to FANOUT_NODES with halt-on-fail
fi

if [[ "$HAS_BRANCH_SAFETY" == "true" ]] && [[ "$IS_AGENT" == "true" ]] && [[ "$CURRENT_BRANCH" == "$MAIN_BRANCH" ]]; then
  die "Agent cannot commit directly to main — use claude-code/<purpose>/<topic> branch"
fi
```

Adding a new trait switch requires:
1. Add the bash logic in the template
2. Document it in this table
3. Set the value in every repo's row in `propagate.config` (engine fails loudly if a repo's row doesn't supply a referenced var — keeps drift visible)

### 8.4 Generation procedure

```bash
cd ~/jarvis-standards
git checkout main && git pull
bash scripts/propagate_scripts.sh --dry-run        # see what would change
bash scripts/propagate_scripts.sh                  # generate (default mode — only overwrites GENERATED files)
bash scripts/propagate_scripts.sh --initial        # one-time first-rollout (overwrites hand-written files)
# Result: each consumer repo gets an updated script with the GENERATED header
```

Use `--initial` exactly once per consumer repo when first adopting a template (replaces a hand-written script). After initial rollout, default mode is sufficient — the engine refuses to overwrite hand-edited files unless `--initial` is re-passed (drift safety).

### 8.5 Drift detection

A consumer repo's commit script is considered "drifted" if it has been hand-edited after generation (the `# GENERATED FROM jarvis-standards` header includes a hash of the template at generation time).

```bash
bash scripts/propagate_scripts.sh --check
# Reports drift across all consumer repos; exit non-zero if any drift
```

Run this before every standards-repo release. Quarterly is the minimum cadence.

---

## 9. Compose & Docker

This section largely preserves the existing DEPLOYMENT.md content from 2026-04-19. Updates are flagged with **[UPDATED]**.

### 9.1 Compose file organization

```
jarvis-infra/
├── compose/
│   ├── unraid.yml          # Postgres, NATS, Redis, observability, Portainer
│   ├── brain.yml           # Alpha services (post-Alpha-5 containerization)
│   ├── gateway.yml         # Cloud adapter, JWT edge   [UPDATED — was caddy/family/jwt]
│   ├── endpoint.yml        # nginx, React UI
│   └── sandbox.yml         # forge dashboard, CI runner    [UPDATED — was forge.yml]
├── env/
│   ├── .node_addresses     # Tailscale hostnames — committed
│   └── .env.*.example      # committed templates; real .env files NEVER committed
└── README.md
```

**[UPDATED] On the `forge.yml` → `sandbox.yml` rename:** the machine was renamed from `jarvis-forge` to `jarvis-sandbox` on 2026-04-28. Compose file follows the machine name. References in shell scripts should use `${SANDBOX_HOST}`, never the legacy `${FORGE_HOST}`.

### 9.2 Naming

- Compose project name = machine name: `name: jarvis-brain` in `brain.yml`
- Container names = `<project>-<service>`: `jarvis-brain-postgres`

### 9.3 Image pinning — mandatory

Never use `:latest`. Always pin to a specific tag. Prefer digest-pinning for production-critical services.

```yaml
# ✅ Good
image: postgres:16.4-alpine
image: redis:7.4.1-alpine

# ✅ Better — digest-pinned (immutable)
image: postgres:16.4-alpine@sha256:abc123...

# ❌ Bad
image: postgres:latest
image: redis
```

**Rationale:** `:latest` is a moving target. Reproducible deploys require reproducible images. Digest pinning prevents supply-chain surprises from tag re-pushes.

**Update cadence:** pull new versions explicitly, per service, during planned maintenance — not on every restart.

### 9.4 Registry strategy

#### Today (acceptable)

- Pull from Docker Hub with pinned tags
- Cache locally on each Mac (Docker default)

#### Planned (Sovereignty First hardening)

- Self-hosted `registry:2` on Unraid (planned in ADR-0002 Phase 5.2)
- Mirror all pinned base images to Unraid at adoption time
- Services pull from `registry.${TAILNET}:5000/postgres:16.4-alpine` instead of Docker Hub
- If Docker Hub goes down, JARVIS keeps running

**Trigger for hardening:** first Docker Hub outage that affects us, or explicit sovereignty audit.

### 9.5 Docker runtime per machine

| Machine | Runtime | Auto-start | Rationale |
|---|---|---|---|
| Unraid | Built-in Docker | On boot | Unraid's default Docker plugin |
| Brain | OrbStack | At login | Fastest on Apple Silicon, no licensing cost |
| Gateway | OrbStack | At login | Same |
| Endpoint | OrbStack | At login | Same |
| Sandbox | OrbStack | At login | Same  **[UPDATED — was forge]** |
| Air | OrbStack | Manual | Laptop; dev only |

Docker Desktop is acceptable if OrbStack doesn't fit a contributor's situation. Both run the same containers.

### 9.6 Portainer admin UI

Portainer runs on Unraid. All Docker endpoints (Unraid + every always-on Mac) register agents so Portainer shows everything from one dashboard.

#### Access

- URL: `https://${UNRAID_HOST}:9443`
- Auth: admin account at first boot, password in 1Password
- ⚠️ Portainer admin = effectively root on all JARVIS Docker hosts. Long random password, never shared.

#### Per-Mac agent install

```bash
docker run -d \
  --name portainer_agent \
  --restart=always \
  -p 9001:9001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  portainer/agent:latest
```

Then in Portainer UI, add each as a "Docker Standalone — Agent" environment using `${BRAIN_HOST}:9001`, `${SANDBOX_HOST}:9001`, etc.

### 9.7 Compose conventions

#### Standard top-matter

Every compose file starts with:

```yaml
# =============================================================================
# <MACHINE> — <role summary>
# =============================================================================
# See docs/DEPLOYMENT.md for conventions. Never hardcode hostnames — always
# source .node_addresses + .secrets before `docker compose up`.
# =============================================================================

name: jarvis-<machine>

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

x-restart: &default-restart
  restart: unless-stopped
```

#### Every service includes

- `container_name` for predictable logs/exec targets
- `restart: unless-stopped` (via the anchor)
- `healthcheck` with realistic thresholds
- `logging: *default-logging` (bounds disk use)
- Explicit `volumes` and `networks`

#### Networking

- Internal: Docker bridge network per machine, named `backend`
- Cross-machine: services bind to `127.0.0.1:<port>` on the host; Tailscale hostname is how other machines reach them
- Never expose a service on `0.0.0.0` unless it's the Gateway's public-facing edge

### 9.8 Ollama on Brain — native exception

Ollama runs natively on Brain (NOT in a container). Reason: needs Apple Metal GPU access. Docker Desktop's Linux VM cannot provide GPU access on Mac. Running Ollama in Docker = 10-50× slower CPU-only fallback.

```bash
brew install ollama
brew services start ollama
# Ollama binds to 127.0.0.1:11434
# Containerized services on Brain reach it via host.docker.internal:11434
```

This exception is documented in ADR-0002. Other services may NOT bypass containerization without an ADR.

---

## 10. Node addressing

Standard: per `DEVELOPMENT_PROCESS.md` § Cross-Repo Consistency #6 — no hardcoded IPs, hostnames, or URLs.

### 10.1 The `.node_addresses` file

Lives at `infra/env/.node_addresses`. Committed. Plain shell-sourceable:

```bash
# Canonical Tailscale magic-DNS hostnames for JARVIS nodes.
# Update here; everything else references these variables.

export TAILNET=tail40ed36.ts.net

export BRAIN_HOST=brain.${TAILNET}
export GATEWAY_HOST=gateway.${TAILNET}
export ENDPOINT_HOST=endpoint.${TAILNET}
export SANDBOX_HOST=sandbox.${TAILNET}     # [UPDATED — magic DNS jarvis-sandbox preferred over IP]
export AIR_HOST=air.${TAILNET}
export UNRAID_HOST=unraid.${TAILNET}

# Service ports (stable across JARVIS)
export ALPHA_BRAIN_PORT=8186
export ALPHA_GATEWAY_PORT=8283
export ALPHA_UI_PORT=4100
export FORGE_PORT=5001
export POSTGRES_PORT=5432
export REDIS_PORT=6379
export NATS_PORT=4222
export NATS_HTTP_PORT=8222
```

### 10.2 Magic DNS preference

**Always prefer magic DNS hostname over IP.** Tailscale magic DNS resolves the current IP for a node — survives any future hardware swap. The 2026-04-20 Gateway swap and 2026-04-21 Sandbox IP drift would have been zero-touch if all references had been to magic DNS.

✅ Good: `ssh sandbox` (resolves to current IP)
❌ Bad: `ssh 100.69.178.17` (will silently break next IP drift)

### 10.3 Usage in compose files

```yaml
# ✅ Good — references env var
environment:
  POSTGRES_URL: postgresql://user:pass@${UNRAID_HOST}:${POSTGRES_PORT}/jarvis_alpha

# ❌ Bad — hardcoded
environment:
  POSTGRES_URL: postgresql://user:pass@unraid.tail40ed36.ts.net:5432/jarvis_alpha
```

### 10.4 Usage in shell + Python

```bash
# Source at the top of any session referencing nodes
source ~/jarvis/infra/env/.node_addresses
ssh "${SANDBOX_HOST}"
nc -zv "${UNRAID_HOST}" "${POSTGRES_PORT}"
```

```python
# Python — read from env via node_addresses.py per repo
import os
TAILNET = os.environ["TAILNET"]
BRAIN_HOST = f"brain.{TAILNET}"
SANDBOX_HOST = f"sandbox.{TAILNET}"
```

---

## 11. Secrets — `get_secret()` pattern

Standard: per `DEVELOPMENT_PROCESS.md` § Cross-Repo Consistency #3 — all secrets via `get_secret()` reading from `~/jarvis/.secrets`.

### 11.1 The secrets file

Lives at `~/jarvis/.secrets` on Brain / Gateway / Endpoint / Air, and `~/.secrets` on Sandbox (note the path difference). Mode `600`. **Never committed.** Shell-sourceable:

```bash
# ~/jarvis/.secrets (or ~/.secrets on Sandbox)
# Real values. Generate with: openssl rand -hex 32

export ALPHA_PIN=...
export ALPHA_SERVICE_TOKEN=...
export ALPHA_BUDDY_TOKEN=...
export POSTGRES_ALPHA_PASSWORD=...
export POSTGRES_FINANCIAL_PASSWORD=...
export REDIS_PASSWORD=...
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export PERPLEXITY_API_KEY=pplx-...
export GEMINI_API_KEY=...
export GITHUB_TOKEN=ghp-...
```

### 11.2 Usage in compose

Do NOT put secrets in compose files directly. Compose reads them from the shell environment at `up` time:

```bash
source ~/jarvis/infra/env/.node_addresses
source ~/jarvis/.secrets
docker compose -f compose/brain.yml up -d
```

In compose:
```yaml
services:
  postgres:
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_ALPHA_PASSWORD}  # pulled from env
```

### 11.3 Bootstrap

First-time setup:
```bash
mkdir -p ~/jarvis
touch ~/jarvis/.secrets
chmod 600 ~/jarvis/.secrets
# Paste generated secrets; do NOT commit
```

### 11.4 Rotation

See `DEVELOPMENT_PROCESS.md` § Decision Matrix — secret rotation is **Air direct-edit only**, no AI agent allowed. Rotate individual values in `~/jarvis/.secrets`, then restart affected services.

The `scripts/rotate_secret.py` tool (jarvis-alpha) supports automation for service tokens with `requires_alter_role:false`. DB password rotation pending TD-134.

### 11.5 Per-service secrets splitting (Phase 5.0 plan)

ADR-0003 plans to split the monolithic `~/jarvis/.secrets` into `~/jarvis/secrets.d/<service>.env` per-service files. Not yet shipped. Status: planned for Alpha-5 Phase 5.0.

---

## 12. Common operations

All commands assume `.node_addresses` and `.secrets` are sourced.

### 12.1 Service operations

```bash
docker compose -f compose/brain.yml up -d                   # start
docker compose -f compose/brain.yml ps                      # status
docker compose -f compose/brain.yml logs -f postgres        # tail logs
docker compose -f compose/brain.yml exec postgres psql -U jarvis_alpha    # shell in
docker compose -f compose/brain.yml pull && docker compose -f compose/brain.yml up -d   # pull updates
docker compose -f compose/brain.yml down                    # stop (volumes persist)
docker compose -f compose/brain.yml down -v                 # ⚠️ destroys volumes
```

### 12.2 Repo operations

```bash
# Commit (F + B trait — alpha as example)
bash ~/jarvis-alpha/scripts/jarvisalpha_commit.sh "msg"

# Commit (B trait — family as example)
bash ~/jarvis-family/scripts/familyvault_commit.sh "msg"

# Branch + PR (P trait — financial / standards / data-sources)
git checkout -b feature/<topic>
# ... work ...
git push -u origin feature/<topic>
gh pr create --base main --title "..." --body-file <bodyfile>
```

### 12.3 Branch protection audit (quarterly)

```bash
for repo in jarvis-alpha jarvis-forge jarvis-family jarvis-financial jarvis-standards jarvis-council jarvis-data-sources jarvis-print-copilot; do
  echo "=== $repo ==="
  gh api repos/kphaas/$repo/branches/main/protection --jq '
    {
      requires_linear_history: .required_linear_history.enabled,
      blocks_force_push: .allow_force_pushes.enabled | not,
      requires_pr: (.required_pull_request_reviews // null) != null
    }' 2>/dev/null || echo "  (no protection rule or no access)"
done
```

---

## 13. First-time setup

For collaborator-or-future-Ken landing cold. Ordered: machine → repos → verification.

### 13.1 Per-machine setup (one-time)

```bash
# 1. Clone jarvis-infra (assumed to live at ~/jarvis/infra/)
mkdir -p ~/jarvis
cd ~/jarvis
git clone git@github.com:kphaas/jarvis-infra.git infra

# 2. Source environment
source ~/jarvis/infra/env/.node_addresses

# 3. Create secrets file (paste from password manager)
touch ~/jarvis/.secrets
chmod 600 ~/jarvis/.secrets
# Edit and paste from 1Password / Bitwarden / your store

# 4. Install OrbStack (or Docker Desktop)
brew install --cask orbstack
open /Applications/OrbStack.app
# Accept license, set to launch at login

# 5. Install gh CLI (if not present)
brew install gh
gh auth login

# 6. Install ruff (if Python repos in scope)
brew install uv
uv tool install ruff
```

### 13.2 Per-repo setup

For each repo you'll work in:

```bash
cd ~
git clone git@github.com:kphaas/<repo>.git
cd <repo>

# Verify branch protection config matches §6
gh api repos/kphaas/<repo>/branches/main/protection --jq '.'

# Review the trait assignment in DEPLOYMENT.md §5.2

# If the repo has a commit script (F or B trait), make it executable
chmod +x scripts/*_commit.sh
```

### 13.3 Verification — end-to-end smoke test

```bash
# Source env
source ~/jarvis/infra/env/.node_addresses
source ~/jarvis/.secrets

# Reach all JARVIS machines via SSH
for h in BRAIN GATEWAY ENDPOINT SANDBOX UNRAID; do
  v="${h}_HOST"
  echo -n "${h}: "
  nc -zv "${!v}" 22 2>&1 | head -1
done

# Reach Brain alpha API health
curl -sk https://${BRAIN_HOST}:8186/health | python3 -m json.tool

# Open Forge dashboard
open https://${SANDBOX_HOST}:5001
```

If all of the above succeed, you have a working JARVIS dev setup.

---

## 14. Backup integration

Docker volumes used for state (Postgres, NATS JetStream) are backed up nightly via Unraid's backup plugin. Specific schedule and retention live in `BACKUP.md` (planned standard).

For Postgres specifically:
```bash
# UNRAID — nightly cron
docker compose -f compose/unraid.yml exec -T postgres \
  pg_dumpall -U jarvis_alpha | gzip > /mnt/user/backups/pg_alpha_$(date +%Y%m%d).sql.gz
```

Pre-Alpha-5 (today): Postgres still runs natively on Brain, not in a container. Backup goes through `pg_dump` on Brain via cron, ships dumps to Unraid SMB mount. Backup script lives in jarvis-alpha repo.

---

## 15. Forbidden patterns

### 15.1 Docker / Compose

1. `image: postgres:latest` — no floating tags
2. Hardcoded hostnames or IPs in compose files (use Tailscale magic DNS)
3. Plaintext secrets in compose files (use env vars sourced from `~/jarvis/.secrets`)
4. `0.0.0.0` port binds on any machine except Gateway's public edge
5. Kubernetes manifests or Helm charts — scope is plain Compose only
6. Running stateful services on Macs (they belong on Unraid per ADR-0002)
7. Running Ollama in Docker (breaks Metal GPU access — see §9.8)
8. `--privileged` containers (security footgun)
9. `network_mode: host` without an ADR
10. Pulling images from unofficial registries without an ADR

### 15.2 Multi-writer / commits **[NEW per ADR-0005]**

11. Direct push to `main` from an agent (Claude Code, forge pipeline, GitHub Actions). Use branch + PR
12. `Co-Authored-By: <agent>` trailer for AI agent attribution. Use `AI-Agent:` instead
13. Hand-editing a generated commit script (look for `# GENERATED FROM jarvis-standards` header). Edit the template, re-propagate
14. Committing without `X-Machine` trailer (CI status check rejects it)
15. Branching outside the namespace conventions in §4.3 — agents on `feature/*` or humans on `claude-code/*`
16. Bypassing branch protection rules via "skip checks" (defeat-in-depth violation)
17. Using owner-bypass on a required CI check for non-emergency reasons. Bypass exists for genuine emergencies (production hotfix, broken CI blocking everything else). Routine bypass — e.g. "the lint job is flaky, just merge" — is a §15.2 violation; fix the check, do not skip it. Bypass usage MUST be logged in the session handoff (§15.2.3 owner-bypass discipline)

**Not a violation:** force-push to an agent branch (`claude-code/**`, `cursor/**`, `copilot/**`, `forge/**`, `bot/**`) on an open PR for in-flight rebase-and-fix. See §6.1.1 and ADR-0005 Amendment 2026-05-05. Force-push to `main` (#11 above) and cross-namespace overwrites remain prohibited.

### 15.2.1 Enforcement mechanisms

§15.2 is enforced at the local-commit boundary by two git hooks shipped from
`scripts/_templates/hooks/` in this repo, complementing the server-side
GitHub branch protection (Layer 1 in ADR-0005). The local hooks catch
violations before they reach a remote and are deliberately layered with the
server-side checks — neither is sufficient alone.

| Mechanism | Source | Enforces |
|---|---|---|
| `commit-msg` hook (TD-X22) | `scripts/_templates/hooks/commit-msg` | §15.2 #12 — strips the Cursor agent's `Co-authored-by: Cursor <cursoragent@cursor.com>` trailer; non-blocking; pattern is anchored and does not affect human Co-authored-by lines |
| `pre-commit` hook — main block (TD-X25) | `scripts/_templates/hooks/pre-commit` | §15.2 #11 — blocks any commit whose `HEAD` is `main` or `master`; allows detached HEAD so rebase / cherry-pick keep working |
| `pre-commit` hook — namespace (TD-X24) | `scripts/_templates/hooks/pre-commit` (extended) | §15.2 #15 — agents on `feature/*` are rejected (exit 1); humans on agent namespaces (`claude-code/*` / `cursor/*` / `copilot/*`) get a stderr warning + audit log entry but the commit proceeds. Asymmetric on purpose: humans get the override hatch, agents do not. |
| PR-base staleness check (TD-X23) | `scripts/_templates/workflows/pr-base-staleness.yml` | §15.2 #11 indirect — a stale PR base reflects abandoned work whose merge into `main` carries silent-conflict + lost-context risk. Posts an idempotent comment ≥14 days, fails the required check ≥30 days. |
| `scripts/sync_check.sh` | `scripts/sync_check.sh` | Optional read-only inspector. Reports per-repo branch / dirty state / `main` ahead-or-behind / branch base age; exit 1 if anything needs attention so it can chain into shell aliases. No fetch, no mutation. |
| `scripts/install_hooks.sh` | `scripts/install_hooks.sh` | Bootstrap: copies both hooks into a target repo's `.git/hooks/`, prompts on conflict (override with `--force`) |

**Known gap.** Git stores hooks under `.git/hooks/`, which is outside the
working tree and **not tracked by the repo**. Every fresh clone starts with
no hooks installed, and propagation from outside the clone (e.g.
`propagate_scripts.sh`) cannot fix this — the bootstrap step
(`install_hooks.sh`) must run inside each clone. Operationally: any new
clone of a JARVIS repo on Sandbox or Air must be followed by
`/path/to/jarvis-standards/scripts/install_hooks.sh` before the first commit.

The PR-base staleness workflow is propagated by copying
`scripts/_templates/workflows/pr-base-staleness.yml` into each consuming
repo's `.github/workflows/`. Phase B3 will land that copy across the 6
target repos; today only `jarvis-standards` itself runs the workflow.

### 15.2.2 Identity detection

The TD-X24 namespace enforcement reads identity to decide whether to
reject, warn, or allow a commit on the current branch.

**Source of identity (in precedence order):**

1. `$JARVIS_AGENT` env var, when set to one of:
   - `human` — Ken or another person at the keyboard
   - `claude-code` — Claude Code CLI
   - `cursor` — Cursor IDE / Composer (reserved; recognized even though
     not currently emitted by Cursor itself)
   - `copilot` — GitHub Copilot Cloud Agent (reserved)
2. Hostname-based fallback (when env var is unset):

   | Hostname matches | Identity |
   |---|---|
   | `*sandbox*` / `*jarvis-sandbox*` | `claude-code` |
   | `*macbook*` / `*air*` | `human` |
   | anything else | `unknown` (treated as human) |

`HOOK_HOSTNAME_OVERRIDE` overrides the hostname for tests.

**Emergency human override on Sandbox.** Sandbox defaults to `claude-code`,
so a human running a hand commit on Sandbox in a `claude-code/*` branch is
fine, but a human committing on a `feature/*` branch from a Sandbox shell
will be rejected — the hook can't distinguish a human at the keyboard from
an agent invocation. Override for that command:

```
JARVIS_AGENT=human git commit -m '…'
```

The warning path (human on `claude-code/*` etc.) is the inverse case: an
operator working a hot fix in an agent's namespace. The hook does not
block — stderr gets a one-line warning and `~/.jarvis/namespace_violations.log`
gets a tab-separated audit row (`timestamp \t repo \t branch \t identity \t action`).

### 15.2.3 CI/CD substrate

A trio of complementary mechanisms keeps every JARVIS clone close to
`main`, every commit linted and secret-free, and every PR gated by the
same CI matrix. All three are propagated from `jarvis-standards` and
adopted per repo via the install scripts described in §15.2.1.

| Mechanism | TD | Source | Role |
|---|---|---|---|
| Polling sync daemon | TD-X27 | `scripts/_templates/sync_daemon.sh` + `scripts/_templates/launchagents/com.jarvis.sync_daemon.plist.template` | Long-lived LaunchAgent on Sandbox + Air. Every interval (default 300s) walks every clone under `$HOME/jarvis-*`, fetches `origin` read-only, and fast-forwards local `main` when (and only when) the working tree is clean and `ahead==0`. Pull-based GitOps per ADR-0007. Logs to `~/.jarvis/sync_daemon.log`; never rebases, never resolves conflicts. |
| Pre-commit framework | TD-X28 | `scripts/_templates/.pre-commit-config.yaml` + `scripts/_templates/.secrets.baseline` + `scripts/install_pre_commit.sh` | pre-commit.com framework with three hook sources: `ruff` (lint + auto-fix), `ruff-format`, Yelp `detect-secrets` (audited against `.secrets.baseline`), and a `local` repo entry that reruns the JARVIS namespace + main-block hook (TD-X24 + TD-X25) so the framework's takeover of `.git/hooks/pre-commit` does not silently drop §15.2 #11 / #15 enforcement. |
| Uniform CI workflow | TD-X29 + TD-X32 + TD-X35 + TD-X48 + TD-X48 v2 | `scripts/_templates/workflows/ci.yml` | Four parallel jobs on every PR + `main` push: `lint` (ruff check + format check), `typecheck` (mypy if configured), `test` (pytest if configured), `secret-scan` (detect-secrets baseline audit). Each Python job gracefully skips when its config is absent. Aggregator job `ci-pass` is the single required-status-check name in branch protection. **Workspace-aware sync (TD-X32):** test + typecheck detect `[tool.uv.workspace]` in the root `pyproject.toml` and add `--all-packages` to `uv sync` when present so workspace siblings install. **Dev-group-aware sync (TD-X35):** the same two jobs detect `[dependency-groups]` (PEP 735) or `[tool.uv.dev-dependencies]` (legacy uv) and add `--group dev` only when present — repos that put pytest in `[project.optional-dependencies]` instead (e.g. financial) no longer fail with `Group `dev` is not defined`. Repos with no root `pyproject.toml` skip both jobs entirely. Lint is unaffected because `uv tool run ruff` operates on the filesystem. **Integration-marker filter (TD-X48):** the test job's pytest invocation defaults to `-m "not integration"` — tests requiring external services (DB, Redis, network) MUST register `@pytest.mark.integration` and are skipped in default CI to keep PR-time signal fast and substrate-portable. Repos override via the GitHub repo-level variable `JARVIS_PYTEST_MARKERS` (set to `""` to run everything, or e.g. `"not integration and not slow"` to add exclusions). Integration suites run via a separate workflow (TD-X50, future). **Exit-5 handling (TD-X48 v2):** when the marker filter excludes every collected test (repos whose suites are 100% integration-marked, e.g. family), pytest exits 5 ("no tests collected"). The test step captures pytest's exit code, treats 5 as success with a `::notice::` annotation, and propagates every other code unchanged. See `docs/policy/CI_CONVENTIONS.md` for the convention. |

**Why pull-based, not webhook-push.** Webhook-push from GitHub Actions to
Sandbox + Air was considered and rejected. Air is a laptop and is asleep
or off the network most of the day; a webhook would silently drop on
delivery failure and the operator wouldn't notice until the drift was
weeks deep. A polling daemon retries on every cycle until it reaches the
remote. ArgoCD / Flux took the same architectural turn at scale for the
same reasons. ADR-0007 is the lock.

**Owner-bypass discipline.** Ken is repo owner on every JARVIS repo and
can bypass any required status check via GitHub's "Bypass" branch
protection rule. The mechanism exists for genuine emergencies — production
hotfix, CI itself broken — and using it for anything else is a §15.2 #17
violation. Whenever bypass IS used, the session handoff must record
which PR, which check was bypassed, and why. The bypass log lives in
`docs/handoffs/` so future audits can trace it.

**Sync daemon configuration (TD-X30).** `install_sync_daemon.sh` reads
two install-time env vars:

| Env var | Default | Effect |
|---|---|---|
| `SYNC_DAEMON_INTERVAL` | `300` | Seconds between cycles. Must be a positive integer; the installer rejects anything else. The value is substituted into the rendered plist's `EnvironmentVariables.SYNC_DAEMON_INTERVAL` so the running LaunchAgent inherits it. |
| `JARVIS_INSTALL_SKIP_LAUNCHCTL` | unset | Test-only escape hatch — when set to `1`, the installer renders the plist and stages the daemon at `~/.jarvis/sync_daemon.sh` but skips the `launchctl bootstrap` / `enable` / `kickstart` steps. Production callers leave this unset. |

The daemon body is staged at `~/.jarvis/sync_daemon.sh` (outside any
source repo) so re-running the installer never dirties the
`jarvis-standards` working tree. Earlier installs may have left a copy
at `~/jarvis-standards/scripts/sync_daemon.sh`; running
`uninstall_sync_daemon.sh` removes both that legacy copy and the
canonical staged script.

### 15.3 Sandbox-specific

18. `~/jarvis/.secrets` on Sandbox — Sandbox uses `~/.secrets` (no jarvis subdir). Path difference is documented in §11.1
19. Hardcoded `100.124.172.14` (old Sandbox IP) anywhere — magic DNS `${SANDBOX_HOST}` only **[NEW from drift sweep]**
20. Hardcoded `jarvis-forge` machine hostname — current is `jarvis-sandbox` **[NEW from 2026-04-28 migration]**

---

## 16. Observability

Services emit structured logs per `LOGGING.md`. Container stdout is captured by Docker's json-file driver (bounded by the logging anchor in §9.7). Promtail on each Mac ships logs to Loki on Unraid. See `docs/OBSERVABILITY.md` (planned) for the full stack.

JSON log schema (every service):
```
{"timestamp": "...", "level": "...", "service": "...", "node": "...", "message": "..."}
```

No bare `echo` or `print` in production scripts — always structured JSON.

---

## 17. Related standards

- `ADR-0001` — Adopt Docker for service deployment
- `ADR-0002` — State native, compute containerized
- `ADR-0003` — Progressive secrets management
- `ADR-0004` — Alpha-5 execution standards
- `ADR-0005` — Adopt multi-writer coordination model **[implemented in §4-§8 of this doc]**
- `DEVELOPMENT_PROCESS.md` — Sovereignty First principle, Cross-Repo Consistency rules
- `LOGGING.md` — structured logging via `get_logger()`
- `SECURITY.md` (planned) — secrets rotation, access controls
- `OBSERVABILITY.md` (planned) — Prom / Loki / Tempo / Grafana stack
- `BACKUP.md` (planned) — schedule + retention

---

## 18. Amendment

Changes to this standard require:

1. Update this doc
2. Update the "Last reviewed" date
3. If the change affects a live decision, update or supersede the relevant ADR
4. Branch and PR per ADR-0005 §4.3 (`feature/<topic>` for human, `claude-code/<purpose>/<topic>` for agent)
5. Merge after review
6. Next JARVIS session opens with "new deployment standard in effect"

Operational changes (e.g. a new repo joining the trait map, a node IP changing) are amendments. Architectural changes (e.g. moving Postgres back to Macs) require a new ADR that supersedes the relevant prior ADR — this doc gets updated as a consequence, not as the driver.

---

*Canonical source: github.com/kphaas/jarvis-standards/docs/DEPLOYMENT.md*
