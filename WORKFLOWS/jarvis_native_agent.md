# Workflow: Self-Hosted JARVIS Agent

**Tier 1 — JARVIS-native** · PLANNED — Session #08+

---

## Purpose

Provide a JARVIS-native equivalent of Copilot Cloud Agent's branch+PR flow. Runs entirely on Sandbox. Does not depend on GitHub cloud or Microsoft enterprise seat. Ensures sovereignty — if Tier 3 tools disappear, JARVIS retains the full capability.

## Target Capabilities

- Accept a task (natural language description, optionally referencing a Forge feature ID or an issue)
- Detect drift from origin/main before starting work
- Create feature branch `jarvis/<yyyy-mm-dd>-<slug>`
- Commit with proper bot identity (`Claude Code (Sandbox)`)
- Push branch to origin
- Open PR (via gh CLI since GitHub hosting remains Tier 4)
- Emit Agent-Logs-Url trailer pointing to local session log
- Support @-mention iteration (Ken comments → agent responds)

## Status

**NOT YET IMPLEMENTED.** Current Sandbox flow is ad-hoc.

## Why Build This When Copilot Works?

Sovereignty. Copilot is Tier 3. JARVIS must have a Tier 1 fallback for every significant capability. If Microsoft revokes your seat or GitHub Copilot Cloud Agent is deprecated, this flow steps in.

## Design Principles (for Session #08+)

1. Must not require GitHub Copilot infrastructure
2. Must work offline (local commits) and sync when network returns
3. Must produce commits indistinguishable (in quality of provenance) from Copilot's — Verified, attributable, auditable
4. Must integrate with Forge backlog
5. Must emit structured session logs that JARVIS can ingest into memory

## Open Design Questions

- GPG key setup for `claude-code+sandbox@jarvis.local` → enables Verified commits without GitHub bot key
- Session log format + storage (append to `~/jarvis-forge/logs/` or new Brain DB table)
- How to handle PR creation when gh CLI is not authenticated (need machine-level GitHub PAT specifically for Sandbox)
- Integration with Forge feature queue

## Dependency On Copilot

None. This flow is designed to work entirely without Copilot Cloud Agent.

## Priority

**Not urgent.** Copilot is working well. This is a sovereignty insurance policy. Build when: (a) Copilot stability becomes a concern, or (b) a clear gap emerges that Copilot can't fill.

## Deferred Until

Session #08 or later. Revisit after Session #07 (Forge integration) — Forge's improved state may reshape requirements for this agent.
