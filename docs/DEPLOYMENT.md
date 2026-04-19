# DEPLOYMENT Standard

How JARVIS services are packaged, deployed, and run.

**Last reviewed:** 2026-04-19 · **Review trigger:** every 4 sessions or when topology changes

---

## 30-Second Summary

- All services run as **Docker containers** (with narrow native exceptions — see §Exceptions)
- Stateful services live on **Unraid** (the pet). Stateless app services live on **Macs** (cattle).
- One compose file per machine, at `infra/compose/<machine>.yml`
- Portainer on Unraid manages all Docker endpoints from one UI
- Cross-machine networking via **Tailscale hostnames**, never hardcoded IPs
- Image tags are **pinned** (no `:latest`, ever)
- Secrets come from `~/jarvis/.secrets` (not committed)

See `ADR-0001` for the reasoning behind Docker adoption.

---

## Topology

```
┌──────────────────────────────────────────────────┐
│  UNRAID — STATEFUL (the pet)                     │
│  Postgres · NATS JetStream · Redis               │
│  Obsidian vault (SMB/NFS share)                  │
│  Observability stack · Backups · Portainer       │
└──────────────────────────────────────────────────┘
                    ↕  Tailscale mesh
   ┌──────────┬──────────────┬──────────────┐
   │          │              │              │
┌──┴───┐ ┌────┴────┐  ┌──────┴──────┐ ┌─────┴────┐
│BRAIN │ │ GATEWAY │  │  ENDPOINT   │ │  FORGE   │   MACS — STATELESS (cattle)
│      │ │         │  │             │ │          │
│alpha │ │ caddy   │  │ financial   │ │ dev +    │
│(llm) │ │ family  │  │ medical     │ │ claude   │
│ollama│ │   web   │  │ scrapers    │ │  code    │
│(nat- │ │ jwt     │  │ tool-use    │ │          │
│ ive) │ │  edge   │  │             │ │          │
└──────┘ └─────────┘  └─────────────┘ └──────────┘

Sandbox (M1 8GB) lives on isolated VLAN. Not part of the JARVIS tailnet.
```

---

## Exceptions — services that run natively

Only two services run outside Docker:

### 1. Ollama on Brain
**Reason**: needs Apple Metal GPU access. Docker Desktop runs a Linux VM that cannot access the Metal API. Native install is 10-50× faster than containerized CPU-only fallback.

**Install pattern**:
```bash
▶ BRAIN —
brew install ollama
brew services start ollama
# Ollama binds to localhost:11434
# Dockerized services on Brain reach it via host.docker.internal:11434
```

### 2. Claude Code on Forge
**Reason**: interactive dev tool, not a service. Needs direct terminal access, filesystem access to source repos, SSH into other machines. Containerization adds friction without benefit.

**Any other exceptions require an ADR.**

---

## Compose file organization

### Per-machine structure

```
jarvis-infra/
├── compose/
│   ├── unraid.yml          # Postgres, NATS, Redis, observability, Portainer, Family web (if here)
│   ├── brain.yml           # Alpha services
│   ├── gateway.yml         # Caddy, Family web (primary home post-swap), JWT edge
│   ├── endpoint.yml        # Financial, Medical, scrapers
│   └── forge.yml           # dev containers (Postgres-for-test, build runners)
├── env/
│   ├── .node_addresses     # Tailscale hostnames — committed
│   └── .env.*.example      # committed templates, real .env files NEVER committed
└── README.md
```

### Naming

- Compose project name = machine name: `name: jarvis-brain` in `brain.yml`
- Container names = `<project>-<service>`: `jarvis-brain-postgres` from `brain.yml`'s `postgres` service

---

## Image pinning — mandatory

**Never use `:latest`.** Always pin to a specific tag. Prefer digest-pinning for production-critical services.

```yaml
# ✅ Good
image: postgres:16.4-alpine
image: redis:7.4.1-alpine

# ✅ Better — digest-pinned (immutable)
image: postgres:16.4-alpine@sha256:abc123...

# ❌ Bad
image: postgres:latest
image: redis
```

**Rationale**: `:latest` is a moving target. A reproducible deploy requires a reproducible image. Digest pinning prevents supply-chain surprises from tag re-pushes.

**Update cadence**: pull new versions explicitly, per service, during planned maintenance — not on every restart.

---

## Registry strategy

### Today (acceptable)
- Pull from Docker Hub with pinned tags
- Cache locally on each Mac (Docker default)

### Planned (Sovereignty First hardening)
- Self-hosted registry on Unraid (`registry:2` container)
- Mirror all pinned base images to Unraid at adoption time
- Services pull from `unraid.${TAILNET}:5000/postgres:16.4-alpine` instead of Docker Hub
- If Docker Hub goes down, JARVIS keeps running

**Trigger for planned hardening**: first Docker Hub outage that affects us, or explicit sovereignty audit.

---

## Node addressing — no hardcoded hostnames

**Standard**: per `DEVELOPMENT_PROCESS.md § Cross-Repo Consistency #6` — no hardcoded IPs, hostnames, or URLs.

### The `.node_addresses` file

Lives at `infra/env/.node_addresses`. Committed. Plain shell-sourceable:

```bash
# infra/env/.node_addresses
# Canonical Tailscale hostnames for JARVIS nodes.
# Update here; everything else references these variables.

export TAILNET=your-tailnet.ts.net

export BRAIN_HOST=brain.${TAILNET}
export GATEWAY_HOST=gateway.${TAILNET}
export ENDPOINT_HOST=endpoint.${TAILNET}
export FORGE_HOST=forge.${TAILNET}
export AIR_HOST=air.${TAILNET}
export UNRAID_HOST=unraid.${TAILNET}

# Service ports (stable across JARVIS)
export POSTGRES_PORT=5432
export POSTGRES_FINANCIAL_PORT=5433
export REDIS_PORT=6379
export NATS_PORT=4222
export NATS_HTTP_PORT=8222
```

### Usage in compose files

```yaml
# ✅ Good — references env var
environment:
  POSTGRES_URL: postgresql://user:pass@${UNRAID_HOST}:${POSTGRES_PORT}/jarvis_alpha

# ❌ Bad — hardcoded
environment:
  POSTGRES_URL: postgresql://user:pass@unraid.ken-tailnet.ts.net:5432/jarvis_alpha
```

### Usage in shell commands + docs

```bash
# Source at the top of any script or session that references nodes
source ~/jarvis/infra/env/.node_addresses

# Then use variables everywhere
ssh "${BRAIN_HOST}"
nc -zv "${UNRAID_HOST}" "${POSTGRES_PORT}"
```

### Usage in Python code

Python services read the same concepts via `node_addresses.py` (one per repo until a shared helper is extracted):

```python
# node_addresses.py — stub, canonical impl pending F-XXX
import os

TAILNET = os.environ["TAILNET"]
BRAIN_HOST = f"brain.{TAILNET}"
GATEWAY_HOST = f"gateway.{TAILNET}"
# ...
```

---

## Secrets — `get_secret()` pattern

**Standard**: per `DEVELOPMENT_PROCESS.md § Cross-Repo Consistency #3` — all secrets via `get_secret()` reading from `~/jarvis/.secrets`.

### The secrets file

Lives at `~/jarvis/.secrets` on each machine. Mode `600`. **Never committed.** Shell-sourceable:

```bash
# ~/jarvis/.secrets
# Real values. Generate with: openssl rand -hex 32

export POSTGRES_ALPHA_PASSWORD=a1b2c3...
export POSTGRES_FINANCIAL_PASSWORD=d4e5f6...
export REDIS_PASSWORD=...
export NATS_ALPHA_PASSWORD=...
export NATS_FINANCIAL_PASSWORD=...
export NATS_FAMILY_PASSWORD=...
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export LITELLM_MASTER_KEY=sk-...
export LITELLM_SALT_KEY=...
```

### Usage in compose

Do NOT put secrets in compose files directly. Docker Compose reads them from the shell environment at `up` time:

```bash
▶ ANY MAC —
source ~/jarvis/infra/env/.node_addresses
source ~/jarvis/.secrets
docker compose -f compose/brain.yml up -d
```

In compose:
```yaml
services:
  postgres:
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_ALPHA_PASSWORD}  # pulled from env
```

### Bootstrap

First-time setup:
```bash
▶ ANY MAC —
mkdir -p ~/jarvis
touch ~/jarvis/.secrets
chmod 600 ~/jarvis/.secrets
# Paste generated secrets; do NOT commit
```

### Secret rotation

See `DEVELOPMENT_PROCESS.md § Decision Matrix` — secret rotation is **Air direct-edit only**, no AI agent allowed. Rotate individual values in `~/jarvis/.secrets`, then restart affected services.

---

## Docker runtime per machine

| Machine | Runtime | Auto-start | Rationale |
|---|---|---|---|
| Unraid | Built-in Docker | On boot | Unraid's default Docker plugin |
| Brain | **OrbStack** | At login | Fastest on Apple Silicon, better battery vs Docker Desktop |
| Gateway | OrbStack | At login | Same |
| Endpoint | OrbStack | At login | Same |
| Forge | OrbStack | At login | Same |
| Air | OrbStack | Manual | Laptop; dev only |
| Sandbox | None | — | Sandbox isn't part of JARVIS |

Docker Desktop is acceptable if OrbStack doesn't fit a contributor's situation. Both run the same containers.

---

## Portainer — admin UI

Portainer runs on Unraid. All Docker endpoints (Unraid + every always-on Mac) register agents so Portainer shows everything from one dashboard.

### Access
- URL: `https://${UNRAID_HOST}:9443`
- Auth: admin account created at first boot, password in 1Password
- ⚠️ Portainer admin = effectively root on all JARVIS Docker hosts. Long random password, never shared.

### Per-Mac agent install
```bash
▶ ANY MAC —
docker run -d \
  --name portainer_agent \
  --restart=always \
  -p 9001:9001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  portainer/agent:latest
```

Then in Portainer UI, add each as a "Docker Standalone — Agent" environment using `${BRAIN_HOST}:9001` etc.

---

## Compose conventions

### Standard top-matter

Every compose file starts with:

```yaml
# =============================================================================
# <MACHINE> — <role summary>
# =============================================================================
# See docs/DEPLOYMENT.md for conventions. Never hardcode hostnames — always
# source .node_addresses + .secrets before `docker compose up`.
# =============================================================================

name: jarvis-<machine>

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

x-restart: &default-restart
  restart: unless-stopped
```

### Every service includes

- `container_name` for predictable logs/exec targets
- `restart: unless-stopped` (via the anchor)
- `healthcheck` with realistic thresholds
- `logging: *default-logging` (bounds disk use)
- Explicit `volumes` and `networks`

### Networking

- Internal: Docker bridge network per machine, named `backend`
- Cross-machine: services bind to `127.0.0.1:<port>` on the host; Tailscale hostname is how other machines reach them
- Never expose a service on `0.0.0.0` unless it's the Gateway's Caddy

---

## Common operations

All commands assume you've sourced `.node_addresses` and `.secrets`.

### Start services on a machine
```bash
▶ ANY JARVIS MAC —
cd ~/jarvis/infra
docker compose -f compose/brain.yml up -d
```

### See what's running
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml ps
```

### Tail logs from one service
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml logs -f postgres
```

### Shell into a running container
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml exec postgres psql -U jarvis_alpha
```

### Pull updates (scheduled maintenance only)
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml pull
docker compose -f compose/brain.yml up -d
```

### Stop services (data persists in volumes)
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml down
```

### Destructive reset (loses all data in volumes)
```bash
▶ ANY MAC —
docker compose -f compose/brain.yml down -v   # ⚠️ removes volumes
```

---

## Backup integration

Docker volumes used for state (Postgres, NATS JetStream) are backed up nightly via Unraid's backup plugin. Specific schedule and retention per `BACKUP.md` (planned standard).

For Postgres specifically:
```bash
▶ UNRAID — nightly cron
docker compose -f compose/unraid.yml exec -T postgres \
  pg_dumpall -U jarvis_alpha | gzip > /mnt/user/backups/pg_alpha_$(date +%Y%m%d).sql.gz
```

---

## Forbidden patterns

1. `image: postgres:latest` — no floating tags
2. Hardcoded hostnames or IPs in compose files
3. Plaintext secrets in compose files (use env vars sourced from `~/jarvis/.secrets`)
4. `0.0.0.0` port binds on any machine except Gateway
5. Kubernetes manifests or Helm charts — scope is plain Compose only
6. Running stateful services on Macs (they belong on Unraid)
7. Running Ollama in Docker (breaks Metal GPU access — see §Exceptions)
8. `--privileged` containers (security footgun)
9. `network_mode: host` without an ADR justifying it
10. Pulling images from unofficial registries without an ADR

---

## Observability

Services emit structured logs per `LOGGING.md`. Container stdout is captured by Docker's json-file driver (bounded by the logging anchor above). Promtail on each Mac ships logs to Loki on Unraid. See `docs/OBSERVABILITY.md` (planned) for the full stack.

---

## Related standards

- `ADR-0001` — Adopt Docker for service deployment (the decision behind this doc)
- `LOGGING.md` — structured logging via `get_logger()`
- `SECURITY.md` (planned) — `get_secret()` pattern + no hardcoded IPs rule (this doc implements that)
- `OBSERVABILITY.md` (planned) — full Prom/Loki/Tempo/Grafana stack
- `BACKUP.md` (planned) — backup schedule + retention

---

## Amendment

Changes to this standard require:
1. Update this doc
2. Update the "Last reviewed" date
3. If the change affects a live decision, update or supersede the relevant ADR
4. Commit via `jarvisstandards_commit.sh`
5. Next JARVIS session opens with "new deployment standard in effect"

---

*Canonical source: github.com/kphaas/jarvis-standards/docs/DEPLOYMENT.md*
