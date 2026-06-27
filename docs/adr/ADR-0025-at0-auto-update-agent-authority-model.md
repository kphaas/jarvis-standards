# ADR-0025: Establish JARVIS Maintainer Authority Model

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** Ken Haas, Codex
- **Supersedes:** N/A
- **Related:** ADR-0013 Forge Autonomous-Pass Execution Model and Multi-Phase Merge-Gate, ADR-0014 Operator Decision Artifacts, ADR-0021 Smithy Per-Repo Test Environment Model

---

## Context

JARVIS needs a fleet update agent that can inventory available updates, classify
their blast radius, and propose safe update work without silently changing the
runtime. The fleet spans Brain, Gateway, Endpoint, Sandbox, and Air. State lives
on Brain; JARVIS Maintainer should run from Sandbox; Air is a development
machine and not a service node.

The risky part is not detection. The risky part is authority. A tool that can
update packages across the fleet can also break Python runtimes, Node builds,
nginx, Temporal, Ollama, or Postgres. It therefore needs a locked authority
model before any implementation starts.

The source draft defines Model A as detector/proposer only and Model B as a
future low-tier auto-apply mode for compute-layer patch updates. The draft also
marks several implementation decisions as open before Phase 0 code can begin.

## Decision

JARVIS will build JARVIS Maintainer as a standalone Sandbox-resident service
named `jarvis-maintainer`, but its initial authority is locked to Model A:
inventory, classify, and propose only. Maintainer must not silently apply
updates, must not touch the state layer without Ken approval, and must route
every proposed change through reviewable PR or forge proposal artifacts.

Model B is allowed only as a future configuration flip, not a rewrite:
`MAINTAINER_AUTO_APPLY_TIER=none|patch`. The default and initial value is `none`.
`patch` may only auto-apply T-patch candidates on the compute layer after all
graduation criteria are met. State-layer candidates remain manual-gated forever.

The following Phase 0 implementation decisions are locked by this ADR:

| Decision | Standard |
|---|---|
| Service home | Standalone `jarvis-maintainer` repository, Sandbox-resident, client of Brain. |
| Store of record | SQLite on Sandbox for SBOM snapshots, update candidates, and rollout events. |
| Branch prefix | `codex/maintainer/...`, preserving the global `codex/<topic>` branch namespace. |
| Classification | Rule-based in v1; LLM use is optional later for changelog summaries only. |
| Scheduler | Sandbox LaunchAgent for the detector/reconcile loop; optional Temporal visibility can be added later without making Temporal a hard scheduling dependency. |

## Non-Negotiable Guarantees

1. No silent change. Every update is visible, reviewable, and revertible.
2. No update without a green test gate.
3. No fleet-wide apply in one shot. Rollout order is Sandbox canary, one
   production node, then fleet.
4. No apply without a restore point. Health-check failure triggers rollback for
   compute-layer apply.
5. State-layer updates are always Ken-approved. Postgres, pgvector, Ollama
   model state, and Temporal server updates are never auto-applied.
6. Maintainer never updates its own runtime unattended.
7. Maintainer uses least privilege: read-mostly fleet access, PR/proposal write
   authority, and staged-apply authority only after Model B graduation.
8. Maintainer cannot propose an update for an unpinned component. Inventory and
   SBOM-of-record are prerequisites.

## Authority Model

### Model A - Detector / Proposer

Model A is the only approved launch authority. Maintainer can:

- Inventory packages, runtime versions, lockfiles, workflows, and model lists.
- Classify update candidates by tier and blast radius.
- Open a PR or forge proposal with labels such as `maintainer` and `update`.
- Publish cost, drift, and pending-candidate reports.

Model A cannot apply changes to fleet nodes.

### Model B - Patch Auto-Apply

Model B is a graduation target. It may be enabled only when:

| Criterion | Required signal |
|---|---|
| G1 | At least 20 T-patch cycles proposed, merged, and deployed cleanly. |
| G2 | Zero CI false-greens across those 20 cycles. |
| G3 | At least one verified automatic rollback drill. |
| G4 | Zero inventory reconcile drift for 30 consecutive days. |

Even in Model B, auto-apply is limited to T-patch compute-layer candidates.
T-minor, T-major, and T-state candidates remain proposal or human approval work.

## Tiering

| Tier | Covers | Gate | Approval |
|---|---|---|---|
| T-patch | Security and patch bumps on compute-layer packages. | CI green, snapshot, canary, health check. | PR in Model A; auto only in graduated Model B. |
| T-minor | Minor version bumps. | CI plus 72-hour canary. | Council or B-trait governance. |
| T-major | Major, runtime, and infrastructure binary changes. | Human review. | Ken only. |
| T-state | Postgres, pgvector, Ollama model state, Temporal server. | Backup and human review. | Ken only. |

The classifier may promote a candidate to a higher tier but must never demote a
candidate below the layer default. Unknown semver changes are treated as T-major.

## Inventory and Storage

Maintainer's source of truth is a SQLite database on Sandbox. It records:

- `inventory_snapshot`: node, layer, package, installed version, pinned version,
  source, capture time.
- `update_candidate`: candidate ID, node, layer, package, version delta, tier,
  lifecycle state, PR URL, forge phase ID.
- `rollout_event`: candidate ID, node, rollout step, outcome, snapshot
  reference, event time.

Read-only detectors may use commands such as `brew outdated --json=v2`,
`pip list --outdated --format=json`, `npm outdated --json`, `ollama list`,
`tailscale version`, `temporal --version`, `postgres --version`, and workflow
file parsing. Commands that reveal secrets or mutate state are out of scope for
Model A.

## Rollout State Machine

The standard rollout lifecycle is:

```text
DETECTED -> CLASSIFIED -> PROPOSED -> CI_PENDING -> CI_GREEN
                                                |
                                                v
                              AWAITING_HUMAN for T-major/T-state
                                                |
                                                v
CANARY -> CANARY_VERIFIED -> PROMOTING -> VERIFIED -> DONE
   |              |              |
   v              v              v
ROLLBACK -> ROLLED_BACK
```

Resume safety follows the forge side-effect rule:

| State group | Crash behavior |
|---|---|
| DETECTED, CLASSIFIED, PROPOSED, CI_PENDING | Safe to auto-resume. |
| CANARY, PROMOTING, ROLLBACK | Never auto-resume; orphan scan flags for human review. |

## Self-Update Rule

Maintainer self-updates are always T-major. Maintainer must not update its own
active venv, runtime, LaunchAgent, or repository unattended. Self-updates require
Ken approval and must run from a node where Maintainer is not actively executing,
or during a maintenance window with Maintainer stopped.

## Consequences

### Positive

- The fleet gets real inventory and drift detection before any apply authority.
- Future auto-apply work is designed in from day one without granting authority
  prematurely.
- State-layer updates remain separated from compute-layer patch automation.
- SQLite on Sandbox lets Maintainer continue recording inventory when Brain is
  degraded.
- The branch prefix remains compatible with the global JARVIS coding-agent
  contract.

### Negative

- Model A does not reduce manual apply toil at launch.
- LaunchAgent scheduling provides less workflow visualization than Temporal.
- A separate repository creates another deployable service to monitor and patch.
- Graduation to Model B requires sustained evidence, not a one-time smoke.

### Neutral

- Maintainer can push summaries to Brain or Helm later, but the SBOM store of record
  remains on Sandbox unless a later ADR changes it.
- Temporal can still be used for dashboarding or shadow workflows; it is not
  required for the detector loop.

## Sovereignty First compliance

Maintainer introduces a new internal service and no mandatory external service.
GitHub is already the governed PR and CI surface for JARVIS code changes.

| Component | Tier | Fallback |
|---|---|---|
| `jarvis-maintainer` service | Internal service | Manual inventory and existing forge proposals. |
| SQLite on Sandbox | Local state store | Export snapshots to forge artifact files; manual reconcile. |
| GitHub PR/proposal emission | Existing external dependency | Forge inbox markdown proposal without auto-merge. |
| Sandbox LaunchAgent | Native macOS scheduler | Manual runbook invocation from Sandbox. |

## Alternatives considered

### Option A - Put Maintainer inside `jarvis-forge`

Rejected. Forge owns governance and phase execution. Maintainer owns fleet inventory,
classification, and staged rollout evidence. Combining them would blur authority
and make least privilege harder.

### Option B - Store SBOM state in Brain Postgres

Rejected for v1. Brain is a state node and can be the thing being updated. The
SBOM store of record should survive Brain maintenance and avoid granting Maintainer
state-layer write authority.

### Option C - Use `maintainer/*` branches

Rejected. The global coding-agent contract requires the `codex/<topic>` branch
namespace. `codex/maintainer/...` preserves Maintainer recognizability without creating a
parallel branch convention.

### Option D - Use Temporal as the required scheduler

Rejected for v1. Temporal is itself an update surface and state-layer candidate.
Making Maintainer depend on it for scheduling creates a circular failure mode during
Temporal maintenance. Temporal visibility can be added later as an observer.

### Option E - Allow T-state auto-rollback scripts

Rejected. State restores can be destructive and must follow the existing
preservation runbook with Ken in the loop.

## Reversal conditions

1. Model A fails to produce accurate inventory after two consecutive reconcile
   cycles, or drift remains non-zero for more than seven days.
2. The Sandbox SQLite store proves operationally unreliable compared with Brain
   storage and a later ADR defines RLS, backups, and failure behavior.
3. The 20-cycle graduation evidence shows CI false-greens, failed rollback, or
   hidden state coupling.
4. JARVIS changes its global branch namespace away from `codex/<topic>`.
5. Temporal gains a proven no-circularity watchdog path for its own maintenance
   and a later ADR promotes it to scheduler of record.

## References

- Attached AT-0 Auto-Update Agent Spec v1 draft, 2026-06.
- `docs/adr/ADR-0013-forge-autonomous-execution-and-merge-gate.md`
- `docs/adr/ADR-0014-operator-decision-artifacts.md`
- `docs/adr/ADR-0021-smithy-per-repo-test-environment-model.md`
