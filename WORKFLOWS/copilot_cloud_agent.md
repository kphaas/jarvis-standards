# Workflow: Copilot Cloud Agent

**Tier 3 — External, sovereign-fallback** · Preferred for pure repo work

---

## When To Use

- Add/modify files that don't require live system access
- Write documentation
- Add tests (unit/integration that run in CI, not against live DB)
- Refactor within a single repo
- Any task where "clone repo, edit files, open PR" is sufficient

## When NOT To Use

- Tasks requiring live DB access (use Claude Code on Sandbox)
- Tasks requiring SSH to other nodes
- High-risk changes to auth/middleware (use Air direct-edit)
- Secret or key management (human-only)
- Anything urgent — Copilot runs asynchronously, latency is 5-30 min

## Participants

- **GitHub Issue** — task definition
- **Copilot Cloud Agent** — runs in GitHub's cloud, isolated from JARVIS
- **Ken on Air** — reviews PR, approves merge
- **Sandbox/Brain/Endpoint** — pull merged changes via standard deploy

## Flow

1. Ken creates a GitHub Issue with clear task description
2. Ken assigns issue to `Copilot` (via assignees dropdown)
3. Copilot:
   - Posts acknowledgment comment
   - Creates branch `copilot/<slug>`
   - Opens draft PR with initial plan
   - Works through plan (5-30 min)
   - Commits changes, all Verified signed
   - Requests review from Ken
4. Ken reviews diff on GitHub, marks PR "Ready for review"
5. Ken merges PR to main
6. Ken runs repo's pull script on target nodes
7. Issue auto-closes on merge

## Authorship

- Commits authored by `copilot-swe-agent[bot]`
- Verified badge (GitHub bot signing key)
- `Co-authored-by: kphaas` trailer (auto-added)
- Agent-Logs-Url trailer links to full Copilot session log

## Billing

- Uses Microsoft enterprise Copilot seat
- "Usage billed to" set to `microsoft` org
- Zero cost to Ken personally

## Safeguards Enabled

- Firewall on cloud agent network access
- Recommended allowlist (package repos only)
- Require approval for workflow runs (Actions don't auto-run on Copilot PRs)
- CodeQL code scanning on every PR
- Copilot code review (bot reviews its own work)
- Secret scanning
- Dependency vulnerability checks

## Fallback — If Copilot Is Unavailable

**Triggers:**
- Microsoft revokes Copilot seat
- GitHub outage > 1 hour
- Copilot Cloud Agent specifically disabled

**Response:**
- Switch to Claude Code on Sandbox for all previously Copilot-routed tasks
- No loss of capability — only loss of cloud-isolated execution and native PR flow
- Fallback capacity check: every 4 sessions, verify Claude Code on Sandbox can handle 100% of current Copilot work

## Provenance

- Cleanest provenance of any AI flow (signed commits, Verified badge, session logs linked)
- Every Copilot commit is auditable back to the originating Issue

## Risk Profile

- Low risk (cloud-isolated, read-only to infrastructure)
- Asynchronous — not suitable for urgent fixes
- Requires GitHub + Microsoft seat availability (Tier 3)

## Cost Tracking

- Premium requests tracked in GitHub Copilot settings
- No integration with JARVIS Forge cost tracker yet (planned for Session #07 — see Forge integration roadmap)
