# Mattermost Integration Spec: Forge + Alpha Ops Channel

**Status:** Proposed  
**Owner:** Ken Haas  
**Date:** 2026-05-25  
**Target:** `jarvis-standards`  
**Related:** ADR-0015, ADR-0001, ADR-0002, ADR-0003, ADR-0004, Alpha-5 migration plan

---

## 1. Executive Summary

JARVIS will use a self-hosted Mattermost server on Unraid as the primary
operations and agent communication surface. Pushover remains as the fallback
wake-up channel when Mattermost, Unraid, or the Tailscale path is unavailable.

Phase 1 is outbound-only and read-only: Forge, Alpha, and the independent
watchdog post structured notifications into Mattermost. Inbound slash commands
and write commands are deferred to later phases.

## 2. Locked Phase 1 Decisions

| Topic | Decision |
|---|---|
| Hosting | Mattermost on Unraid Docker, reachable through Tailscale only. |
| Database | Bundled Mattermost Postgres for Phase 1. |
| Integration depth | Incoming webhooks only; no inbound commands. |
| Channels | `#forge-events`, `#alpha-events`, `#needs-input`, `#alerts`. |
| Fallback | Pushover remains configured for critical degradation. |
| Bot REST API | Deferred to Phase 2+ for threads, slash commands, and richer API automation. |

## 3. Four-Lens Review

| Lens | Rationale |
|---|---|
| CIO | Creates a single operator cockpit without putting command-and-control in third-party SaaS. |
| Enterprise Architect | Keeps stateful collaboration on Unraid and preserves Brain as orchestrator, not chat host. |
| AI Solo Developer | Webhook-first Phase 1 is small, testable, reversible, and avoids premature command-surface security work. |
| Code Production | Secrets stay in node-local secret files; no hardcoded URLs or tokens; Pushover fallback preserves signal during outage. |

## 4. Channel Model

| Channel | Source | Purpose | Push policy |
|---|---|---|---|
| `#forge-events` | Forge | Pipeline events, PR events, cost updates | Badge/mute |
| `#alpha-events` | Alpha | Dream Mode, Buddy, TaskGraph, approvals, runtime activity | Badge/mute |
| `#needs-input` | Cross-system | Ken action required | Push |
| `#alerts` | Cross-system | Critical failures and safety/security alerts | Push with sound |

Routing:

| Severity | Channel |
|---|---|
| `debug`, `info`, `warning` | Source event channel |
| `needs_input` | `#needs-input` |
| `error`, `critical` | `#alerts` |
| Watchdog events | Always `#alerts` |

## 5. Source Identities and Secrets

| Source | Bot identity | Secret key |
|---|---|---|
| Sandbox / Forge | `forge-bot` | `MATTERMOST_WEBHOOK_URL_FORGE_EVENTS` |
| Brain / Alpha | `alpha-bot` | `MATTERMOST_WEBHOOK_URL_ALPHA_EVENTS` |
| Endpoint watchdog | `watchdog-bot` | `MATTERMOST_WEBHOOK_URL_WATCHDOG` |

Webhook URLs are bearer secrets. They must live only in node secret files and
must never be committed, printed, or logged.

## 6. Install Runbook

1. Verify Unraid is on the Tailscale mesh.
2. Install Mattermost Team Edition through Unraid Community Apps.
3. Bind Mattermost to Tailscale-only access; do not expose to LAN/WAN.
4. Create team `jarvis-ops`.
5. Disable public signups.
6. Enable incoming webhooks.
7. Create four channels: `forge-events`, `alpha-events`, `needs-input`, `alerts`.
8. Create webhook identities for Forge, Alpha, and Watchdog.
9. Store webhook URLs on the corresponding nodes.
10. Install Mattermost iOS app, connect over Tailscale, and set per-channel notification policy.
11. Run one smoke post per source and verify routing.

## 7. Phase 1 Acceptance Criteria

1. Mattermost is reachable via Tailscale from Ken's Mac and iPhone.
2. The four initial channels exist.
3. Incoming webhook posting works from Forge, Alpha, and Watchdog paths.
4. `#forge-events` and `#alpha-events` do not wake Ken for routine posts.
5. `#needs-input` and `#alerts` do wake Ken.
6. Pushover fallback still works.
7. A Mattermost outage does not block pipelines or agents.
8. Notification failures are logged without leaking webhook URLs.

## 8. Future Phases

| Phase | Scope |
|---|---|
| Phase 2 | Read-only slash commands: `/alpha health`, `/alpha approvals`, `/forge status`, `/forge cost`. |
| Phase 3 | Audited write commands: approvals, kill/pause/resume, cost cap changes. |
| Phase 4 | Project-specific channels for medical, financial, family when volume warrants. |
| Phase 5 | Council verdict and disagreement channels after Council reaches production. |

## 9. Rollback

Soft rollback: remove or disable `MATTERMOST_WEBHOOK_URL_*` secrets. Senders
log and fall back to Pushover where configured.

Hard rollback: stop the Unraid Mattermost container, archive/export data, remove
webhook secrets, and rely on Pushover until a replacement surface is chosen.
