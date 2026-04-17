# Workflow: Emergency Hotfix

**Tier 1 — JARVIS-native** · Critical production fix

---

## When To Use

- Production is broken (family app down, Brain unresponsive, etc.)
- Time-to-fix matters more than process purity
- Normal flows are too slow

## When NOT To Use

- "Feels urgent" but actually isn't — default to Air direct-edit
- You're tired and might break more than you fix — wait for morning

## Participants

- **Ken on Air** — sole participant
- No AI agents (too slow, risk of wrong action)

## Flow

1. Identify the issue (manual debugging, log inspection)
2. Write the fix in Cursor on Air
3. Skip lint if necessary (flag for cleanup follow-up)
4. Commit with prefix `hotfix: <description>` so git log is scannable
5. Deploy immediately via pull script on affected nodes
6. Verify fix
7. **Within 24 hours:** write a follow-up commit cleaning up any shortcuts + update jarvis-standards if the incident revealed a process gap

## Authorship

- Ken as author
- Commit message `hotfix:` prefix makes it visible in git log
- Optional: squash+rename later if the fix was ugly

## Fallback

- If Air is down: SSH directly to affected node, edit in place (VERY last resort, flag immediately for follow-up commit to resync tree state)

## Post-Incident

- Always write a retrospective within 48 hours
- Retro captures: what broke, what fixed it, how detect earlier, what to change in process
- File in `jarvis-standards/incidents/YYYY-MM-DD-brief-name.md`

## Risk Profile

- High velocity, high cognitive load, high error potential
- Mitigation: strict post-incident review cadence
- Never use this flow for non-emergencies; it erodes discipline

## Known Anti-Patterns

- "Quick fix" that bypasses RLS — don't
- Touching secrets/keys under emergency pressure — find another path
- Multi-file changes under emergency — split into smaller fixes
- Merging without reviewing the diff — always read your own patch
