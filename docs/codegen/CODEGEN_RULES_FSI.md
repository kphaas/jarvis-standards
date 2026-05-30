### Codegen Rules — FSI overlay
Engineering controls supporting FSI — NOT legal compliance certification.
- Immutable audit trail on every financial action/decision.
- Idempotent money operations; no partial or silent failure on money paths.
- Kill-switch / circuit-breaker + pre-trade validation gates honored (per jarvis-financial's kill-switch / pre-trade governance ADR).
- Data-integrity and reconciliation checks; segregation of duties.
- No financial credentials/keys in code.
