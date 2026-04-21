# ADR-0002: State Native, Compute Containerized

**Status:** Accepted
**Date:** 2026-04-20
**Deciders:** Ken (architect)
**Supersedes:** Architecture Review V1 §1 line 23 ("No Docker anywhere — Homebrew native ARM binaries with LaunchAgents only")
**Related:** ADR-0001 (Adopt Docker deployment)

---

## Context

ADR-0001 established Docker (via OrbStack on Apple Silicon) as the target container runtime for JARVIS Alpha. That decision contradicted Architecture Review V1 §1 line 23 ("No Docker anywhere"), which had been the working rule through Alpha-1. This ADR resolves that contradiction and defines **which services run in containers versus natively**.

The naive path — "containerize everything" — is not the industry pattern. Big-tech practice consistently separates **state layer** from **compute layer**:

| Platform | Managed DB | App layer |
|---|---|---|
| AWS | RDS / Aurora on dedicated EC2 hosts (now including bare-metal RDS instances as of 2025) | ECS / EKS containers |
| GCP | Cloud SQL on managed VMs | GKE / Cloud Run containers |
| Azure | Azure SQL on Hyper-V VMs | AKS / Container Apps |
| Netflix | Cassandra on EC2 AMIs | Titus containers |
| Meta | MySQL on bare metal | Tupperware containers |

Perplexity validation (2026-04-20) confirmed additional points:

- Docker's own documentation states containers are best for **local Postgres development**, not production.
- Cybertec (Postgres consultancy) warns that production benefit in Docker requires Kubernetes + third-party operators (CloudNativePG, Crunchy, StackGres) plus custom upgrade tooling.
- InfoQ's stateful Kubernetes guidance explicitly recommends running stateful applications on VMs or bare metal external to the orchestrator.

Apple Silicon adds two specific constraints:

- Postgres in Docker on macOS: reported 2–4× performance penalty vs native due to hypervisor + filesystem indirection.
- Ollama in Docker on macOS: no Metal GPU access → CPU-only inference → llama3.1:8b unusably slow, which directly breaks the 79% local routing target.

## Decision Drivers

- Preserve Postgres performance on Apple Silicon (avoid the 2–4× Docker penalty)
- Preserve Ollama Metal GPU access (protect 79% local routing target)
- Match big-tech state/stateless pattern without over-engineering
- Avoid Kubernetes-only infrastructure (CloudNativePG, StackGres) at 3-node scale
- Maintain upgrade clarity (Homebrew `brew upgrade` simpler than Docker volume migration for DBs)
- Enable container benefits (immutability, rollback, resource limits) for stateless services
- Respect solo-operator constraints: simple to debug, minimal moving parts

## Options Considered

### Option A — Containerize Everything (REJECTED)
Move all services into containers, including Postgres, Ollama, SQLite, and Temporal.

- Postgres in Docker on macOS: 2–4× I/O penalty with no operator benefit at this scale
- Ollama in Docker: no Metal GPU access → unusable inference speed
- Kubernetes operators (the standard way to run stateful containers in production) are unavailable at this scale
- Major-version Postgres upgrades in containers without operators are brittle

### Option B — State Native, Compute Containerized (SELECTED)
Hybrid pattern matching AWS RDS + ECS / GCP Cloud SQL + GKE / Azure SQL + AKS.

### Option C — Keep Everything Native (REJECTED)
Stay with LaunchAgent-only deployment across all services.

- Loses image immutability and rollback benefits for stateless services
- The M1 → M4 Gateway swap (2026-04-20) demonstrated the brittleness of native deployment without templating
- Blocks future dev/prod parity
- Drifts further from industry norms

## Decision

**State layer runs native via LaunchAgent. Compute layer runs in OrbStack containers via Docker Compose.**

### Native (LaunchAgent) — exhaustive exception list

Modifications to this list **require an ADR amendment**.

| Service | Node | Justification |
|---|---|---|
| Postgres 16 + pgvector + extensions | Brain | Stateful, I/O-sensitive, extensions, clean upgrade path |
| SQLite (forge + module-local DBs) | Sandbox + any | File-based state — no runtime to containerize |
| Ollama (llama3.1:8b, qwen2.5-coder:7b) | Brain | Metal GPU access — non-negotiable for inference perf |
| Temporal server + UI | Brain | Stateful orchestrator, tied to native Postgres |
| Tailscale daemon | All nodes | Kernel-level networking |
| Voice UI / STT / TTS (future) | Endpoint | Audio I/O hardware access |

### Containerized (OrbStack + Compose)

| Service | Node |
|---|---|
| FastAPI Brain (`brain.app:app`) | Brain |
| FastAPI Gateway | Gateway |
| FastAPI forge dashboard | Sandbox |
| nginx | Endpoint |
| Buddy agent | Brain |
| TaskGraph executor | Brain |
| React UI build artifacts (served by nginx) | Endpoint |
| Future batch workers | Any |

### Container-to-Native communication

Containers reach native host services via `host.docker.internal` (supported natively by OrbStack):

- FastAPI Brain container → `postgres://host.docker.internal:5432/jarvis_alpha`
- FastAPI Brain container → `http://host.docker.internal:11434` (Ollama)
- FastAPI Brain container → `host.docker.internal:7233` (Temporal gRPC)

Compose files include `extra_hosts: ["host.docker.internal:host-gateway"]` for portability across Docker variants.

## Consequences

### Positive

- Native Postgres retains 2–4× performance advantage over Docker on macOS.
- Ollama retains Metal GPU access, protecting the 79% local routing target.
- Stateless services gain container benefits: immutable images, easy rollback, resource limits, per-service isolation.
- Clear architectural boundary aligned with AWS / GCP / Azure industry pattern.
- Fewer moving parts than Kubernetes + database operators.
- Simpler disaster recovery: state layer is a small, well-understood set of native services to back up.

### Negative

- Dual ops model: LaunchAgent for native services + Docker Compose for containers.
- Observability split: macOS unified log vs Docker logs — **unified log aggregation (Fluentbit / Loki) required**.
- Startup ordering: containers depend on native services being healthy (Postgres, Ollama, Temporal) — requires healthcheck gating.
- Secrets must be delivered to both surfaces — see ADR-0003.
- Exception-list drift risk: "just one more native service" temptation — requires ADR amendment discipline.

### Neutral

- Plist templating pattern (proven 2026-04-20 on Gateway M1 → M4 swap) carries forward for native services.
- Docker Compose per node handles the containerized set.
- Cross-node service discovery unchanged (Tailscale hostnames).
- Data-persistence strategy unchanged: Postgres WAL backup to Unraid (F-024).

## Follow-ups and Dependencies

- ADR-0003: Secrets Management Pattern (addresses delivery to both surfaces)
- F-024: Postgres WAL backup to Unraid (unchanged, targets native data directory)
- **Observability consolidation**: Fluentbit must tail both macOS unified log and Docker logs — prerequisite for Alpha-5 completion
- Architecture Review V1 §1 line 23 retired — document must be amended
- Per-node `docker-compose.yml` files to be created in jarvis-alpha repo under `deploy/<node>/`
- Inter-node mTLS certs: native and container consumers both need read access
- `host.docker.internal` resolution confirmed on OrbStack; verify for any future runtime migration

## References

- ADR-0001: Adopt Docker deployment
- `JARVIS_Alpha_Architecture_Review_V1.md`
- Perplexity validation transcript (session 2026-04-20)
- Docker official blog: "How to Use the Postgres Docker Official Image"
- Cybertec PostgreSQL: "Running Postgres in Docker — why and how?"
- AWS: Amazon RDS bare-metal instances launch (2025)
- InfoQ: "Netflix Uncovers Kernel-Level Bottlenecks While Scaling Containers" (Mar 2026)
- ACM Queue: "Titus: Introducing Containers to the Netflix Cloud"
- Google Cloud Blog: "To run or not to run a database on Kubernetes"
- CloudNativePG: Architecture documentation
- RepoFlow Benchmark: Apple Containers vs Docker Desktop vs OrbStack (Mar 2026)
