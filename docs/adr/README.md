# Architecture Decision Records

ADRs capture architecturally significant decisions. One decision per file. Numbered sequentially.

## Why ADRs

- **Durability** — decisions get forgotten; files don't.
- **Auditability** — future sessions, future collaborators, future Ken can ask "why did we do this?" and get a real answer.
- **Prevents re-litigation** — settled questions don't get re-opened every session.

## When to write one

Write an ADR when a decision:
- Changes how services talk to each other
- Introduces a new external dependency
- Contradicts an existing standard or ADR
- Would be surprising to a future reader of the code

Skip an ADR for: code style, variable naming, which Python lib to use for one task.

## Process

1. Copy `TEMPLATE.md` to `ADR-NNNN-short-title.md` (next sequential number)
2. Fill it in, status = **Proposed**
3. Commit + open PR (or direct commit if solo)
4. Once decision is locked, flip status to **Accepted**
5. If later superseded by a new decision, update status + link to the superseding ADR

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [0001](./ADR-0001-adopt-docker-deployment.md) | Adopt Docker for service deployment | Accepted | 2026-04-19 |
| [0002](./ADR-0002-state-native-compute-containerized.md) | State Native, Compute Containerized | Accepted | 2026-04-20 |
| [0003](./ADR-0003-progressive-secrets-management.md) | Progressive Secrets Management Pattern | Accepted | 2026-04-20 |
| [0004](./ADR-0004-alpha5-execution-standards.md) | Alpha-5 Execution Standards | Accepted | 2026-04-21 |
| [0005](./ADR-0005-adopt-multi-writer-coordination-model.md) | Adopt multi-writer coordination model | Accepted | 2026-05-01 |
| [0006](./ADR-0006-orbstack-default-container-runtime.md) | OrbStack as default container runtime | Accepted | 2026-05-01 |
| [0007](./ADR-0007-pull-based-gitops-sync.md) | Pull-based GitOps sync across JARVIS dev machines | Accepted | 2026-05-05 |
| [0008](./ADR-0008-structlog-as-python-logging-standard.md) | structlog as the JARVIS Python services logging standard | Accepted | 2026-05-07 |
| [0009](./ADR-0009-ruff-s-static-security-standard.md) | Standardize on ruff S ruleset for Python static security analysis | Accepted | 2026-05-08 |
| [0010](./ADR-0010-cross-repo-runtime-bridge-contract.md) | Cross-Repo Runtime Bridge Contract | Proposed | 2026-05-09 |
| [0011](./ADR-0011-spec-md-format-standard.md) | Spec.md Format Standard for Forge Pipeline Adoption | Accepted | 2026-05-12 |
| [0012](./ADR-0012-project-phase-pipeline-data-model.md) | Project / Phase Pipeline Data Model | Proposed | 2026-05-13 |
| [0013](./ADR-0013-forge-autonomous-execution-and-merge-gate.md) | Forge Autonomous-Pass Execution Model & Multi-Phase Merge-Gate | Proposed | 2026-05-19 |
| [0014](./ADR-0014-operator-decision-artifacts.md) | Operator Decision Artifacts | Proposed | 2026-05-25 |
| [0015](./ADR-0015-mattermost-ops-chatops-surface.md) | Mattermost as the JARVIS Ops ChatOps Surface | Proposed | 2026-05-25 |

## Template

See `TEMPLATE.md` for the ADR skeleton.
