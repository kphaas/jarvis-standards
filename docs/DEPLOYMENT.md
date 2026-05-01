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
| `jarvis-family` | B | Shipped via DEBT-027 (Session #08–09); pilot for new commit-script template Session #10 |
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

### 6.1 Rule 1 — Agent branches require PR review

**Settings → Branches → Add classic branch protection rule** (or use Rulesets — equivalent settings):

```
Branch name pattern: claude-code/** | forge/** | bot/**
```

| Setting | Value | Why |
|---|---|---|
| Require a pull request before merging | ✓ | Q1 — agents must always go through review |
| Required approvals | 1 | Human-must-approve for agent commits |
| Dismiss stale pull request approvals when new commits are pushed | ✓ | Force re-review if agent amends |
| Require review from Code Owners | Optional | Useful for repos with `CODEOWNERS` file |
| Require approval of the most recent reviewable push | ✓ | Prevents silent re-push past approval |
| Require status checks to pass before merging | ✓ | Lint + test + trailer-validation |
| Required checks | `lint`, `test`, `trailer-validation` (when CI ships) | Each must pass |
| Require branches to be up to date before merging | ✓ | Prevents merge-skew bugs |
| Require linear history | ✓ | Forces rebase-merge or squash-merge; no merge commits |
| Do not allow bypassing the above settings | ✓ | Rule applies to admins too |

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

### 15.3 Sandbox-specific

17. `~/jarvis/.secrets` on Sandbox — Sandbox uses `~/.secrets` (no jarvis subdir). Path difference is documented in §11.1
18. Hardcoded `100.124.172.14` (old Sandbox IP) anywhere — magic DNS `${SANDBOX_HOST}` only **[NEW from drift sweep]**
19. Hardcoded `jarvis-forge` machine hostname — current is `jarvis-sandbox` **[NEW from 2026-04-28 migration]**

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
