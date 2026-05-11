# ADR-0011: Adopt a single canonical Agent Spec template across JARVIS

- **Status:** Accepted
- **Date:** 2026-05-11
- **Deciders:** Ken
- **Supersedes:** N/A — no prior JARVIS-wide ADR on agent declaration. Earlier per-agent CLAUDE.md files served as ad-hoc agent contracts and are NOT retired by this ADR; they are reframed as supplementary onboarding docs, with the Agent Spec becoming the machine-readable contract.
- **Related:** ADR-0005 (multi-writer coordination — Agent Spec PRs follow the same branch/review flow); ADR-0010 (cross-repo runtime bridge contract — agents that cross repo boundaries layer the bridge contract on top of their spec); jarvis-standards/docs/templates/AGENT_SPEC_TEMPLATE.md (the artifact landed alongside this ADR); A2A Protocol v1 (https://a2aproject.github.io/A2A/) — Agent Card shape that the template wraps; Model Context Protocol (https://modelcontextprotocol.io/) — tool-access layer referenced by spec §6.

---

## Context

JARVIS is moving from a single runtime (`jarvis-alpha`) to a multi-agent system. Confirmed and planned agents include `financial`, `family`, `council`, `business`, `ken-voice`, `ken-delegate`, `forge`, `security`, and a long tail of narrower specialists (`dad-mode`, `medical`, `buddy`). Each agent must declare, in a form that humans can review in PR diffs and machines can validate before build:

- Identity (name, version, owning repo, principal)
- Capabilities (skills exposed, A2A endpoints, MCP tool access)
- Cost model (per-call budgets, monthly cap, model tier)
- Approval requirements (T1–T5 tier mapping per action class, hard refusals)
- Data scope (RLS role, persona vault folders read/written, table allow-list)
- Audit behavior (trace propagation, persistence target, redaction rules)
- Lifecycle (deprecation policy, replacement agent pointer)

Two external standards already cover part of this surface. **A2A Protocol v1** defines an Agent Card for agent discovery and inter-agent communication. **MCP** defines tool-access semantics. Neither covers JARVIS-specific governance — cost caps, the T1–T5 approval ladder, the child-safety surface that gates access to minors' data, or the per-agent RLS role attribution that backs `alpha_*` table policies. Adopting A2A and MCP without a JARVIS wrapper would either (a) duplicate governance metadata in every agent's source code with no canonical shape, or (b) defer governance to runtime checks that PR review can't see.

The architectural question is whether a single canonical Agent Spec template should be the contract every JARVIS agent declares against, or whether each agent repo should evolve its own shape. Three options were on the table:

1. **No template — per-agent free-form declarations.** Every agent repo writes whatever the author thinks matters. Forge planner/runner has no validation surface; Brain orchestrator has no schema to dispatch against; PR review compares apples to oranges. Drift is encoded as policy.
2. **Adopt A2A Agent Card alone, no JARVIS extensions.** Half of the governance surface (cost caps, T1–T5, RLS role, child-safety) lives outside the spec, in code or runtime config. The questions a PR reviewer needs to answer ("can this agent autonomously spend money?") can't be answered from the diff.
3. **Single canonical template wrapping the A2A Agent Card with a `governance:` block.** One shape every agent forks. Filled specs land in `<agent-repo>/docs/specs/AGENT_SPEC_<agent_id>.md`. Forge `reviewer.py` validates against the template's §15 acceptance criteria before allowing agent build.

Option 3 is the only one that lets Forge auto-scaffold agents from filled specs (the overnight-build pattern requires a validatable input) and the only one where a PR reviewer can see governance choices in the diff. The template version field plus reviewer's version-match gate means the template can evolve without invalidating in-flight specs.

## Decision

**JARVIS adopts the master Agent Spec template at `jarvis-standards/docs/templates/AGENT_SPEC_TEMPLATE.md` as the canonical declaration format for every JARVIS agent**, with the following binding rules:

1. **One canonical template, single source of truth.** Every JARVIS agent forks the template at `jarvis-standards/docs/templates/AGENT_SPEC_TEMPLATE.md` and lands its filled spec at `<repo>/docs/specs/AGENT_SPEC_<agent_id>.md`. No per-repo template variants. Template version 1.0.0 ships alongside this ADR.
2. **Template wraps A2A Agent Card with JARVIS governance.** The A2A Agent Card shape (identity, skills, endpoints) is honoured directly. JARVIS-specific extensions (`governance:` block: cost model, T1–T5 approval mapping per action class, RLS role, persona vault access map, child-safety flag, hard refusals) live in additional sections within the same file. A2A consumers see a valid Agent Card; JARVIS consumers see the full governance contract.
3. **Forge validates before build.** The Forge `reviewer.py` validator checks filled specs against the template's §15 acceptance criteria (required fields populated, costs sum to within monthly cap, T-tier assignments cover every declared action class, RLS role exists in `alpha_*` policy, child-safety flag is set explicitly true or false). A spec that fails validation does NOT enter the Forge planner queue.
4. **Template version is load-bearing.** The template carries a `version` field (semver). Each filled spec records the template version it was authored against. Reviewer rejects specs whose template version is more than one minor version behind the current template. Template-breaking changes (field removal, semantic shift) require an ADR amendment and bump of the major version.
5. **No backfill flag day.** Existing agent-ish artifacts (CLAUDE.md files in jarvis-financial, jarvis-family, jarvis-council, jarvis-data-sources, etc.) are NOT retroactively converted by this ADR. Per-agent migration TDs file when each agent's first Forge-built revision lands. Existing CLAUDE.md files remain as onboarding companions; the Agent Spec becomes the machine-readable contract.
6. **Per-agent overrides are explicit.** The Agent Spec template includes optional override blocks (delegation policy, cost cap, RLS role) that can deviate from JARVIS defaults declared in `jarvis-personality/04_delegation/delegation_policy.yml`. Overrides require a `rationale:` field; reviewer rejects empty rationale.

## Consequences

### Positive
- Every JARVIS agent has the same machine-readable shape. PR review surfaces governance choices in the diff rather than burying them in runtime config.
- Forge can auto-scaffold agents from filled specs (overnight-build pattern). The validator gives Forge a hard gate before generation.
- Brain orchestrator dispatches against a single schema. Routing logic doesn't need per-agent special-cases for cost or approval semantics.
- Agents can be deprecated and replaced uniformly. The lifecycle fields (deprecation date, replacement agent pointer) make sunsetting a mechanical operation.
- A2A and MCP compatibility comes "for free" — the template wraps both standards rather than replacing them.
- Child-safety surface (Ryleigh/Sloane data access) is declared in the spec and enforced at the spec layer, not buried in agent code.

### Negative
- Template will evolve. Existing filled specs need versioned migration when the template ships breaking changes. Reviewer's version-match gate enforces this but adds friction.
- Solo-dev cognitive load for the first two-to-three agents until the pattern is internalized. The worked example at the template bottom (ken-voice) is designed to mitigate this, but won't eliminate it.
- Forge `reviewer.py` becomes a hard dependency of agent shipping. If reviewer is broken, no new agent ships. Mitigation: reviewer is deterministic and small; failures are mechanical to diagnose.

### Neutral
- The template is descriptive, not prescriptive about agent internals. It says what the agent must declare, not how it must be implemented. Implementation language, framework, and architecture remain per-agent decisions.
- The `governance:` block does not enforce policy at runtime — Brain orchestrator and Approval Gateway enforce policy. The spec is the declared contract; the runtime is the gate. Drift between declaration and runtime is detectable but not prevented by this ADR.

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| A2A Protocol v1 | Tier 3 (external spec, no runtime dependency) | If A2A evolves incompatibly, JARVIS forks the Agent Card shape into the template. The wrapper structure means JARVIS controls the binding. |
| Model Context Protocol | Tier 3 (external spec, no runtime dependency) | Same as A2A — MCP semantics are referenced by spec §6 but not embedded; per-agent tool-access can describe non-MCP transports. |
| Forge `reviewer.py` | Tier 1 (in-repo, JARVIS-owned) | If reviewer has bugs, validation is manual against §15 checklist. Reviewer is a quality gate, not a gating dependency. |

No new external runtime dependencies are introduced by this ADR. The template references A2A and MCP at declaration time only; whether an agent actually talks A2A or MCP is the agent's own choice and lives in the filled spec.

## Alternatives considered

### Option A — No template
Rejected: the multi-agent system Brain orchestrates already exists in fragments (financial, family, council, data-sources). Letting each agent declare its own shape encodes the existing drift as the future. Forge cannot autobuild from drift.

### Option B — A2A Agent Card alone
Rejected: A2A is silent on cost caps, T1–T5 approval, RLS role, and child-safety. These are precisely the dimensions PR review needs to see and the runtime needs to enforce. Wrapping A2A gives both layers what they need.

## Reversal conditions

1. If Forge `reviewer.py` cannot validate the template reliably (false positives that block legitimate specs > 10% of cases), revisit whether the template is too prescriptive.
2. If A2A v2 ships a Governance Extension Protocol that subsumes the JARVIS `governance:` block, fold the wrapper and migrate filled specs to direct A2A v2 declarations.
3. If the count of filled Agent Specs reaches 12+ and the template has not had a single breaking change requiring full migration, the template is over-engineered; consider tightening required fields.

## References

- `jarvis-standards/docs/templates/AGENT_SPEC_TEMPLATE.md` — the master template landed alongside this ADR (template version 1.0.0).
- A2A Protocol v1 — https://a2aproject.github.io/A2A/
- Model Context Protocol — https://modelcontextprotocol.io/
- ADR-0005 — Multi-writer coordination model (branch/review flow that Agent Spec PRs follow).
- ADR-0010 — Cross-repo runtime bridge contract (layered on top of Agent Spec for cross-repo agents).
