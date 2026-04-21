# ADR-0003: Progressive Secrets Management Pattern

**Status:** Accepted
**Date:** 2026-04-20
**Deciders:** Ken (architect)
**Related:** ADR-0001 (Adopt Docker deployment), ADR-0002 (State Native, Compute Containerized)

---

## Context

ADR-0002 creates two distinct secret-delivery surfaces:

1. **Native services** — Postgres, Ollama, Temporal, Tailscale — read secrets from the host filesystem via LaunchAgent environment variables or config files.
2. **Container services** — FastAPI × 3, nginx, Buddy, TaskGraph executor, forge dashboard — need JWT keys, rotating service tokens, cloud API keys, and DB credentials delivered into container filesystem.

### Accumulated debt (pre-Alpha-5)

- Monolithic `~/jarvis/.secrets` file (chmod 600) with all secrets in a single blob
- Hardcoded `/Users/infranet/` paths **inside** the `.secrets` file — broke during M1 → M4 Gateway swap (2026-04-20)
- 8 different files each define their own `get_secret()` implementation (F-034)
- `GATEWAY_TOKEN` and `JARVIS_GATEWAY_TOKEN` both exist — canonical name unclear
- Preservation bundle (2026-04-20) missed `~/.gcp_billing.json` because the script scanned `~/jarvis/` only
- Service identity RS256 private key was nearly lost before M1 wipe — retrieved at the last minute
- F-023 (90-day rotation) has a countdown display but no automation
- Sandbox uses `~/.secrets`, Brain + Gateway use `~/jarvis/.secrets` — inconsistent location

### Industry reference points

- **Big-tech pattern:** AWS Secrets Manager / GCP Secret Manager / Azure Key Vault with IAM-based per-service access and automated rotation. For ~10 secrets and one operator, full vault infrastructure is overkill (Perplexity validation 2026-04-20).
- **Twelve-Factor App (III. Config):** secrets must be separate from code and supplied by environment. Modern interpretations add: file mounts > environment variables, per-service least privilege, central rotation once complexity grows.
- **NIST SP 800-57 Rev. 5:** minimize the number of root keys, treat root-level access as emergency break-glass with logging. Applies to the bootstrap credential for any vault.
- **Security best practice (Wiz, GitGuardian, SUSE):** prefer file-based mounts over environment variables for container secrets; env vars can leak via process listings, log aggregation, and child-process inheritance.

## Decision Drivers

- Improve secret hygiene immediately without blocking Alpha-5 delivery
- Enable per-service least privilege
- Match big-tech pattern at appropriate scale (central-ish store + per-service access + rotation)
- Survive hardware swaps without manual secret-file editing (direct lesson from 2026-04-20)
- Close F-023 (rotation) and F-034 (`get_secret()` consolidation) with a clear path
- Avoid over-engineering for 10 secrets and one operator
- Preserve the ability to migrate to a full vault later **without rewriting application code**
- Apply file-mount delivery over environment variables

## Options Considered

### Option A — Progressive: files → Compose secrets → external vault (SELECTED)
Three phases matching the natural evolution of big-tech deployments: config files → orchestrator secrets → central vault.

### Option B — Docker Compose secrets only, no vault ever
Stops at Phase 5b. Simpler, less overhead, but misses automated rotation and central audit.

- **Rejected because:** rotation at scale (even 10 secrets across many nodes) is a real operational burden without vault tooling, and the "big-tech pattern" bar favours a central store when feasible.

### Option C — Infisical or Bitwarden Secrets Manager now
Deploy vault in Phase 5a, skip the intermediate file-based step.

- **Rejected because:**
  - Bootstrap problem becomes immediate complexity during an already disruptive Alpha-5 rollout.
  - Higher failure-domain exposure: runtime change + deployment-pattern change + secrets-pattern change all simultaneously.
  - Adds a new service to debug before Alpha-5 has stabilised.
  - Phase 5a delivers substantial value independently.

### Option D — HashiCorp Vault now
Full enterprise-grade vault deployment.

- **Rejected because:**
  - Overkill for 10 secrets and one operator (Perplexity confirmed).
  - Steep learning curve plus policy / unseal-key management overhead.
  - Designed for enterprise PKI and dynamic secrets — use cases we do not have.

## Decision

**Adopt a three-phase progressive pattern.**

### Phase 5a — File-based per-service secrets (Alpha-5 core)

**Directory structure:**

```
~/jarvis/secrets.d/
├── MANIFEST.md              (canonical list — consumed by preservation scripts)
├── anthropic.env
├── perplexity.env
├── gemini.env
├── gcp-billing.json
├── postgres.env
├── jwt-signing.pem          (Brain only)
├── jwt-public.pem           (all nodes)
├── gateway-service.env      (rotating)
├── brain-service.env        (rotating)
├── endpoint-service.env     (rotating)
├── alpha-pin.env
├── unifi.env                (Gateway only)
└── tailscale-auth.env       (bootstrap only)
```

**Rules:**

- `chmod 600`, owned by the service runtime user on the host.
- **Never** contain hardcoded `/Users/xxx` paths. Always `$HOME` or a canonical absolute path documented in MANIFEST.md.
- Each file has a single logical purpose (one API provider or one service identity per file).
- Loaded via a unified `get_secret()` implementation in `jarvis-standards`.

**Container delivery:**

- Docker Compose `secrets:` top-level stanza references files from the host.
- Each service declares **only** the secrets it needs.
- Mounted at `/run/secrets/<name>` inside the container.
- Applications read from file path, **never** from environment variables (except short-lived backward-compat shims during migration).

**Native delivery:**

- LaunchAgent `plist` references `$HOME/jarvis/secrets.d/<service>.env` via an env-var path (not the secret value itself).
- `get_secret()` reads the file, caches in process memory, logs access.

**Manifest:**

- `~/jarvis/secrets.d/MANIFEST.md` lists every secret — owner service, file path, rotation schedule, and category (bootstrap / rotating / static).
- Preservation / migration scripts consume this manifest to determine what to back up — **prevents repeat of the `.gcp_billing.json` miss from 2026-04-20**.

### Phase 5b — LaunchAgent-driven rotation (Alpha-5 late)

- Rotation LaunchAgents (stubs already exist on Brain: `com.jarvis.alpha.rotate.brain_service`, `rotate.buddy`; Gateway / Endpoint equivalents to be installed).
- Grace period during rotation: old and new tokens both valid for N seconds to avoid auth cliffs.
- Rotation scope limited to internal service tokens (JWT-signed inter-node auth).
- Cloud API keys rotated manually until Phase 5c.
- Closes F-023 for internal service tokens.

### Phase 5c — External vault (Alpha-6, deferred)

- Final vault choice deferred to Alpha-6 kickoff session.
- Shortlist: **Infisical** (self-hosted) or **Bitwarden Secrets Manager**.
- Vault is deployed as a containerized service on Brain (per ADR-0002 — stateless app layer), with its data store native.
- Vault agent writes secrets into the same files applications already read (Phase 5a paths unchanged).
- **Zero application code change** during vault adoption — agent replaces manual file updates.
- Bootstrap credential stored in password manager + FileVault-encrypted disk.
- Break-glass procedure documented per NIST SP 800-57 root-key guidance.

### SOPS + age (optional complement)

- Permitted for **encrypted-config-in-git** use cases.
- Does **not** replace Phase 5a / 5b / 5c; it complements them.
- Used for committed, encrypted configuration adjacent to code (service configs, non-rotating infrastructure parameters).
- Not required — listed as an optional tool if the need arises.

## Consequences

### Positive

- Immediate improvement in secret hygiene — Phase 5a is deployable within Alpha-5.
- Path to vault without blocking Alpha-5 delivery.
- **Zero application code change** during Phase 5c vault adoption (agent writes to the same files apps already read).
- Preservation scripts consume MANIFEST — prevents repeat of 2026-04-20 `gcp_billing.json` oversight.
- Least privilege from Phase 5a: each container sees only its own secrets.
- File-mount delivery reduces env-var leakage via process listings and log aggregation.
- NIST-aligned root-key minimisation via break-glass model.
- Closes F-023 (partial) and F-034 (full) during Phase 5a / 5b.

### Negative

- Phase 5a produces ~12 files where there was one — more metadata to track (mitigated by MANIFEST).
- "Phase 5c later" carries drift risk — requires forge backlog discipline with target dates.
- Manual cloud API key rotation until Phase 5c.
- Bootstrap credential remains file-based permanently — fundamental to secrets management (NIST SP 800-57 acknowledges this).
- Compose `secrets:` stanza is local-host scoped; multi-host sync is manual until Phase 5c.
- Dual delivery paths (native file vs Compose secret) increase surface area.

### Neutral

- Compose `secrets:` stanza works outside Swarm mode (confirmed by Wiz / Semaphore / GitGuardian / IBM mq-container GitHub issue #588).
- `get_secret()` consolidation becomes a prerequisite for Phase 5a (F-052).
- Phase 5a is essentially free — Compose secrets are built into OrbStack, per-service files are trivial to create.

## Follow-ups and Dependencies

| ID | Task | Phase | Priority |
|---|---|---|---|
| F-051 | Split `.secrets` into `secrets.d/` per-service directory | 5a | P1 |
| F-052 | Consolidate `get_secret()` into `jarvis-standards` (closes F-034) | 5a | P1 (blocks 5a) |
| F-053 | Create `MANIFEST.md` and wire preservation scripts to read it | 5a | P1 |
| F-054 | Remove hardcoded `/Users/xxx` paths; use `$HOME` expansion everywhere | 5a | P1 |
| F-055 | LaunchAgent service-token rotation with grace period | 5b | P2 |
| F-056 | Evaluate Infisical vs Bitwarden Secrets Manager (pick + deploy) | 5c | P3 |
| F-057 | SOPS + age for encrypted-config-in-git (optional complement) | N/A | P3 |

## References

- ADR-0001: Adopt Docker deployment
- ADR-0002: State Native, Compute Containerized
- Twelve-Factor App — III. Config — https://12factor.net/config
- NIST SP 800-57 Rev. 5 Part 1: Recommendation for Key Management
- HashiCorp Vault: Root token regeneration best practices
- Wiz: "Docker Secrets Explained — Setup, Best Practices & Examples"
- GitGuardian: "4 Ways to Securely Store & Manage Secrets in Docker"
- SUSE: "Six Essential Docker Security Best Practices for Safe Containers"
- Perplexity validation transcript (session 2026-04-20)
- IBM mq-container GitHub issue #588 — Compose secrets outside Swarm
- Infisical: Self-hosting documentation for homelabs
- AWS ECS: Pass Secrets Manager secrets programmatically
- GCP Cloud Run: Access Secret Manager secrets as environment variables
- Azure Container Apps: Key Vault integration guidance
