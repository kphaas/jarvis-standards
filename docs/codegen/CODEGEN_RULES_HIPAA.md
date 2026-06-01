### Codegen Rules — HIPAA overlay
Engineering controls supporting HIPAA — NOT legal compliance certification.
Tiers: [CI] deterministic gate · [LLM] review judgment · [CI+LLM] both.
- PHI encrypted in transit and at rest. [CI+LLM]
- No PHI in logs, errors, traces, or test fixtures — ever. Synthetic/de-identified data only. [CI+LLM]
- Least-privilege access; audit-log every PHI read/write. [LLM]
- PHI must not leave the trust boundary without gated de-identification; on uncertainty, FAIL CLOSED. [LLM]
- Data minimization; secure deletion. [LLM]
