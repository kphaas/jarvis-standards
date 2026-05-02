# ADR-0006: OrbStack as default container runtime

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** Ken
- **Supersedes:** N/A
- **Related:** ADR-0001 (Adopt Docker deployment) — refines by specifying which runtime; ADR-0002 (state native, compute containerized) — resolves ambiguity in the §"Container-to-Native communication" reference to OrbStack; ADR-0004 (Alpha-5 execution standards); ADR-0005 (multi-writer coordination — governs how this runtime decision is operationally enforced via commit scripts)

---

## Context

ADR-0001 established Docker as the target containerization technology. ADR-0002 split state and compute layers, naming OrbStack in the "Container-to-Native communication" section but never as a standalone decision. As `jarvis-council`, `jarvis-financial`, `jarvis-family`, `jarvis-alpha`, and `jarvis-forge` all begin building containerized services in parallel, multiple repos need a single, citeable answer to "which container runtime do we use?"

This ADR formalizes OrbStack as the default and documents the alternatives evaluated. It promotes an implicit architectural choice into an explicit standard so future decisions across modules don't drift — one repo on Docker Desktop, another on Colima, a third on Apple Container.

The 2026 macOS container ecosystem has four mature options:

| Tool | Primary niche | Cost | Apple Silicon performance |
|---|---|---|---|
| OrbStack | macOS-first developer experience | Personal: free under 10K USD/yr; Commercial: 8 USD/user/mo | Best-in-class — 2s startup, ~200-300 MB idle, native Swift |
| Docker Desktop | Cross-platform parity (macOS + Windows + Linux) | Free under 250 employees / 10M USD revenue, then paid | Slower startup, 4-6 GB idle RAM, VM-based |
| Colima | CLI-only minimalist, scripting | Free, open source | Good — built on Lima/QEMU, no GUI |
| Apple Container | Native Apple framework, VM-per-container security | Free, open source | Very fast startup, but VM-per-container memory inefficient for 5+ services |

Two relevant 2026 developments shape this decision:

- **Apple Container (macOS 26 Tahoe, June 2025 WWDC release).** First-party, OCI-compatible, optimized for Apple Silicon. Architecture is VM-per-container — strong security isolation, but memory cost scales linearly with container count. As of v0.6.0 (Mar 2026), still pre-1.0 and "stability only guaranteed within minor versions" per Apple's own README. Lacks Compose support.
- **Docker Desktop licensing pressure.** Free for personal use and orgs under 250 employees / 10M USD revenue. JARVIS is solo-operator, well under the threshold, but the trend across alternatives is cleaner non-commercial licensing.

Industry direction (validated 2026-05-01 via web search):

- OrbStack is the consensus best Docker Desktop alternative for Apple Silicon macOS in 2026, per RepoFlow benchmarks (Nov 2025), The New Stack analysis (Mar 2026), DEV Community guides (Mar 2026), and Hacker News practitioner reports
- Three independent benchmarks (RepoFlow, sliplane, fsck.sh) consistently show OrbStack winning on macOS for: startup time, idle resource consumption, file-system performance for development workloads
- OrbStack is documented as a drop-in replacement for Docker CLI / Compose / Buildx with `orb migrate docker` providing single-command migration from Docker Desktop

The decision must specify a default macOS runtime, preserve the option to add Linux nodes (Unraid is already in the architecture per ADR-0002 future state), and not paint into a corner that prevents migrating to Apple Container post-v1.0.

## Decision

**OrbStack is the default container runtime for all macOS nodes (Brain, Gateway, Endpoint, Sandbox, Air) in the JARVIS ecosystem.** All committed Compose configuration must be runtime-agnostic to preserve portability to Linux nodes (Unraid today, future cloud VMs). Per-developer license selection follows OrbStack's published terms — solo-operator JARVIS uses the personal/non-commercial tier; commercial tier is required if operator commercial revenue connected to OrbStack use exceeds 10K USD/yr.

### Scope

| Repo | Container runtime | Notes |
|---|---|---|
| `jarvis-alpha` | OrbStack | Per ADR-0002, all compute-layer services |
| `jarvis-council` | OrbStack | All Council services (FastAPI, writeback, Redis, NATS) |
| `jarvis-forge` | OrbStack | Dashboard + workers when containerized |
| `jarvis-financial` | OrbStack | All services when containerized |
| `jarvis-family` | OrbStack | All services when containerized |

### Compose portability constraint

Committed `docker-compose.yml` files MUST NOT use OrbStack-specific features:

- No `*.orb.local` domain references in Compose configuration
- No `orb` CLI commands in committed scripts (use `docker` and `docker compose` only)
- No reliance on OrbStack's automatic container DNS — services that need to reach each other use Compose service names or environment variables
- No reliance on OrbStack-only host-networking shortcuts beyond what standard Docker Engine supports

This preserves the ability to run identical Compose files on:

- Linux servers (Docker Engine, Podman, containerd)
- Unraid Docker (native to Unraid, per ADR-0002 future-state references)
- Future cloud VMs or edge devices

OrbStack-specific affordances (auto-domains, faster volume mounts, native file-share) are fine in personal dev workflows but never in repo-committed configuration.

### Out of scope for this ADR

- **Unraid (Linux NAS at 192.168.30.10)**: Runs Unraid's native Docker engine, not OrbStack. Compose files for Unraid-hosted services follow the portability constraint above and run on Unraid's Docker without modification.
- **Future Linux nodes (cloud VMs, dedicated Linux servers, edge devices)**: Will use Docker Engine, Podman, or containerd as appropriate. Selection deferred until that need arises.
- **CI/CD runners (GitHub Actions, etc.)**: Use platform-provided container runtime. No JARVIS standard required.
- **Developer-local exploration**: Individual experimentation with Apple Container, Podman, or Colima alongside OrbStack is permitted. Only committed configuration is constrained.

### Operational standards

- Install via Homebrew Cask: `brew install --cask orbstack`
- Each developer maintains their own license under OrbStack's published terms
- Docker CLI, Compose, and Buildx are the supported interfaces
- Containers reach native services via `host.docker.internal` (per ADR-0002), supported natively by OrbStack
- Tailscale runs on the host (native), not as a sidecar; containers reach the tailnet via `host.docker.internal` or by forwarding ports to the host
- Commit scripts that build Docker images on macOS hosts will be generated from `jarvis-standards/scripts/_templates/` per ADR-0005, ensuring uniform OrbStack invocation

## Consequences

### Positive

- Single citeable standard across all `jarvis-*` repos eliminates per-repo runtime debate
- Best-in-class Apple Silicon performance — preserves Ollama working set on Brain (no Docker Desktop RAM competition)
- Native `host.docker.internal` and host networking simplify ADR-0002's container-to-native communication
- VirtioFS file-share is fast enough that bind-mounted source code for live-reload dev workflows performs well
- 2-second startup makes "stop containers when not in use" practical, lowering idle resource use further
- VPN, DNS, and Tailscale work without configuration changes
- Compose portability constraint preserves the option to add Linux nodes (Unraid services, cloud VMs) without rewriting any committed configuration

### Negative

- Vendor lock-in to a closed-source commercial product. Mitigated by: standard Docker CLI / Compose surface, the Compose portability constraint, and `orb migrate docker` for single-command migration to alternative runtimes
- Commercial license required if JARVIS operator revenue connected to OrbStack use ever exceeds 10K USD/yr — tracked operationally
- macOS-only — the runtime itself does not work on Linux. Mitigated by Compose portability constraint that keeps configuration runtime-agnostic
- Dependency on third-party update cadence for Apple Silicon optimization. Historically OrbStack ships fast; not currently a risk

### Neutral

- Migration from Docker Desktop is `orb migrate docker` — single command, no manual data migration
- Docker Compose YAML files remain portable across OrbStack, Docker Desktop, Colima, Linux Docker Engine
- Apple Container can be evaluated in parallel for new use cases without disrupting existing deployments

## Sovereignty First compliance

This ADR introduces and clarifies one external dependency (OrbStack) and one already-tracked dependency (Docker tooling).

| Component | Tier | Fallback |
|---|---|---|
| OrbStack | Tier 3 (closed-source commercial macOS app) | Colima (open-source, free, drop-in `docker compose` compatible); or Docker Desktop (commercial alternative); or Apple Container post-v1.0 with Compose support |
| Docker CLI + Compose + Buildx | Tier 1 (open-source, multi-platform protocol) | None needed — these are open standards implemented by OrbStack, Docker Desktop, Colima, Podman, and others |
| `host.docker.internal` resolution | Tier 1 (multi-runtime convention) | None needed — supported by all major runtimes; falls back to `extra_hosts: ["host.docker.internal:host-gateway"]` Compose directive for portability |

The **Compose portability constraint** in the Decision section is the structural sovereignty mitigation. Because committed Compose files never reference OrbStack-specific features, switching the underlying runtime is a config change (Homebrew Cask uninstall + install replacement), not a configuration rewrite. The runtime is replaceable; the application configuration is not coupled to it.

This ADR's net effect on sovereignty is neutral-to-positive. While it accepts a Tier 3 dependency, the explicit constraint structure provides a stronger fallback path than the implicit OrbStack reference in ADR-0002, which had no portability rule.

## Alternatives considered

### Option A — OrbStack (SELECTED)

See Decision section above.

### Option B — Docker Desktop

Use Docker Desktop as the runtime.

Rejected: 4-6 GB idle RAM directly competes with Ollama working set on Brain. Slower startup. File-system sync historically slower than OrbStack on macOS. Cross-platform parity is not a JARVIS need (no Windows or Linux dev machines today). Same Compose / CLI surface as OrbStack provides no portability advantage. Licensing tightens for organizations >250 employees / >10M USD revenue, which JARVIS is not, but the trend toward licensing pressure across alternatives makes this a less stable long-term default.

### Option C — Colima

Use Colima (Lima-based, CLI-only).

Rejected: free and open source, but slower than OrbStack on macOS, no GUI for solo-operator debugging, more complex networking configuration, and manual `colima start` adds operational friction. Acceptable as a fallback if OrbStack licensing or behavior becomes problematic. Listed in Sovereignty First fallback for that reason.

### Option D — Apple Container (REVISIT post-v1.0)

Use Apple's first-party `container` CLI and Containerization framework.

Rejected for now: native, free, OCI-compatible, optimized for Apple Silicon, but: (a) VM-per-container model is memory-inefficient at JARVIS scale where Brain runs ~10 services, (b) no Docker Compose support as of Mar 2026, (c) pre-v1.0 with explicit "stability only within minor versions" caveat from Apple, (d) requires macOS 26 Tahoe for full feature set. Genuine candidate for re-evaluation when v1.0 ships with Compose support.

### Option E — Mix per repo

Each repo picks its own runtime based on developer preference.

Rejected: cross-repo debugging becomes painful; documentation must hedge every Docker reference; defeats the purpose of `jarvis-standards` as a coordinating layer. Industry pattern (AWS internal services, Stripe, GitHub) consistently picks one runtime per environment scope rather than per-component.

### Option F — No standard, defer per-repo

Don't standardize at all; let each repo decide as containerization arrives.

Rejected: this is the implicit status quo from ADR-0001 and ADR-0002. The whole reason for ADR-0006 is that multiple repos are building containerized services right now. Deferring guarantees drift.

## Reversal conditions

Revisit this ADR if any of the following occur:

1. **OrbStack pricing exceeds JARVIS budget envelope.** If pricing changes such that solo-operator JARVIS exceeds free-tier thresholds and the cost of commercial licensing is no longer trivial relative to operational budget, switch to Colima.
2. **Apple Container reaches v1.0 with Compose support.** Re-evaluate Option D specifically against (a) memory consumption at JARVIS service count, (b) startup latency, (c) Tailscale and VPN compatibility. If favorable, this ADR is superseded.
3. **OrbStack-specific bug blocks JARVIS service for >30 days.** A specific service failure not addressed by OrbStack within 30 days triggers fallback to Colima.
4. **Cross-platform expansion requires runtime portability.** If JARVIS gains a Linux dev machine or Windows dev machine, the macOS-only constraint forces a re-evaluation. The Compose portability constraint preserves the option but doesn't decide it.
5. **Calendar review.** Re-evaluate this ADR annually (target Q2 2027) regardless of the above triggers. The container ecosystem moves fast — explicit review prevents this ADR from rotting silently.

## References

- ADR-0001 (this repo) — adopted Docker as containerization technology
- ADR-0002 (this repo) — state native, compute containerized; first OrbStack reference
- ADR-0004 (this repo) — Alpha-5 execution standards
- ADR-0005 (this repo) — multi-writer coordination (governs operational deployment of decisions in this ADR)
- `DEPLOYMENT.md` (this repo) — operational runbook for per-repo deployment
- OrbStack documentation: <https://docs.orbstack.dev/>
- OrbStack licensing: <https://docs.orbstack.dev/licensing>
- OrbStack networking and `host.docker.internal`: <https://docs.orbstack.dev/docker/network>
- OrbStack host networking: <https://docs.orbstack.dev/docker/host-networking>
- OrbStack vs. Colima comparison: <https://docs.orbstack.dev/compare/colima>
- Apple Container framework: <https://github.com/apple/container>
- Apple's Containerization framework deep dive (Anil Madhavapeddy, Jun 2025): <https://anil.recoil.org/notes/apple-containerisation>
- The New Stack — "OrbStack: A Deep Dive for Container and Kubernetes Development" (Mar 2026): <https://thenewstack.io/orbstack-a-deep-dive-for-container-and-kubernetes-development/>
- The New Stack — "Apple Containers on macOS: A Technical Comparison With Docker" (2026): <https://thenewstack.io/apple-containers-on-macos-a-technical-comparison-with-docker/>
- The New Stack — "What You Need To Know About Apple's New Container Framework" (2026): <https://thenewstack.io/what-you-need-to-know-about-apples-new-container-framework/>
- RepoFlow benchmark — "Apple Containers vs Docker Desktop vs OrbStack" (Nov 2025): <https://www.repoflow.io/blog/apple-containers-vs-docker-desktop-vs-orbstack>
- DEV Community — "Best Docker Desktop Alternatives in 2025" (Mar 2026): <https://dev.to/_d7eb1c1703182e3ce1782/best-docker-desktop-alternatives-in-2025-rancher-podman-orbstack-and-more-3n2c>
- sliplane — "OrbStack vs Docker Desktop" comparison (Mar 2025): <https://sliplane.io/blog/orbstack-vs-docker>
- fsck.sh — "Docker Desktop Alternatives 2025" (Jul 2025): <https://fsck.sh/en/blog/docker-desktop-alternatives-2025/>
- Setapp — "5 Best Docker Desktop Alternative Mac Options in 2026" (Jan 2026): <https://setapp.com/app-reviews/docker-desktop-alternatives-for-mac>
- InfoQ — "Apple Containerization: Native Linux Container Support for macOS" (2025): <https://www.infoq.com/news/2025/06/apple-container-linux/>
