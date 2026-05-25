# ADR-0014: Mattermost as the JARVIS Ops ChatOps Surface

**Repo:** `jarvis-standards`
**Status:** Proposed
**Date:** 2026-05-25
**Author:** Ken Haas (drafted with Codex)
**Supersedes:** None
**Related:** ADR-0001, ADR-0002, ADR-0003, ADR-0004, Alpha-5 migration plan, `docs/designs/MATTERMOST_INTEGRATION_SPEC.md`

---

## Context

JARVIS needs an operator surface that can carry routine events, failures,
approval prompts, and future read-only commands across `jarvis-alpha`,
`jarvis-forge`, and later family, medical, financial, and council systems.
Pushover is useful for one-way wake-up notifications, but it is not a durable
ops cockpit: it has no shared channels, no threading model, no slash-command
path, and no self-hosted command surface.

Mattermost is self-hostable on existing Unraid infrastructure, supports
incoming webhooks, bot accounts, mobile clients, channel-level notification
policy, and future slash-command / REST API automation. It fits the Alpha-5
stateful-services-on-Unraid direction without putting the ops control plane on
Brain, Endpoint, or a third-party SaaS.

## Decision

JARVIS will use self-hosted Mattermost on Unraid, reachable only over the
Tailscale mesh, as the primary operations and agent ChatOps surface. Phase 1 is
read-only outbound notifications through Mattermost incoming webhooks. Pushover
remains the fallback wake-up channel when Mattermost or Unraid is unavailable.
Bot-token REST API access and slash commands are deferred to later phases after
separate security review.

Initial channels:

| Channel | Purpose | Notification policy |
|---|---|---|
| `#forge-events` | Routine forge pipeline events | Badge/mute by default |
| `#alpha-events` | Routine Alpha runtime and agent events | Badge/mute by default |
| `#needs-input` | Cross-system Ken action required | Push |
| `#alerts` | Critical failures and safety/security events | Push with sound |

Initial sources:

| Source | Identity | Default webhook |
|---|---|---|
| Sandbox / forge | `forge-bot` | `MATTERMOST_WEBHOOK_URL_FORGE_EVENTS` |
| Brain / alpha | `alpha-bot` | `MATTERMOST_WEBHOOK_URL_ALPHA_EVENTS` |
| Endpoint watchdog | `watchdog-bot` | `MATTERMOST_WEBHOOK_URL_WATCHDOG` |

## Consequences

### Positive

- Gives Ken a single self-hosted phone-first ops surface for Alpha and Forge.
- Keeps command-and-control off public SaaS and inside the Tailscale mesh.
- Separates routine event volume from action-required and critical alerts.
- Preserves Pushover as a degraded-mode fallback instead of relying on it as the primary interface.
- Creates a clear future path for read-only slash commands and later audited write commands.

### Negative

- Adds another stateful service on Unraid that needs backup, restore, and health monitoring.
- Mattermost mobile push may require Mattermost's push notification proxy unless a self-hosted PNS path is later adopted.
- Incoming webhook URLs are bearer secrets; leaks allow posting into Mattermost until rotated.

### Neutral

- Bundled Mattermost Postgres is accepted for Phase 1 to keep deployment simple.
- Bot REST tokens are not required for Phase 1 outbound notifications, but may be created later for Phase 2+ automation.

## Sovereignty First Compliance

| Component | Tier | Fallback |
|---|---|---|
| Mattermost Team Edition on Unraid | Tier 1 self-hosted | Pushover fallback, local logs, Buddy events |
| Mattermost incoming webhooks | Tier 1 self-hosted integration | Pushover fallback |
| Mattermost mobile push proxy | Tier 3 optional relay | Tailscale-connected app polling / Pushover fallback |
| Pushover | Tier 4 third-party fallback | Local logs and Mattermost when restored |

## Alternatives Considered

### Pushover Only

Rejected as the primary surface. It is good for one-way wake-up alerts, but it
does not provide channels, threading, slash commands, or a command cockpit.

### Slack or Discord

Rejected because the operational command surface would live in third-party SaaS.
That is not acceptable for JARVIS infrastructure, medical, family, or future
agent-management workflows.

### Matrix

Rejected for this phase because federation and bridge complexity are not needed
for the initial private ops cockpit.

### Mattermost Bot REST API for Phase 1

Deferred. Bot REST is valuable for threaded follow-ups and future slash-command
work, but incoming webhooks are the safer, smaller, read-only outbound surface
for the first production slice.

## Reversal Conditions

1. Mattermost mobile notifications miss critical alerts more than once after configuration stabilizes.
2. Unraid availability becomes worse than Brain/Gateway/Endpoint availability.
3. Mattermost maintenance burden exceeds the value of the ops cockpit for two consecutive months.
4. A security review finds webhook or command-surface risks that cannot be mitigated inside Tailscale.

## References

- `docs/designs/MATTERMOST_INTEGRATION_SPEC.md`
- `jarvis-alpha/docs/JARVIS_Alpha_Skills_Agents_Catalog_v0_9.md`
- Mattermost incoming webhook docs: https://docs.mattermost.com/integrations-guide/incoming-webhooks.html
- Mattermost integrations configuration docs: https://docs.mattermost.com/administration-guide/configure/integrations-configuration-settings.html
