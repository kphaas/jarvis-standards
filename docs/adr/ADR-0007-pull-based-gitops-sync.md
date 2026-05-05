# ADR-0007: Pull-based GitOps sync across JARVIS dev machines

- **Status:** Accepted
- **Date:** 2026-05-05
- **Deciders:** Ken
- **Supersedes:** N/A
- **Related:** ADR-0005 (multi-writer coordination — defines the per-machine commit model that this sync model maintains the floor for); `DEPLOYMENT.md` §15.2.3 (operational substrate)

---

## Context

JARVIS dev work happens across two always-relevant machines: Sandbox (always-on Mac mini) and Air (operator's laptop). Code lives in eight repos cloned on each. Without a sync model, the two clones drift: Sandbox-Claude-Code merges a PR via the GitHub web UI, and Air's local `main` is now a day behind. The next session on Air either picks up where it thinks it is — branching from a stale `main`, producing a PR that conflicts on rebase — or wastes the first ten minutes of the session re-pulling every repo by hand.

Two dev sessions in April 2026 (the family pilot Session #10 and the standards drift sweep) lost time specifically to this drift. Both were recoverable; both wanted prevention rather than detection.

The architectural question is **how** to keep clones near `main`, not whether. Three patterns were on the table:

1. **Webhook-push from GitHub Actions** — A repo-level workflow fires on `push to main`, hits a per-machine endpoint, the endpoint pulls. Active. Push-driven.
2. **Polling sync daemon** — A long-lived process on each machine walks every JARVIS clone every N seconds, fetches `origin`, fast-forwards `main` when clean. Passive. Pull-driven.
3. **Manual pull on session start** — Status quo. Operator runs `git pull` per repo or via `jarvis_pull.sh` at session start.

Option 3 is what we have, and we already know it leaves drift. The choice is between Options 1 and 2.

ArgoCD and Flux — the two reference GitOps tools at scale — both made this exact choice in favor of polling, for reasons that apply directly here:

- **Reliability over flaky destinations.** Air is asleep, off the network, or behind a captive portal more often than it's reachable. A push must succeed at delivery time; a poll retries every cycle until conditions allow. The cost of a push failure is a silent drop; the cost of a poll failure is the next cycle catching it.
- **Simpler architecture.** Pull mode requires no inbound endpoint, no exposed port, no cloud → laptop hairpin through Tailscale, no per-machine webhook secret management. The only network direction is laptop → GitHub, which is already required for `git pull` to function at all.
- **Failure mode visibility.** A polling daemon's log captures every cycle. Per-repo failures accumulate over time and surface in observability. Webhook drops are invisible by default.

Air's specific cycle — closed during commute, awake at the office, asleep overnight — is the exact "destination unavailable at delivery time" failure mode that polling tolerates and webhook-push doesn't.

## Decision

**JARVIS adopts pull-based GitOps sync** via a polling daemon installed as a `launchd` LaunchAgent on Sandbox and Air. The daemon (`scripts/_templates/sync_daemon.sh`) walks every clone under `$HOME` matching `jarvis-*`, fetches `origin` read-only, and fast-forwards local `main` only when the working tree is clean and `ahead == 0` against `origin/main`. Default cadence is 300 seconds.

The daemon is **purely additive**: it never rebases, never resolves conflicts, never touches a branch that isn't `main`, never modifies the working tree of a non-main checkout. Operator drift (a dirty tree, an unpushed local commit) is logged and skipped — operator decides what to do next session.

### Scope

| Machine | Daemon installed | Reason |
|---|---|---|
| Sandbox | Yes (Phase 2) | Always-on dev runner; benefits from minute-fresh local `main` for Claude Code sessions |
| Air | Yes (Phase 2) | Laptop with sporadic connectivity; benefits most from retry-on-every-cycle |
| Brain / Gateway / Endpoint | No | Service nodes; no developer cloned-repo state to maintain |
| Unraid | No | Stateful tier only |

### Out of scope for this ADR

- Sync of `~/jarvis/infra` or `~/jarvis-infra/` deploy state — handled by per-service deploy scripts, not this daemon
- Sync of `~/.secrets` between Sandbox and Air — explicitly never automated (per `DEVELOPMENT_PROCESS.md` Decision Matrix, secret rotation is Air-direct only)
- Branches other than `main` — daemon only fast-forwards `main` and refreshes the local `main` ref when on another branch via `git fetch origin main:main`. Feature branches stay where the operator left them.
- Conflict resolution — by design impossible. Daemon refuses to act when ahead != 0 or the tree is dirty.

### Operational standards

- LaunchAgent label: `com.jarvis.sync_daemon`
- Per-cycle target: <1 second when caches are warm
- Log: `~/.jarvis/sync_daemon.log` (tab-separated: `timestamp \t level \t repo \t action \t [detail]`)
- Three consecutive `fetch_failed` cycles for the same repo escalate to `WARN` level (notification gating handled by future log scrapers; not in MVP scope)
- Graceful shutdown: SIGTERM finishes the current cycle, exits 0; never exits non-zero on transient errors

## Consequences

### Positive

- Drift between Sandbox and Air's `main` checkouts collapses from "as long as the operator forgets to pull" to "≤1 cycle, default 300s"
- Failure mode is loud (per-repo `WARN` after three consecutive failures) instead of silent (webhook drop)
- No new inbound network surface on either machine
- Operator's safety floor — clean tree, ahead=0 — guarantees the daemon never destroys work
- Per-cycle log creates an audit trail of what advanced when, useful for post-mortems
- Pattern is industry-validated (ArgoCD, Flux) and trivially understood

### Negative

- A clone that has been dirty for hours stays out-of-sync — the daemon won't intervene. Mitigation: that's the same state the operator was in before the daemon existed; the daemon doesn't make it worse
- Polling consumes per-cycle network even when nothing has changed (one `git fetch` per repo per cycle). At default 300s × 8 repos × 2 machines, that's ~115 fetches per hour. Each is a few KB if there's no change. Acceptable.
- Power cost on Air during battery operation. Mitigation: daemon doesn't run when Air is asleep (LaunchAgent's default behavior); reactivates on wake. An operator who closes the laptop loses no fetches because none would have been useful anyway.
- A daemon misbehavior could in principle fast-forward an in-flight rebase or hide a remote-state change. Mitigation: read-only fetch + clean-tree + ahead=0 guard set is verifiable in the script and tested in `scripts/test/test_sync_daemon.sh`.

### Neutral

- The daemon is replaceable by a webhook-push if conditions change (see Reversal conditions). Switching is a config-and-restart, not a rewrite — webhook-push lives at the GitHub Actions side, with the daemon side simply uninstalled.
- The daemon's log shape is forward-compatible with eventual Loki ingest per `LOGGING.md` (tab-separated, ISO-8601 timestamps, structured fields) without requiring a schema change.

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| `launchd` LaunchAgent | Tier 1 (macOS-native, no phone-home) | None needed; if launchd ever fails this hard, the entire Mac is unusable |
| `git fetch` over Tailscale → GitHub | Tier 4 (GitHub remote — already an existing dependency) | Manual `git pull` retains effect; daemon failure mode degrades to status quo, not regression |
| Daemon process itself | Tier 1 (bash + git, no third-party libs) | Manual `git pull` per repo (today's status quo) |

The daemon adds no new external dependency beyond ones already present. GitHub remote access is required for any sync model; the daemon does not introduce that dependency, only schedules its use.

## Alternatives considered

### Option A — Pull-based polling daemon (SELECTED)

See Decision section above.

### Option B — Webhook-push from GitHub Actions

A `push to main` workflow on each repo posts to a per-machine endpoint over Tailscale; the endpoint runs `git pull` for the affected repo.

Rejected: requires an inbound endpoint on Sandbox + Air (a small HTTP service or a long-running listener); requires per-machine auth secret management; silently drops when the destination is offline (Air's default state for hours per day); makes failure invisible without a separate observability path. None of these problems are unsolvable, but the polling model avoids them all by inverting the direction.

### Option C — Manual pull on session start

Operator runs `jarvis_pull.sh` (or per-repo `git pull`) at the top of every session.

Rejected: this is the status quo, and it has demonstrably leaked drift in two recent sessions. Adding an explicit step that the operator must remember every time is exactly the failure mode the daemon eliminates. Status quo is preserved as the fallback for when the daemon is uninstalled, so we lose nothing by adopting daemon-as-default.

### Option D — Cron job per machine running `git pull` per repo

Crontab entry every N minutes that walks `~/jarvis-*` and runs `git pull`.

Rejected: `git pull` defaults to merge — if the local has any unpushed commits, this would create merge commits in `main`, violating §6.2 "Require linear history". `git pull --ff-only` would solve that, but a cron approach also lacks the per-cycle structured log, the consecutive-failure tracking, and the graceful-shutdown handling that the daemon provides. The functional gap is real even on top of the linear-history fix.

### Option E — Restic-style rsync of the working trees

Use `rsync` over Tailscale to keep two clones bit-for-bit identical.

Rejected: bypasses git entirely; loses all history-aware safety (would happily overwrite an in-flight rebase on the destination); doesn't sync remote state. Considered only for completeness.

## Reversal conditions

Revisit this ADR if any of the following occur:

1. **Network cost becomes meaningful.** If JARVIS adds 30+ repos and the per-cycle fetch storm noticeably affects laptop battery or the Tailscale link, drop the cadence (300s → 1800s) before reverting the model. If even relaxed cadence is too costly, evaluate webhook-push then.
2. **A daemon bug destroys work.** A real incident where the daemon advances `main` past an in-flight operation triggers an immediate rollback to manual pull; the daemon code stays in the repo for a post-mortem fix and re-adoption.
3. **GitHub adds first-class push-to-clone primitives.** If GitHub ships a "git push notification → local pull" capability that handles the offline-destination case (e.g. queued delivery with retry), re-evaluate. Today no such primitive exists at the laptop tier we operate.
4. **Annual review.** Re-read this ADR at the next yearly standards review (target Q2 2027). The GitOps ecosystem moves; explicit review prevents silent rot.

## References

- ADR-0005 (this repo) — multi-writer coordination model that this sync floor maintains
- `DEPLOYMENT.md` §15.2.3 (this repo) — operational substrate where this daemon lives
- `scripts/_templates/sync_daemon.sh` — the daemon script
- `scripts/_templates/launchagents/com.jarvis.sync_daemon.plist.template` — LaunchAgent template
- `scripts/install_sync_daemon.sh` — Phase 2 installer
- ArgoCD architecture overview: <https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/>
- Flux GitOps Toolkit pull architecture: <https://fluxcd.io/flux/concepts/>
- launchd LaunchAgent reference (`man launchd.plist`)
