## Codegen Rules
Source of truth: ADR-0019 (Discovery-First) + ADR-0020 (Anti-Slop) in jarvis-standards/docs/adr/. Canonical — edit here in jarvis-standards; consumed read-only by forge.

Before coding (ADR-0019):
- Read files_to_touch + their direct dependencies before editing. Verify signatures, columns, config keys, and patterns by READING — never assume from memory or the spec.
- Reuse existing helpers; do not reinvent.
- If the spec conflicts with reality (missing/different symbol, column, endpoint) → STOP, surface needs_input. Do not improvise.
- Edit only files_to_touch. Discovery scope = edit scope.

Quality floor — every bar is a gate (ADR-0020):
Tiers: [CI] deterministic gate · [LLM] review judgment · [CI+LLM] both.
1. Complete — no untracked stubs (TODO/FIXME/pass-stub/NotImplementedError). Defer only via a filed TD referenced inline: TODO(TD-###). Else → needs_input. [LLM]
2. Real error handling — no bare except / silent swallow; match the repo's pattern. [CI+LLM]
3. Tested — new behavior gets tests; fixes get a regression test. [CI]
4. Conform to existing patterns (discovered first). No second way to do an existing thing. [LLM]
5. Verified APIs — never call an unconfirmed symbol/endpoint/column. [LLM]
6. DRY — reuse discovered helpers. [LLM]
7. Edge cases — handle empty/None/error inputs. [LLM]
8. YAGNI — minimal change meeting acceptance criteria; no speculative abstraction. [LLM]
9. Security — no hardcoded secrets/IPs/tokens/certs; secrets via get_secret(); never log secrets. [CI]
10. Observable — repo structured logging; no leftover print/debug. [CI+LLM]
11. In-scope — only files_to_touch; no drive-by refactors. [CI+LLM]
12. Commit hygiene — ADR-0005 trailers; no Co-authored-by; title ≤70 chars. [CI]
13. Documented interfaces — docstrings on public functions/APIs. [LLM]
14. Migration-safe — schema/API changes reversible + backward-compatible. [LLM]
15. CI-green — format/lint/type/test/scanners pass before merge. [CI]
