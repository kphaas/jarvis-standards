# JARVIS Agent Spec — Master Template

**Template version:** 1.0.0
**Last updated:** 2026-05-11
**Owner:** Ken / jarvis-standards
**Status:** canonical
**Supersedes:** none

---

## How to use this template

1. Copy this file to `docs/specs/AGENT_SPEC_<agent_id>.md` in the appropriate repo (typically the agent's own repo, or `jarvis-standards/docs/specs/` for cross-repo agents).
2. Fill in every `<FILL_IN: ...>` placeholder. Hints inside each placeholder explain what to write.
3. Delete the "How to use this template" and "Worked example" sections from the filled copy.
4. Run validation: `forge validate-spec docs/specs/AGENT_SPEC_<agent_id>.md` — Forge `reviewer.py` checks completeness against §15 acceptance criteria.
5. Once validated, this spec is the input to jarvis-forge planner/runner pipeline for autonomous build.

**Vague specs produce vague code.** The more precise this file, the better Forge's overnight build. Treat unclear sections as a signal to do more design work, not less.

**Two-file rule:** if an agent has both a Voice layer and a Delegate layer (e.g. ken-voice + ken-delegate), produce **two separate spec files**. They share persona but have different tool grants, approval thresholds, and audit trails.

---

## Template begins below

---

# Agent Spec — `<FILL_IN: agent_name e.g. Ken-Voice>`

```yaml
---
agent_id: <FILL_IN: slug, lowercase-hyphenated, e.g. ken-voice>
agent_name: <FILL_IN: human-readable name>
agent_class: voice | delegate | specialist | tool-wrapper | orchestrator
version: 0.1.0
status: draft | in_review | active | deprecated
owner: ken
created: <FILL_IN: YYYY-MM-DD>
last_updated: <FILL_IN: YYYY-MM-DD>
supersedes: <FILL_IN: previous spec path, or "none">
related_specs: [<FILL_IN: other agents this one pairs with>]
repo: <FILL_IN: github.com/kphaas/jarvis-X>
---
```

---

## 1. A2A Agent Card (machine-readable)

This block becomes the agent's `/.well-known/agent-card.json` served by the agent's HTTP server. A2A v1 spec.

```yaml
agent_card:
  name: <FILL_IN: same as agent_name>
  description: <FILL_IN: one-line mission, what this agent does>
  url: <FILL_IN: https://<host>.tail40ed36.ts.net:<port>>
  version: 0.1.0
  capabilities:
    streaming: true | false        # SSE streaming supported
    pushNotifications: true | false  # NATS notify supported
    extensions: []
  skills:
    - id: <FILL_IN: skill_slug>
      name: <FILL_IN: Human Readable Skill Name>
      description: <FILL_IN: what this skill does in one sentence>
      examples:
        - <FILL_IN: example invocation>
        - <FILL_IN: another example>
      input_schema: <FILL_IN: JSON schema or pointer to schema file>
      output_schema: <FILL_IN: same>
    # Repeat per skill
  authentication:
    schemes: [bearer_jwt_rs256]
    required_audience: <FILL_IN: agent_id>
    issuer_pubkey: brain.jarvis_alpha
```

---

## 2. JARVIS Governance Extensions (machine-readable)

Custom JARVIS metadata layered on top of A2A. Used by Brain orchestrator, Approval Gateway, cost tracking, and audit.

```yaml
governance:
  cost:
    cap_daily_usd: <FILL_IN: number, e.g. 5.00>
    cap_monthly_usd: <FILL_IN: number, e.g. 100.00>
    preferred_models:
      - ollama:llama3.1:8b           # local-first
      - claude-haiku-4-5-20251001    # fallback for tasks requiring cloud
    cloud_cost_alert_threshold_usd: <FILL_IN: number>

  approval:
    tier_default: T1 | T2 | T3 | T4 | T5
    tier_overrides:
      <action_class>: T<n>
      # Example: spending_financial_commitment: T5
      # Example: low_risk_external_comms: T2
    risk_dimensions_enabled:
      - impact
      - reversibility
      - novelty
      - social_sensitivity
    confidence_floor: <FILL_IN: 0.0-1.0, escalate if below>
    confidence_role: secondary  # confidence is one input, not the sole trigger

  data_scope:
    reads:
      - table: <FILL_IN: e.g. personality_values>
        rls_role: <FILL_IN: platform_admin | user | child>
      - table: <FILL_IN: e.g. alpha_conversation_memory>
        rls_role: <FILL_IN>
        tag_filter: <FILL_IN: e.g. source=personality AND tags LIKE 'core/%'>
    writes:
      - table: <FILL_IN: e.g. alpha_buddy_events>
        rls_role: <FILL_IN>
    forbidden:
      - <FILL_IN: explicit tables/resources this agent must NEVER touch>

  identity:
    service_identity_key_path: ~/jarvis/pki/services/<agent_id>_private.pem
    service_identity_pubkey_in_repo: brain/pki/services/<agent_id>_public.pem
    audit_log_subject: jarvis.audit.<agent_id>
    audit_retention_days: 90

  child_safety_surface:
    applicable: true | false
    affected_profiles: [ryleigh, sloane, none]
    second_factor_required_for: [<FILL_IN: list of actions>]
    content_filtering: <FILL_IN: scope description, e.g. "age-appropriate only">

  delegation_policy:
    unified_policy_file: ~/jarvis-personality/04_delegation/delegation_policy.yml
    agent_specific_overrides:
      - <FILL_IN: list any deviations from the unified policy>

  correction_loop:
    veto_endpoint: <FILL_IN: e.g. POST /v1/<agent_id>/veto/{decision_id}>
    annotation_table: alpha_decision_annotations
    consolidation_cadence: weekly | daily | monthly
    consolidation_threshold_count: 3      # N annotations on same dimension before persona update
    consolidation_target: persona_table | policy_file
```

---

## 3. Mission

`<FILL_IN: one to two sentences declaring what this agent does and what it explicitly does NOT do. Example: "Ken-Voice drafts, summarizes, and replies in Ken's tone across email, messaging, and document drafting. It does NOT send, commit, or spend.">`

---

## 4. Capabilities (detailed)

Expanded from §1 skills. Per capability:

### Capability: `<FILL_IN: skill_id>`

- **Purpose:** `<FILL_IN: what problem this solves>`
- **Inputs:** `<FILL_IN: structure>`
- **Outputs:** `<FILL_IN: structure>`
- **Cost model:** `<FILL_IN: e.g. ~500 tokens local, ~200 tokens cloud fallback>`
- **Latency target:** `<FILL_IN: p50, p99>`
- **Risk class** (from §7 taxonomy): `<FILL_IN: e.g. drafting_only>`
- **Examples:**
  - `<FILL_IN: realistic invocation 1>`
  - `<FILL_IN: realistic invocation 2>`

`<Repeat per capability>`

---

## 5. Persona and Voice Alignment

How this agent grounds itself in Ken's persona. (Skip section 5b for non-Voice agents.)

### 5a. Persona reads

```yaml
persona_tables_consumed:
  - personality_identity
  - personality_values
  - personality_voice         # voice agents only
  - personality_decision_heuristics  # delegate agents only
  - personality_anti_goals
persona_query_strategy: <FILL_IN: e.g. "load full identity + values at agent start; retrieve voice/decision rows on demand via pgvector semantic search">
persona_cache_ttl_minutes: <FILL_IN: e.g. 60>
persona_refresh_trigger: <FILL_IN: e.g. "fswatch on ~/jarvis-personality/ → POST /v1/persona/reload">
```

### 5b. Voice constraints (Voice-class agents only)

```yaml
tone_constraints:
  formality_register: <FILL_IN: casual | mixed | formal>
  vocabulary_constraints:
    avoid: [<FILL_IN: words/phrases Ken would never use>]
    favor: [<FILL_IN: signature phrases>]
  length_default: <FILL_IN: e.g. "≤ 3 sentences for chat, ≤ 1 paragraph for email">
refusal_behavior:
  refuse_when:
    - <FILL_IN: e.g. "asked to impersonate Ken in a financial discussion">
    - <FILL_IN: e.g. "contact key file forbids the topic">
  refusal_template: <FILL_IN: standard refusal copy>
```

---

## 6. Memory Tier Configuration

How THIS agent uses the 3-tier memory pattern.

```yaml
working_memory:
  storage: alpha_conversation_memory with memory_type='working'
  ttl_hours: 24
  evicted_by: com.jarvis.alpha.buddy
  contents:
    - <FILL_IN: what kinds of facts go here>

episodic_memory:
  storage: alpha_conversation_memory with memory_type='episodic'
  retention_days: 30
  contents:
    - <FILL_IN>
  promotion_score_function: <FILL_IN: e.g. recency*0.3 + access_count*0.4 + manual_flag*0.3>

semantic_memory:
  storage: alpha_conversation_memory with memory_type='semantic'
  retention: permanent
  contents:
    - <FILL_IN: what gets promoted from episodic to semantic>
  promotion_gate: <FILL_IN: e.g. "Buddy agent + Ken manual review">
```

---

## 7. Action Class Taxonomy Mapping

Map every action this agent can perform to the JARVIS risk-class taxonomy.

| Action class | Examples in this agent | Default approval tier | Risk dimensions that apply |
|---|---|---|---|
| `read_only_retrieval` | <FILL_IN> | T1 | impact: low / reversibility: full |
| `drafting_only` | <FILL_IN> | T1 | impact: low / reversibility: full |
| `low_risk_external_comms` | <FILL_IN> | T2 | impact: medium / social_sensitivity: medium |
| `scheduling_calendar_mutation` | <FILL_IN> | T3 | impact: medium / reversibility: partial |
| `time_commitment` | <FILL_IN> | T3 | impact: medium / novelty: high → T4 |
| `spending_financial_commitment` | <FILL_IN> | T5 | always T5, no overrides |
| `identity_legal_medical_child_reputation` | <FILL_IN> | T5 | always T5, never autonomous |

Risk dimension modifiers (any one tripping → escalate one tier):
- **Impact magnitude:** quantitative or qualitative scale
- **Reversibility:** full | partial | irreversible (irreversible → +1 tier)
- **Novelty:** has-precedent | similar-precedent | novel (novel → +1 tier)
- **Social sensitivity:** contact key file flag → +1 tier

---

## 8. Delegation Policy Reference

```yaml
unified_policy_file: ~/jarvis-personality/04_delegation/delegation_policy.yml

# Inheritance: this agent inherits all rules from unified policy
inherits_from_unified: true

# Agent-specific overrides (only if the agent has a defensible reason to deviate)
overrides:
  - rule: <FILL_IN: e.g. "auto_approved.draft_under_3_sentences">
    deviation: <FILL_IN: what changes>
    rationale: <FILL_IN: why>

# Hard-coded refusals that bypass policy file entirely (defense in depth)
hard_refusals:
  - <FILL_IN: e.g. "Never sign legal documents, even with approval">
  - <FILL_IN: e.g. "Never modify Ryleigh/Sloane records without second-factor">
```

---

## 9. Interfaces

### 9a. HTTP endpoints exposed

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/.well-known/agent-card.json` | none (public) | A2A discovery |
| POST | `/v1/<agent_id>/invoke` | RS256 JWT | A2A skill invocation |
| GET | `/v1/<agent_id>/health` | none | Liveness probe |
| `<FILL_IN>` | `<FILL_IN>` | `<FILL_IN>` | `<FILL_IN>` |

Each endpoint should have body/response schemas referenced or inlined.

### 9b. NATS topics

```yaml
published:
  - subject: jarvis.<agent_id>.event.<event_type>
    payload_schema: <FILL_IN>
    purpose: <FILL_IN>

subscribed:
  - subject: jarvis.persona.reload
    handler: refresh_persona_cache
  - subject: <FILL_IN>
    handler: <FILL_IN>
```

### 9c. MCP servers consumed (tools)

```yaml
mcp_servers:
  - name: <FILL_IN: e.g. mcp-calendar-google>
    purpose: <FILL_IN>
    auth: <FILL_IN: OAuth scope or service account>
    required: true | false  # if false, agent degrades gracefully without it
```

### 9d. A2A agents consumed (peer agents)

```yaml
a2a_peers:
  - agent_id: <FILL_IN: e.g. ken-voice>
    relationship: peer | provider | dependent
    skills_used: [<FILL_IN: list of skills invoked>]
```

---

## 10. Dependencies

```yaml
agents:
  - <FILL_IN: agent_id> (relationship: <peer|provider|dependent>)

tools_via_mcp:
  - <FILL_IN>

databases:
  - jarvis_alpha (tables: <FILL_IN: list>)

secrets_required:
  - <FILL_IN: secret name in ~/jarvis/secrets.d/, not the value>

repos_required_at_runtime:
  - <FILL_IN: e.g. jarvis-personality vault must be readable>
```

---

## 11. Identity and Audit

```yaml
service_identity:
  keypair_location:
    private: ~/jarvis/pki/services/<agent_id>_private.pem  # 600 perms
    public: brain/pki/services/<agent_id>_public.pem (in alpha repo)
  algorithm: RS256
  rotation_schedule: 90 days (per ADR-0003 progressive plan)
  signed_audience: <agent_id>

audit_log:
  subject: jarvis.audit.<agent_id>
  destination: alpha_audit_events table + Loki
  retention_days: 90
  redaction_rules:
    - <FILL_IN: e.g. "redact contact_id when audit_log accessed by non-admin">
  required_fields:
    - timestamp
    - actor_sub
    - action_class
    - target
    - decision
    - confidence (if applicable)
    - approval_tier_applied
    - rls_role_at_execution
```

---

## 12. Failure Modes and Degradation

Per failure mode:

### Failure: `<FILL_IN: e.g. "Brain unreachable">`

- **Trigger condition:** `<FILL_IN: how to detect>`
- **Detection mechanism:** `<FILL_IN: e.g. "HTTP 5xx after 3 retries, 30s exponential backoff">`
- **Degraded behavior:** `<FILL_IN: what the agent does in this state>`
- **Recovery path:** `<FILL_IN: e.g. "Resume queue on Brain reachability">`
- **Alert:** `<FILL_IN: yes/no, what channel>`

`<Repeat per failure mode>`

Required failure modes to cover (at minimum):
- Brain unreachable
- Postgres unreachable
- Ollama unreachable (if used)
- Cloud LLM rate-limited or down (if used)
- MCP server unreachable
- Persona vault out of sync
- Approval Gateway timeout
- Cost cap exceeded
- Service identity key rotation in progress

---

## 13. Correction Loop Configuration

How Ken corrects this agent and how corrections propagate.

```yaml
veto:
  ui_button: <FILL_IN: e.g. "Veto" button on every Approvals page row>
  api_endpoint: POST /v1/<agent_id>/veto/{decision_id}
  veto_window_seconds: <FILL_IN: e.g. 300 for irreversible actions, instant for reversible>
  effect:
    - block action if not yet executed
    - mark decision row vetoed=true
    - emit jarvis.<agent_id>.veto event
    - do NOT immediately update persona/policy

annotation:
  ui_form: per-decision row, structured fields
  fields:
    - what_went_wrong: text
    - correct_behavior: text
    - rationale_class: <FILL_IN: enum of common categories>
  storage: alpha_decision_annotations
  effect: tag decision; surface in weekly consolidation

consolidation:
  cadence: weekly | biweekly
  threshold_count: 3       # require N annotations on same dimension
  cron_schedule: <FILL_IN: e.g. "0 8 * * SUN">
  target:
    - persona_tables (slow update path)
    - delegation_policy_file (rule revision PR draft for Ken review)
  effect: NEVER auto-merges policy changes — produces a draft PR for Ken
```

---

## 14. Child Safety Surface (omit section if not applicable)

```yaml
applicable: true

affected_profiles:
  - ryleigh (age 8)
  - sloane (age 5)

protections:
  rls_enforcement:
    - profile_id-scoped RLS on all child-touching tables
    - admin override audit-logged separately
  second_factor:
    required_for:
      - <FILL_IN: actions affecting child profile>
    factor_type: TOTP | hardware_key
  content_filtering:
    scope: <FILL_IN>
    review_path: <FILL_IN>

audit:
  separate_subject: jarvis.audit.child_safety.<agent_id>
  retention_days: 365
  reviewed_by: ken (weekly)

emergency_lockout:
  trigger: <FILL_IN: e.g. "anomaly score above N">
  effect: agent enters read-only mode, alerts Ken
```

---

## 15. Acceptance Criteria (Forge reviewer.py validates)

Forge marks this spec ready-for-build only when ALL criteria pass.

- [ ] All YAML blocks parse without error
- [ ] `agent_id` matches repo path and file name
- [ ] Service identity keypair path exists in §11
- [ ] Every skill in §1 has a matching capability in §4
- [ ] Every capability in §4 maps to an action class in §7
- [ ] Every action class in §7 has a default approval tier
- [ ] Unified policy file path in §8 resolves to a real file
- [ ] Every database table in §2 data_scope exists in `jarvis_alpha` (Forge queries pg_class to verify)
- [ ] Every MCP server in §9c is reachable from Brain (Forge probes /.well-known/agent-card.json)
- [ ] All required failure modes in §12 covered
- [ ] Correction loop endpoints in §13 are implementable (POST handlers planned)
- [ ] If `child_safety_surface.applicable: true`, §14 is fully populated
- [ ] No hardcoded IPs, secrets, paths in capability descriptions
- [ ] At least 3 test scenarios per category in §16

---

## 16. Test Plan

### 16a. Happy paths

- **Scenario:** `<FILL_IN: name>`
  - Setup: `<FILL_IN>`
  - Action: `<FILL_IN>`
  - Expected: `<FILL_IN>`
  - Validates: `<FILL_IN: which capability / acceptance criterion>`

### 16b. Failure paths

- **Scenario:** `<FILL_IN: e.g. "Brain unreachable during decision">`
  - Setup: kill Brain LaunchAgent
  - Action: agent attempts decision
  - Expected: degrades per §12 spec; emits failure event; recovers on Brain restart
  - Validates: §12 failure mode coverage

### 16c. Security paths

Required scenarios:
- Privilege escalation attempt (non-admin actor tries admin action) → must be denied + audited
- Identity spoofing attempt (wrong JWT) → must be rejected at AuthMiddleware
- Cost cap violation attempt → must be capped + alerted
- RLS bypass attempt (action_class=X but data_scope says read-only) → must be blocked
- Persona poisoning attempt (write to persona table from this agent's role) → must be blocked

### 16d. Child safety paths (if §14 applicable)

- Unauthorized read of child profile data → blocked
- Second-factor missing on protected action → blocked
- Admin override → succeeds but logged to child-safety audit subject

---

## 17. Changelog

| Date | Version | Author | Change |
|---|---|---|---|
| `<FILL_IN>` | 0.1.0 | ken | Initial draft |

---

## Worked example — Ken-Voice (abbreviated)

Below is a partial fill-in showing what the populated spec looks like for `ken-voice`. Not exhaustive; included to illustrate density and tone of completed sections.

```yaml
---
agent_id: ken-voice
agent_name: Ken-Voice
agent_class: voice
version: 0.1.0
status: draft
owner: ken
created: 2026-05-12
last_updated: 2026-05-12
supersedes: none
related_specs: [ken-delegate, business, family]
repo: github.com/kphaas/jarvis-ken-twin
---
```

### §3 Mission

Ken-Voice drafts, summarizes, and replies in Ken's tone across email, messaging, and document drafting. It does NOT send, commit, or spend. Sending and committing are handled by Ken-Delegate under explicit policy gates.

### §7 Action class mapping (excerpt)

| Action class | Examples in Ken-Voice | Default tier | Notes |
|---|---|---|---|
| `read_only_retrieval` | "Summarize last week's emails from Mike" | T1 | autonomous |
| `drafting_only` | "Draft a reply to this email" | T1 | autonomous; output never auto-sent |
| `low_risk_external_comms` | "Write a casual reply" | T2 | Ken reviews before Ken-Delegate sends |
| `spending_financial_commitment` | n/a | — | Out of scope for voice |
| `identity_legal_medical_child_reputation` | n/a | — | Out of scope for voice |

### §2 Governance excerpt

```yaml
governance:
  cost:
    cap_daily_usd: 3.00
    cap_monthly_usd: 60.00
    preferred_models:
      - ollama:llama3.1:8b
      - claude-haiku-4-5-20251001
  approval:
    tier_default: T1
    tier_overrides:
      low_risk_external_comms: T2
    confidence_floor: 0.7
    confidence_role: secondary
  data_scope:
    reads:
      - table: personality_voice
        rls_role: platform_admin
      - table: personality_values
        rls_role: platform_admin
      - table: alpha_conversation_memory
        rls_role: user
        tag_filter: source=personality AND tags LIKE 'core/voice%'
    writes:
      - table: alpha_buddy_events
        rls_role: platform_admin
    forbidden:
      - alpha_approval_queue (cannot mutate; Ken-Delegate handles)
      - personality_decision_heuristics (delegate's scope)
```

### §13 Correction loop excerpt

```yaml
veto:
  ui_button: "Reject Draft" on every Ken-Voice output card
  api_endpoint: POST /v1/ken-voice/veto/{draft_id}
  veto_window_seconds: irrelevant (drafts never auto-execute)
  effect:
    - mark draft rejected
    - capture rationale via annotation
    - DO NOT immediately update voice persona
```

---

*End of master template.*

*To use: copy this file, fill in placeholders, run `forge validate-spec`, hand to Forge planner/runner for autonomous build.*
