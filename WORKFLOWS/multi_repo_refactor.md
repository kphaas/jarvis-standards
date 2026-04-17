# Workflow: Multi-Repo Refactor

**Tier 1 — JARVIS-native** · Coordinated change across repos

---

## When To Use

- A single logical change must land in ≥2 of: jarvis-alpha, jarvis-forge, jarvis-family, jarvis-standards
- Examples: updating a shared pattern in `get_secret()`, rolling out a logging standard change, migrating API contract versions

## When NOT To Use

- Changes that happen to touch multiple repos coincidentally — handle each separately
- When the "coordination" is just "update docs in all repos" — use Copilot for each

## Participants

- **Ken on Air** — coordinator, writes sequence plan
- One or more agents depending on risk (Copilot for pure code, Claude Code for infra-aware, human-only for security surface)
- **jarvis-standards repo** — final landing zone for the shared pattern

## Flow

1. Ken writes a coordination plan in a scratch file:
   - Which repos change, in what order
   - What's the "atomic moment" (when does old behavior stop being valid)
   - Rollback plan per repo
2. Land pattern in `jarvis-standards` first (if applicable)
3. Land changes in downstream repos in dependency order:
   - jarvis-alpha first (most critical)
   - jarvis-family second
   - jarvis-forge last (least critical)
4. After all repos updated: run smoke tests across all affected services
5. Commit a final "coordination record" to jarvis-standards noting the change

## Authorship

- Mixed — each repo commit follows its own flow
- Coordination record is Ken-authored in jarvis-standards

## Fallback

- If one repo fails mid-refactor: STOP. Do not proceed to next repo. Debug + fix or roll back completed repos.
- Rollback order: reverse of deploy order (forge → family → alpha → standards)

## Risk Profile

- Highest coordination risk of any flow
- Failure mode: partial rollout leaves the system in an inconsistent state (e.g., alpha expects new contract, forge still sends old)
- Mitigation: atomic moment design — ensure backwards-compat during rollout, remove old path in a follow-up refactor

## Known Anti-Patterns

- Trying to atomically change all repos simultaneously — impossible without distributed transactions
- Forgetting to update jarvis-standards — pattern rots, next person can't find it
- Skipping smoke tests after multi-repo changes — exactly when they matter most
