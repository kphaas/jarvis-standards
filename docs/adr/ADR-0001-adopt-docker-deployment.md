# ADR-0001: Adopt Docker for service deployment

- **Status:** Accepted
- **Date:** 2026-04-19
- **Deciders:** Ken
- **Supersedes:** N/A (first ADR in this repo)
- **Related:** `DEVELOPMENT_PROCESS.md` (Sovereignty First principle), `docs/DEPLOYMENT.md` (deployment conventions)

---

## Context

Until now, JARVIS services have been run natively on macOS hosts (Homebrew-installed Postgres, direct `uv run` processes, etc.). This worked at 1-2 services on 1-2 Macs. As JARVIS grows to match the Marvel-Jarvis vision — pervasive, always-available, spanning Alpha (brain/memory), Financial, Medical, Family, Forge, and future capabilities — several pressure points have emerged:

1. **5+ services across 5+ machines** means 5 different install procedures, scattered config files in `/etc` and `/opt/homebrew`, hostname-specific port conflicts, and fragile upgrade paths.
2. **Reproducibility**: a new always-on Mac (Forge, future Business/Home nodes) means replaying a long README of `brew install` commands. Drift is inevitable.
3. **Service isolation**: running Financial's scrapers, Medical's pollers, and Alpha's buddy agent as sibling processes on one Mac shares a blast radius. An RCE in a scraper has the same filesystem as Alpha's memory.
4. **State vs compute separation**: Marvel-Jarvis-grade availability requires stateful services (Postgres, NATS, Redis) on hardware built for it — Unraid, not a consumer Mac. Moving state off a Mac is cleaner with containers than with Homebrew.
5. **Cost tracking / observability**: each service emits telemetry, but aggregating across native macOS processes means host-specific logging configs. Containers normalize stdout + labels.

These are problems at JARVIS's current scale — not hypothetical future scale.

## Decision

**All JARVIS services run as Docker containers**, with two narrow exceptions. Plain Docker per machine + Portainer for unified management. No Swarm, no Kubernetes.

### Exceptions (native macOS)

1. **Ollama on Brain** — requires Apple Metal GPU access, which Docker Desktop's Linux VM cannot provide. Running in Docker = 10-50× slower CPU-only fallback. Native install via `brew install ollama` is mandatory.
2. **Claude Code on the Forge Mac** — interactive dev tool, not a service. Runs natively.

### Topology

- **Stateful services** run on Unraid (Postgres, NATS JetStream, Redis, Obsidian vault share, observability stack, backups). Unraid is the "pet" with ECC RAM, parity, backups.
- **Stateless application services** run on Macs (Alpha on Brain, Family web on Gateway, Financial + Medical on Endpoint, dev tooling on Forge). Macs are "cattle" — disposable app hosts.
- **Cross-machine connectivity** via Tailscale mesh, addressed by hostname only (never hardcoded IPs).

## Consequences

### Positive

- **Reproducibility**: a new node = Docker install + `docker compose up`. No README scavenger hunt.
- **Ops consistency**: same commands (`docker compose up/down/logs/exec`) across every service, every machine.
- **Service isolation**: each service in its own namespace. Scraper RCE has a smaller blast radius.
- **Clean upgrades**: `postgres:16` → `postgres:17` is an image tag change + migration, not a weekend.
- **Portability**: moving Family from Gateway to Unraid in the future is a compose-file change, not a rebuild.
- **Observability hooks**: Promtail → Loki works over Docker's stdout capture without per-service logging config.
- **Unified management**: Portainer provides a single dashboard across all Docker hosts.

### Negative

- **Mac Docker has a VM penalty**: file I/O and network have ~5-15% overhead under Docker Desktop. Negligible at personal scale; mitigated by OrbStack over Docker Desktop.
- **One more abstraction layer**: debugging becomes "is it the app or the container?" — new muscle memory required.
- **Image supply chain**: base images from Docker Hub introduce external dependencies (see Sovereignty implications below).
- **Licensing drift risk**: Docker Desktop is free for personal use; commercial use requires a paid plan. OrbStack is similar ($8/mo for pro). Changes if any contributor's situation changes.

### Neutral

- Compose files become part of the infra surface area (reviewed, versioned, commit-scripted).
- `/infra/compose/<machine>.yml` per-machine pattern; no monorepo Kubernetes manifest soup.
- Dev workflow is Path A (per handoff): Docker for prod, `uv run` for the ONE app you're actively editing.

## Sovereignty First compliance

Per `DEVELOPMENT_PROCESS.md`, every external dependency must have a documented fallback. Docker adoption introduces multiple dependencies at different tiers:

| Component | Tier | Fallback |
|---|---|---|
| Docker Engine (the runtime) | **Tier 1** | Open-source, no phone-home, survives internet outage. No fallback needed. |
| OrbStack / Docker Desktop (Mac) | **Tier 3** | Colima (free, open-source) or Podman (free, Red Hat). Both run the same containers. Switching is ~1 hour per Mac. |
| Docker Hub base images | **Tier 3** | Pin specific versions (never `:latest`). Mirror pinned images to a local registry on Unraid as Tier 1 fallback (planned, not blocking). |
| Portainer (admin UI) | **Tier 3** | Native `docker` CLI is the always-available fallback. Portainer is convenience, not load-bearing. |
| Anthropic API (via LiteLLM) | **Tier 2** | Ollama on Brain (already documented in `DEVELOPMENT_PROCESS.md` Fallback Triggers). |

**Conclusion**: Docker adoption is compatible with Sovereignty First. The weakest link (Docker Hub pulls during image refresh) is mitigated by version pinning and a planned local registry mirror on Unraid.

## Alternatives considered

### Option A — Stay native (Homebrew services everywhere)
Keep `brew services` for Postgres/Redis, `uv run` in systemd-like wrappers for services.
- ✅ Pure Tier 1 sovereignty (no external dep at all).
- ❌ Scales badly past 2-3 services. Upgrade paths are manual. Service isolation weak. New nodes mean long setup.
- **Rejected** as the current pain point driving this ADR.

### Option B — Kubernetes (K3s or full K8s)
Real orchestration, declarative, production-proven.
- ✅ Industry standard.
- ❌ Massive overkill at 5-6 services. Ops burden alone exceeds the savings. "No Kubernetes until you have reason to" is its own well-known principle.
- **Rejected** as premature.

### Option C — Docker Swarm
Multi-host orchestration built into Docker.
- ✅ Simpler than K8s.
- ❌ In maintenance mode. Community momentum moved to K8s. Mac Docker + Swarm is a corner case with poor docs.
- **Rejected** as a dying path.

### Option D — Nomad
HashiCorp's orchestrator, lighter than K8s.
- ✅ Real orchestrator without K8s weight.
- ❌ Adds a second control plane alongside Docker. Additional Tier 3 dependency (HashiCorp).
- **Rejected** as adding complexity without proportional benefit at current scale.

## Reversal conditions

Revisit this decision if:

1. **Docker Desktop / OrbStack performance becomes a material bottleneck** measured on Brain (e.g., p95 latency on LLM calls regresses >15% vs native baseline).
2. **Docker Hub supply-chain incident** where a widely-used base image is compromised. (Mitigation: move to local registry mirror before this happens, not after.)
3. **JARVIS scales to 10+ services across 5+ nodes** to the point where plain Compose per machine becomes painful. Then re-evaluate K3s or Nomad.
4. **Commercial contributor added** whose employer requires K8s for compliance. Low probability, worth documenting.

## References

- `DEVELOPMENT_PROCESS.md` § Core Principle — Sovereignty First
- `DEVELOPMENT_PROCESS.md` § Sovereignty Tiers
- `docs/DEPLOYMENT.md` — deployment conventions under Docker
- ADR template: `docs/adr/TEMPLATE.md` (to be added)
