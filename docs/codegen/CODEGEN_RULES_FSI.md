### Codegen Rules — FSI overlay
Engineering controls supporting FSI — NOT legal compliance certification.
Tiers: [CI] deterministic gate · [LLM] review judgment · [CI+LLM] both.
- Immutable audit trail on every financial action/decision. [LLM]
- Idempotent money operations; no partial or silent failure on money paths. [LLM]
- Kill-switch / circuit-breaker + pre-trade validation gates honored (per jarvis-financial's kill-switch / pre-trade governance ADR). [LLM]
- Data-integrity and reconciliation checks; segregation of duties. [LLM]
- No financial credentials/keys in code. [CI]
