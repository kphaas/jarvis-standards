# Workflow: Air Direct-Edit

**Tier 1 — JARVIS-native** · Default flow for high-risk work

---

## When To Use

- Any task touching auth, JWT, middleware, RLS policies
- Secret rotation, key generation
- Production hotfixes
- Any work where Ken wants full manual control
- When Copilot is unavailable and Claude Code isn't appropriate (e.g., touching secrets)

## When NOT To Use

- Routine repo work (route additions, docs) — use Copilot Cloud Agent instead
- Live DB debugging — use Claude Code on Sandbox (it has node access)
- Long autonomous work — humans get tired; AI agents don't

## Participants

- **Ken** — writes/edits code in Cursor on Air
- **Air machine** — repo lives at `/Users/swetagurnani/<repo-name>/`
- No AI agent involved in this flow by definition

## Flow

1. Ken opens Cursor on Air, edits files
2. Ken commits via repo's commit script:
   - `bash ~/jarvis-alpha/scripts/jarvisalpha_commit.sh "msg"` for alpha
   - `bash ~/jarvis-forge/scripts/jarvisforge_commit.sh "msg"` for forge
   - `bash ~/jarvis-family/scripts/familyvault_commit.sh "msg"` for family
3. Commit script runs lint, build, commit, push (and sometimes auto-pull targets)
4. Ken runs repo's pull script on target nodes (Brain, Gateway, Endpoint, sometimes Sandbox)
5. Ken manually verifies deploy via health checks

## Authorship

- Commits authored by `Ken Haas <kennethphaas@gmail.com>`
- No bot identity involved

## Fallback

- If Air is down: no fallback for this flow; Air is the only dev machine. Consider adding a second dev machine (Session future).
- If commit script fails: manual `git add -A && git commit && git push` on Air is acceptable in emergency — skip lint, flag for follow-up

## Provenance

- Human commits only
- Standard git log shows `Ken Haas` as author
- No Agent-Logs-Url needed

## Risk Profile

- Slowest flow (manual work)
- Highest fidelity (human judgment at every step)
- Required for high-risk surface area
