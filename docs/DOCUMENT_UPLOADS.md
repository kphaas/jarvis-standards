# Document Uploads

Alpha vault is the standard document intake, archive, and ingestion boundary for JARVIS.

The default durable path for any JARVIS domain is:

`domain app -> Alpha vault upload -> Alpha staging -> Unraid long-term storage`

Domain repos should not create durable local document stores, Sandbox-only upload folders, browser-local storage, or direct app-to-Unraid mounts unless a repo ADR explicitly accepts the exception.

## Default Flow

1. The domain app validates the upload and chooses a classification.
2. The domain app calls Alpha `POST /v1/vault/upload`.
3. Alpha writes the file into vault storage and creates `vault_documents` plus `vault_pipeline`.
4. The domain app calls Alpha `POST /v1/vault/pipeline/{pipeline_id}/confirm`.
5. Alpha stages the file on JarvisSecure and mirrors to Unraid when mounted and writable.
6. The domain app stores Alpha metadata and domain-specific extraction results.
7. The domain app calls Alpha ingestion when AT-0/LLM search or recall should know the document contents.

## Classifications

| Classification | Use |
|---|---|
| `10_PUBLIC` | Public/personal non-sensitive documents |
| `15_KIDS` | Child-safe/family-child documents |
| `20_PROJECTS` | Project and family operations documents |
| `30_FINANCE` | Financial, tax, insurance, banking, brokerage, accounting, and audit documents |
| `40_PRIVATE` | Private legal/identity documents that are not secrets |
| `50_SECRETS` | Secret material; Alpha keeps this NVMe-only and never mirrors it to Unraid |

Tax returns and financial planning documents use `30_FINANCE`.

## Ingestion and AT-0 Recall

Upload plus confirm archives the binary file. It does not, by itself, make the document content available to AT-0.

For recall, call the Alpha ingestion endpoint that matches the uploaded file type with the same bytes and `pipeline_id`:

- PDF: `POST /v1/vault/ingest/pdf`
- DOCX: `POST /v1/vault/ingest/docx`
- Plain text: `POST /v1/vault/ingest/text`
- Excel: `POST /v1/vault/ingest/excel`

PDF, DOCX, and plain-text ingestion extract text, chunk it into `vault_chunks`, and attempt embeddings with Ollama `all-minilm`. Excel ingestion loads workbook rows into Alpha-owned ingest tables.

The current Alpha text ingestion path does not create a Markdown file artifact. If a domain needs a canonical Markdown digest for review or audit, the domain should create an explicit digest artifact while keeping the original binary in Alpha vault.

## Domain Repo Requirements

- Store Alpha `doc_id`, `pipeline_id`, `classification`, archive status, tier/path metadata, content type, size, and checksum when available.
- Keep raw uploaded bytes only in request or job scope unless Alpha provides an approved retrieval/read path.
- Run domain-specific extraction from request bytes or approved Alpha retrieval, not from local durable copies.
- Fail closed if Alpha upload, archive, or required ingestion is unavailable.
- Do not log raw document text, secrets, or sensitive extracted values.
- Add a local repo invariant in `AGENTS.md` when a repo supports document uploads.

## Known Alpha Endpoints

- `POST /v1/vault/upload`
- `POST /v1/vault/pipeline/{pipeline_id}/confirm`
- `POST /v1/vault/ingest/pdf`
- `POST /v1/vault/ingest/docx`
- `POST /v1/vault/ingest/text`
- `POST /v1/vault/ingest/excel`

## Related Decisions

- `docs/adr/ADR-0023-alpha-vault-document-upload-standard.md`
