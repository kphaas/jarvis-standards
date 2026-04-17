# Workflow: Forge Pipeline

**Tier 1 — JARVIS-native** · Feature-queue-driven development

---

## When To Use

- Features that are already in the Forge backlog (F-### items)
- Work that benefits from: planner → runner → reviewer decomposition
- Cross-project features where Forge's per-project memory matters
- Scheduled or batched work

## When NOT To Use

- One-off urgent fixes (use Emergency Hotfix flow)
- Tasks not in the backlog (add to backlog first, then use this flow)
- Tasks requiring real-time human iteration (use Claude Code on Sandbox)

## Participants

- **Forge dashboard** — at `https://100.124.172.14:5001` on Sandbox
- **SQLite feature queue** — `~/jarvis-forge/memory/feature_queue.db`
- **Planner** (`planner.py`) — Claude API breaks feature into sub-tasks
- **Runner** (`runner.py`) — generates Cursor prompts per sub-task
- **Reviewer** (`reviewer.py`) — Claude checks acceptance criteria
- **Ken on Air** — runs Cursor prompts, reviews outputs

## Flow

1. Feature exists in Forge SQLite backlog with status `backlog`
2. Ken selects feature in Forge dashboard, moves to `planned`
3. Planner runs: feature description → sub-task list → workspace file
4. For each sub-task:
   - Runner generates Cursor prompt
   - Ken pastes prompt into Cursor on Air, runs it
   - Output committed via repo's commit script
5. Reviewer runs: output vs acceptance criteria → review.md
6. If approved: feature status → `deployed`
7. If not: back to planner with review feedback

## Authorship

- Commits authored by Ken (via Cursor) — currently indistinguishable from Air direct-edit
- **Provenance gap:** Forge-initiated commits should have Agent-Logs-Url trailer + forge task ID reference
- TODO: bot identity `forge-agent[bot] <forge@jarvis.local>` for auto-generated commits (planned Session #07)

## Integration With Other Flows

- Forge can delegate sub-tasks to Copilot Cloud Agent (planned) — issue gets auto-assigned to Copilot, PR gets linked back to forge feature
- Forge can delegate sub-tasks to Claude Code on Sandbox (current reality via Cursor prompts)
- Forge tracks cost and memory across delegations

## Fallback

- If Forge dashboard down: feature queue is SQLite, accessible via `sqlite3 ~/jarvis-forge/memory/feature_queue.db`
- If Claude API down: planner/reviewer use Ollama local models on Brain (degraded but functional)
- If Sandbox down: Forge dashboard inaccessible, but SQLite DB can be pulled to Air for manual feature management

## Provenance

- Currently weak — Forge-initiated commits look like Ken's direct work
- Remediation: Session #07 adds forge task ID to commit message + Agent-Logs-Url trailer

## Risk Profile

- Medium — depends on which downstream flow executes the sub-tasks
- Key risk: Forge can silently re-seed the backlog, causing duplicate features. Mitigate: seed script is idempotent.

## Known Issues

- FI-1 through FI-8 in Forge architecture doc
- No integration with Copilot yet (planned Session #07)
- No cost integration with Brain's aggregated cost tracker
