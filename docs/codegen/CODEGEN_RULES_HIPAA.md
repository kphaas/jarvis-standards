### Codegen Rules — HIPAA overlay
Engineering controls supporting HIPAA — NOT legal compliance certification.
- PHI encrypted in transit and at rest.
- No PHI in logs, errors, traces, or test fixtures — ever. Synthetic/de-identified data only.
- Least-privilege access; audit-log every PHI read/write.
- PHI must not leave the trust boundary without gated de-identification; on uncertainty, FAIL CLOSED.
- Data minimization; secure deletion.
