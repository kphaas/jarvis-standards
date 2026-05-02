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
| [0006](./ADR-0006-orbstack-default-container-runtime.md) | OrbStack as default container runtime | Accepted | 2026-05-02 |

## Template

See `TEMPLATE.md` for the ADR skeleton.
