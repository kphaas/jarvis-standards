# JARVIS Development Process

**Canonical source for cross-repo development workflow.**  
Last reviewed: 2026-04-17 · Review trigger: every 4 sessions or when a flow changes

---

## Core Principle — Sovereignty First

JARVIS is a private AI infrastructure designed to be resilient to external tool availability. External tools **augment** JARVIS capabilities. They do not **replace** them. Every workflow that depends on an external tool has a documented fallback that runs on JARVIS's own hardware.

If Microsoft revokes your Copilot seat tomorrow, if GitHub goes offline for a week, if the Claude API rate-limits your account — JARVIS keeps working. That is the bar.

---

## Sovereignty Tiers

Every tool and workflow is classified by dependency:

| Tier | Meaning | Examples |
|---|---|---|
| **Tier 1 — JARVIS-native** | Runs entirely on your hardware. Survives internet outage. | Brain, Sandbox, Air, Ollama, Postgres, Claude Code CLI, all `~/jarvis-*` scripts |
| **Tier 2 — JARVIS-controlled** | Runs on your hardware; requires external APIs gated through Gateway | Anthropic API calls, Perplexity API, Gemini API, Ollama model downloads |
| **Tier 3 — External, sovereign-fallback** | External tool with documented JARVIS-native replacement path | Copilot Cloud Agent, GitHub Actions CI |
| **Tier 4 — External, no fallback** | External dependency with no replacement | GitHub repo hosting itself (mitigated by self-hosted Gitea plan) |

**Rule:** Tier 4 dependencies require explicit architectural review before adoption. Today only GitHub itself is Tier 4; self-hosted Gitea on Brain is a planned mitigation.

---

## Development Flows

JARVIS supports 7 distinct development flows. Each lives in its own subdocument under `WORKFLOWS/`. The right flow depends on the task type, risk level, and available tools.

| Flow | Tier | File |
|---|---|---|
| Air direct-edit | Tier 1 | `WORKFLOWS/air_direct_edit.md` |
| Claude Code on Sandbox | Tier 1 | `WORKFLOWS/claude_code_sandbox.md` |
| Copilot Cloud Agent | Tier 3 | `WORKFLOWS/copilot_cloud_agent.md` |
| Forge pipeline | Tier 1 | `WORKFLOWS/forge_pipeline.md` |
| Self-hosted JARVIS agent | Tier 1 | `WORKFLOWS/jarvis_native_agent.md` (PLANNED) |
| Emergency hotfix | Tier 1 | `WORKFLOWS/emergency_hotfix.md` |
| Multi-repo refactor | Tier 1 | `WORKFLOWS/multi_repo_refactor.md` |

---

## Decision Matrix

Use this table to pick the right flow. Columns: task type, risk, recommended flow, fallback.

| Task Type | Risk | Recommended Flow | Fallback |
|---|---|---|---|
| Add a new feature route (pure code) | Low | Copilot Cloud Agent | Claude Code on Sandbox |
| Add a feature touching auth/JWT/middleware | **High** | Air direct-edit (manual) | Claude Code on Sandbox + human review |
| Write a SQL migration file | Low–Medium | Copilot Cloud Agent | Claude Code on Sandbox |
| Apply a migration to Brain DB | **High** | Air direct-edit via deploy script | Manual psql on Brain (human only) |
| Debug a live DB issue | Medium | Claude Code on Sandbox | Air direct-edit with SSH |
| Add a UI page | Low | Copilot Cloud Agent | Claude Code on Sandbox |
| Refactor across 1 repo | Low–Medium | Copilot Cloud Agent | Claude Code on Sandbox |
| Refactor across 2+ repos | Medium–High | Multi-repo refactor flow | Air direct-edit (manual, per-repo) |
| Add a test | Low | Copilot Cloud Agent | Claude Code on Sandbox |
| Write documentation | Low | Copilot Cloud Agent | Air direct-edit |
| Forge-driven feature (backlog → plan → build) | Low–Medium | Forge pipeline | Claude Code on Sandbox |
| Production outage fix | **Critical** | Emergency hotfix flow | Air direct-edit + manual deploy |
| Rotate a secret or key | **High** | Air direct-edit only | No AI agent allowed |
| Touch `~/.secrets` or JWT keypair | **High** | Air direct-edit only | No AI agent allowed |

**Risk indicators:**
- **Low** = pure application code, no security surface
- **Medium** = touches data layer, migrations, integration points
- **High** = touches auth, RLS, middleware, keys, secrets, migrations on live DB
- **Critical** = production is broken, time-to-fix matters

---

## Provenance Rules

All commits to `main` must have identifiable authorship:

- **Human commits** — Ken's identity (`Ken Haas <kennethphaas@gmail.com>`), signed where possible
- **Copilot Cloud Agent commits** — `copilot-swe-agent[bot]`, Verified signature from GitHub
- **Claude Code on Sandbox commits** — `Claude Code (Sandbox) <claude-code+sandbox@jarvis.local>`, unsigned but attributable
- **Forge pipeline commits** — `forge-agent[bot] <forge@jarvis.local>` (TODO: set up identity), Agent-Logs-Url trailer required

**Rule:** No commit author may impersonate a human when the work was done by an AI. Violations of this rule are classified as provenance bugs (see DEBT-019 for historical example).

---

## Fallback Triggers

When does a flow fall back to its alternate?

| Trigger | Response |
|---|---|
| Copilot Cloud Agent unavailable (MSFT revocation, GitHub outage, seat expired) | Use Claude Code on Sandbox for all tasks previously routed to Copilot |
| GitHub fully down | Use local git + deploy directly from Air via scripts (skip PR flow) |
| Anthropic API rate-limited/down | Use Ollama local models on Brain (degraded capability, no loss of function) |
| Brain Postgres down | Block all deploys; no workaround — restore Brain first |
| Tailscale mesh down | Block all deploys; no workaround — restore mesh first |
| Ken unavailable for review | Do not merge anything to main. Draft PRs wait. No autonomous merges. Ever. |

---

## Cross-Repo Consistency

All JARVIS repos follow the same core principles:

1. Commit scripts use `git add -A` + confirmation on new files (DEBT-019 remediation) — applies to `jarvisalpha_commit.sh`, `jarvisforge_commit.sh`, `familyvault_commit.sh`
2. Pull scripts are idempotent and safe to re-run
3. All secrets via `get_secret()` reading from `~/jarvis/.secrets` (or `~/.secrets` on Sandbox)
4. Node labels as plain text above command blocks (`▶ BRAIN —`, `▶ GATEWAY —`, etc.), never inside
5. Per-repo `CLAUDE.md` references this document as canonical process source
6. No hardcoded IPs, hostnames, URLs — use `node_addresses.py` / env vars

---

## Doc Lifecycle

This document has a defined review cadence to prevent drift:

- **Review frequency:** Every 4 sessions or when any flow changes, whichever comes first
- **Review owner:** Ken + whichever Claude session is active
- **Review action:** Re-read the doc, update the "Last reviewed" date, flag sections that no longer match reality, commit any changes
- **Staleness alert:** If date at top is >30 days old, any session MUST refresh before the doc is cited as authoritative

---

## Amendment Process

To add or change a flow:

1. Open a session with explicit goal "amend DEVELOPMENT_PROCESS.md"
2. Draft changes on Air
3. Validate the new/changed flow with Perplexity (optional but recommended for architectural changes)
4. Commit via jarvis-standards commit script (or manual commit)
5. Update per-repo CLAUDE.md references if scope changed
6. Next session opens with "new flows in effect" preamble

---

*Canonical source: github.com/kphaas/jarvis-standards/DEVELOPMENT_PROCESS.md*
