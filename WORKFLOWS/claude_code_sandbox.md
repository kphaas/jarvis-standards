# Workflow: Claude Code on Sandbox

**Tier 1 — JARVIS-native** · Primary AI agent for node-access tasks

---

## When To Use

- Live DB debugging (needs psql access to Brain)
- Migration apply + verify (needs SSH to Brain)
- LaunchAgent ops (needs launchctl)
- Log inspection across nodes
- Tasks that need to both read and write to live infrastructure
- When Copilot can't handle it due to its cloud isolation

## When NOT To Use

- Pure repo work with no live-system interaction — Copilot is faster and has cleaner provenance
- Touching secrets or keys — human-only
- High-risk surface (auth, middleware) — human-only or human-heavy review

## Participants

- **Sandbox machine** — repo at `/Users/jarvissand/<repo-name>/`
- **Claude Code CLI** — runs in Sandbox terminal with user `forge`
- **Ken on Air** — reviews output, approves commits (via pull script)

## Flow

1. Ken opens Claude Code session on Sandbox
2. Ken describes the task in natural language
3. Claude Code:
   - Checks sync state: `git fetch && git status` before any work
   - If drift detected: refuse to proceed, instruct Ken to sync Sandbox first
   - Creates a feature branch: `sandbox/<yyyy-mm-dd>-<slug>` (planned — see jarvis_native_agent.md for the full native-agent flow)
   - Edits files on Sandbox filesystem
   - Commits with repo-local identity `Claude Code (Sandbox) <claude-code+sandbox@jarvis.local>`
   - Pushes branch to origin
   - Outputs merge instructions for Ken to run on Air
4. Ken on Air: pulls branch, reviews diff, merges to main
5. Deploy flow resumes normally

## Authorship

- Commits authored by `Claude Code (Sandbox) <claude-code+sandbox@jarvis.local>`
- NOT `forge@jarvis-forge` or `jarvissand`
- Co-authored-by Ken trailer added when Ken's direction drove the change
- Requires: repo-local `git config user.name` + `user.email` set on Sandbox

## Current State (2026-04-17)

- **Branch-based flow not yet implemented** — currently Sandbox commits directly to main, which violates provenance rules (DEBT-019)
- Target state: branch-based flow as described above
- Implementation deferred to Session #08+ (jarvis_native_agent.md)

## Fallback

- If Sandbox is down: use Air direct-edit (slower but works)
- If Claude Code CLI broken: use Cursor on Sandbox via SSH (rare — requires manual coordination)
- If Sandbox has uncommitted work blocking pull: `git clean -fd && git reset --hard origin/main` (destructive, Ken approves)

## Provenance

- Commits clearly AI-authored via identity
- Agent-Logs-Url trailer recommended (TODO: wire Claude Code to emit this)
- Git log shows clear AI vs human split

## Risk Profile

- Medium risk (AI agent has full node access)
- Mitigation: branch-based flow + Ken reviews every merge
- High productivity for infrastructure-adjacent tasks

## Known Issues

- **DEBT-019** — commit script was silently dropping Sandbox-created files until fixed in Session #06
- **DEBT-026** — no automated drift detection between Sandbox and origin/main (planned for jarvis_native_agent.md)
- **DEBT-027** — Sandbox is both source and sink for code; full branch-flow not yet built
