# ADR-0023: Standardize Document Uploads on Alpha Vault

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** Ken, Codex
- **Supersedes:** N/A
- **Related:** `docs/DOCUMENT_UPLOADS.md`, `jarvis-financial/docs/adr/ADR-0011-alpha-vault-document-source-of-truth.md`

---

## Context

Multiple JARVIS domains need document upload: Financial tax returns, Family documents, project records, and future domain-specific archives. The system already has an Alpha vault path that stages uploaded documents on Alpha/JarvisSecure and mirrors durable classes to Unraid long-term storage. Creating separate local upload directories per domain would fragment the source of truth, make AT-0 recall inconsistent, and increase the chance that sensitive documents stay on the wrong machine.

## Decision

All JARVIS domain document uploads use Alpha vault as the default intake, archive, and ingestion boundary. The canonical path is `domain app -> Alpha vault upload -> Alpha staging -> Unraid long-term storage`. Domain apps classify documents, call Alpha upload/confirm, request Alpha ingestion when LLM recall is required, and store Alpha metadata plus domain-specific extraction results. Domain apps do not create durable local document stores or direct app-to-Unraid upload paths without a repo-specific ADR exception.

## Consequences

### Positive

- One document source of truth across domains.
- AT-0/LLM recall can be standardized through Alpha ingestion.
- Sensitive documents avoid accidental Sandbox-local persistence.
- Unraid remains the long-term storage target without every app needing SMB credentials.
- Domain apps can focus on domain extraction rather than storage plumbing.

### Negative

- Domain upload features depend on Alpha vault availability.
- Existing local-upload implementations need migration or fail-closed compatibility shims.
- Alpha ingestion must be completed for each file type that AT-0 needs to search.

### Neutral

- Domain apps still own domain-specific structured facts, such as tax return summaries or family document metadata.
- `50_SECRETS` remains NVMe-only and does not mirror to Unraid.

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| Alpha vault API | Tier 1 internal control plane | Fail closed; do not write locally |
| JarvisSecure staging | Tier 1 local controlled storage | Fail closed or hold in Alpha-managed staging only |
| Unraid SMB share | Tier 1 local long-term storage | Alpha returns `nvme_only` when unavailable |
| Ollama embeddings for ingestion | Tier 1 local inference | Store chunks without embeddings or mark ingestion degraded |

## Alternatives considered

### Per-domain local storage

Rejected because it creates multiple document sources of truth and leaves sensitive files scattered across app hosts.

### Direct app-to-Unraid writes

Rejected because each app would need mount/secrets handling and would bypass Alpha's archive, classification, and ingestion metadata.

### Upload to Alpha only, no ingestion standard

Rejected because archival alone does not make documents searchable or usable by AT-0. Ingestion must be explicit in the standard.

## Reversal conditions

1. Alpha vault is replaced by a dedicated document service with equivalent classification, archive, ingestion, and audit controls.
2. Unraid long-term storage is replaced by a different sovereign storage tier and Alpha vault is updated to target it.
3. A domain has a legal or operational requirement that cannot be met through Alpha vault and documents the exception in its own ADR.

## References

- `/Users/swetagurnani/jarvis-alpha/brain/routes/vault.py`
- `/Users/swetagurnani/jarvis-alpha/brain/storage/archive.py`
- `/Users/swetagurnani/jarvis-alpha/brain/ingest/pdf.py`
- `docs/DOCUMENT_UPLOADS.md`
