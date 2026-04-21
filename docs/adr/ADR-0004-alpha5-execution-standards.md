# ADR-0004: Alpha-5 Execution Standards

**Status:** Accepted
**Date:** 2026-04-21
**Deciders:** Ken (architect)
**Related:** ADR-0001 (Adopt Docker deployment), ADR-0002 (State Native, Compute Containerized), ADR-0003 (Progressive Secrets Management)
**Scope:** Operational execution standards for Alpha-5 container migration — image registry, Compose file layout, Tailscale cert renewal, registry pull authentication

---

## Context

ADR-0002 established the hybrid deployment pattern and ADR-0003 established the progressive secrets pattern. Those are the **what** and the **why**. This ADR addresses the **how** — four operational decisions required before the first container lands on a production node.

Each sub-decision was validated against 2026 industry practice via direct sourcing (OrbStack docs, Tailscale docs, Docker docs, CNCF project docs) and an independent Perplexity cross-check (2026-04-21).

## Decision Drivers

- Match big-tech / industry 2026 norms without overengineering for 3-node scale
- Preserve sovereignty posture (private AI infrastructure — do not leak artifacts to third parties unnecessarily)
- Minimize operational surface area for a solo operator
- Hardware-swap resilience (direct lesson from the 2026-04-20 M1 → M4 Gateway migration)
- Dyslexia-friendly clarity: per-node files beat multi-file inheritance
- Reversibility per phase — no one-way doors

---

## Decision 1 — Container Image Registry

### Decision

**Self-hosted `registry:2` (CNCF Distribution) container on Brain, Tailscale-only access with TLS, basic auth via htpasswd.**

- Deployed as a standard Compose service on Brain per ADR-0002 (stateless app container, data in bind-mounted volume)
- TLS via Tailscale-issued cert for `brain.tail40ed36.ts.net`
- Access restricted to the tailnet — no LAN or public exposure
- `htpasswd`-based basic auth per node; credentials stored in `~/jarvis/secrets.d/registry-pull.env` per ADR-0003
- Scheduled garbage collection via LaunchAgent on Brain

### Options Considered

| Option | Verdict |
|---|---|
| `registry:2` (CNCF Distribution) | **SELECTED** — canonical minimal private registry, 2026 default for self-hosted |
| Harbor (CNCF graduated) | **DEFERRED** to Alpha-6+ if scanning / SBOM / RBAC needed; requires Postgres + Redis + multiple components |
| ghcr.io | **REJECTED** — artifact sovereignty concern; images metadata leaks to GitHub/MS |
| `docker save` + scp distribution | **REJECTED** — manual, slow, drift-prone |
| Build on each node | **REJECTED** — 3× build time, environment-drift risk |
| Gitea registry | Noted alternative; deferred — forge repo on Sandbox does not yet run Gitea |

### Rationale

- Aligns with sovereignty-first architecture (stated project North Star)
- `registry:2` is the Distribution project — the open-source engine behind Docker Hub itself
- Harbor upgrade path is always available; image migration is a straightforward copy between OCI-compliant registries
- Pull bandwidth is LAN-speed over Tailscale mesh
- Restart-on-failure policy handles typical registry downtime
- Images cached on each node after first pull — registry downtime does not block container restart

### Follow-ups

- **GC routine is manual** in `registry:2` — requires scheduled LaunchAgent cron that marks+sweeps unused blobs
- **Tag discipline required**: `<service>:YYYY.MM.DD-N` format (e.g., `brain-api:2026.04.21-1`) to make retention trivial
- **Upgrade trigger to Harbor**: when vulnerability scanning, SBOM generation, or multi-operator RBAC becomes required

---

## Decision 2 — Docker Compose File Layout

### Decision

**Per-node Compose files** under `jarvis-alpha/deploy/<node>/docker-compose.yml`, with **light YAML `x-` extension-field anchors** inside each file for shared stanzas. Image tags centralized in a **root-level `deploy/.env`** file.

### Structure

```
jarvis-alpha/
├── deploy/
│   ├── .env                          # centralized image tags (BRAIN_API_TAG=..., etc.)
│   ├── brain/
│   │   └── docker-compose.yml
│   ├── gateway/
│   │   └── docker-compose.yml
│   └── endpoint/
│       └── docker-compose.yml
```

### Pattern

Image references use `.env` variables:

```yaml
services:
  brain-api:
    image: brain.tail40ed36.ts.net:5000/brain-api:${BRAIN_API_TAG}
```

Shared stanzas via `x-` anchors (limited to a few well-named entries per file):

```yaml
x-default-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

x-default-restart: &default-restart
  restart: unless-stopped

services:
  brain-api:
    <<: *default-restart
    logging: *default-logging
```

### Options Considered

| Option | Verdict |
|---|---|
| Per-node files + `deploy/.env` for tags + light `x-` anchors | **SELECTED** |
| Single file + Compose profiles | REJECTED — one broken service definition breaks every node; shared failure domain |
| Shared base + per-node overrides via `-f` merging | REJECTED — override precedence surprises; cognitive load high for 3 nodes |
| Compose v5 `!override` modifier | Available (Jan 2026) but buys little at this scale |

### Rationale

- Matches proven per-node LaunchAgent plist template pattern from 2026-04-20 Gateway swap
- Mental model: "this file is what runs on this node" — no conditional reasoning
- Centralized `.env` gives clean rollforward / rollback: one commit updates all nodes' target tags
- Image-tag centralization matches 2026 CI/CD Compose pattern
- `x-` anchors limited in scope; readability preserved

### Follow-ups

- Cap `x-` anchors to restart-policy, logging, and healthcheck defaults — do not extend into service-specific overrides
- `deploy/.env` is NOT a secrets file — treat as config; version-controlled
- Per-node `.env.local` optional for node-specific overrides (Tailscale IPs, ports) — gitignored

---

## Decision 3 — Tailscale Cert Renewal Signal to Containers

### Decision

**Staggered LaunchAgent on each node** runs a renewal script that uses `tailscale cert --min-validity=120h` to renew only when within 5 days of expiry, chowns the output files to the service runtime user, then **restarts the dependent container**. nginx receives **SIGHUP** instead (supports live reload).

### Schedule

Nodes stagger by day-of-month to avoid simultaneous mesh brownout:

| Node | Schedule |
|---|---|
| Brain | Daily 02:00 local |
| Gateway | Daily 02:30 local |
| Endpoint | Daily 03:00 local |

Each node's script is a no-op unless the cert has less than 120h validity, so scheduling density has no cost.

### Script pattern

```
# LaunchAgent-invoked renewal script
sudo tailscale cert --min-validity=120h <hostname>
chown <service-user>:<service-group> <cert-files>
docker compose -f /path/to/docker-compose.yml restart <service>  # or SIGHUP for nginx
```

### Options Considered

| Option | Verdict |
|---|---|
| LaunchAgent + `--min-validity` + container restart (+ SIGHUP for nginx) | **SELECTED** |
| Container restart universal — no SIGHUP | Viable but loses nginx's native reload capability |
| Inotify live file-watch inside each app | REJECTED — complexity inside every app; not worth it for 4 events/year |
| Tailscale sidecar container | REJECTED — Tailscale daemon must be native (kernel-level, per ADR-0002) |
| Reloader-style automation (K8s pattern) | Not applicable — no Kubernetes |

### Rationale

- Tailscale docs confirm the operator is responsible for renewals of file-based certs; `tailscale cert` does not automatically reinstall.
- Uvicorn (FastAPI host) does NOT support runtime TLS reload — full process restart is the correct mechanism.
- nginx supports SIGHUP for cert reload natively — use it where available.
- `--min-validity=120h` makes the renewal script idempotent; safe to run daily with zero ops cost.
- Staggering protects against self-inflicted mesh brownouts as more services are added.

### Follow-ups

- **Never** run `tailscale cert` in tight loops or at minute-level frequency
- Verify permissions (`chown` + `chmod 600` for key file) after renewal
- Pagerduty-equivalent alert (ntfy or local logger) on renewal failure — avoid silent breakage
- Test: manually advance cert expiry to within 120h, verify renewal fires on next LaunchAgent tick

---

## Decision 4 — Registry Pull Authentication

### Decision

**OrbStack default osxkeychain credential helper.** One-time interactive `docker login brain.tail40ed36.ts.net:5000` on each node stores credentials in the macOS keychain via `docker-credential-osxkeychain`. Containers pull at startup using the stored credential.

### ADR-0003 reconciliation (critical distinction)

ADR-0003 rejects macOS Keychain for **headless LaunchAgent application secrets**. This decision is explicitly scoped differently:

| Surface | Who reads? | Trigger | Keychain usage |
|---|---|---|---|
| App secrets (rejected by ADR-0003) | LaunchAgent-managed services at runtime | Automatic, headless | Headless prompt required → fragile |
| Registry pull creds (this ADR) | Docker engine via credential-helper protocol | One-time interactive `docker login` | Stored via helper, read by CLI — no runtime prompts |

The distinction is sound: Docker's credential-helper protocol is a different access pattern from a service reading Keychain directly. Docker docs and OrbStack docs both recommend osxkeychain on macOS. Once `docker login` runs in an interactive shell, subsequent `docker pull` calls (including LaunchAgent-triggered deploys) use the stored credential without prompting.

### Verification on fresh OrbStack install

After OrbStack install, confirm:

```
cat ~/.docker/config.json
```

Expected:

```json
{
  "credsStore": "osxkeychain",
  "auths": {
    "brain.tail40ed36.ts.net:5000": {}
  }
}
```

If `credsStore` is missing or set to a different value, edit the file and re-run `docker login`.

### Options Considered

| Option | Verdict |
|---|---|
| OrbStack default osxkeychain | **SELECTED** — matches Docker + OrbStack docs |
| Plain `~/.docker/config.json` base64 | REJECTED — less secure; 2026 best practice explicitly warns against this |
| Compose secret + ephemeral `docker login` | Deferred — more ceremony per deploy |
| JWT token-based pull auth on `registry:2` | DEFERRED to Alpha-6 vault phase (F-062) |
| OAuth2 device flow in front of `registry:2` | REJECTED — no built-in `registry:2` support; auth-proxy overhead overkill for 3 nodes |

### Rationale

- `docker-credential-osxkeychain` is the open-source credential helper shipped with Docker and automatically wired by OrbStack — NOT the full GUI Keychain prompt mechanism that breaks headless services
- LaunchAgent-triggered `docker pull` successfully retrieves credentials from osxkeychain in non-interactive contexts (same path used by headless CI agents)
- Avoids the 2026 downgrade of plain base64 `config.json` as "not secure"
- Migration to token-based pull auth becomes trivial when Phase 5c vault (ADR-0003) lands

### Follow-ups

- On each node, after first `docker login`, verify credentials are retrieved non-interactively: `docker-credential-osxkeychain list`
- Document break-glass procedure: if osxkeychain lock state ever prevents retrieval, fall back to re-running interactive `docker login`
- F-062 (P3): re-evaluate when Infisical/Bitwarden is selected in Alpha-6; agent-written token may replace interactive login entirely

---

## Consequences

### Positive

- Sovereignty posture preserved — no external registry dependency
- Hardware-swap resilience — rebuilding a node means: install OrbStack, `docker login`, pull from Brain registry, run Compose. No environment drift.
- Per-node Compose files match the proven LaunchAgent template pattern (2026-04-20 Gateway swap)
- Centralized `deploy/.env` gives atomic rollforward/rollback
- Tailscale cert renewal automated (partially closes a quarterly ops burden)
- Registry auth is secure-by-default (osxkeychain) without blocking vault migration later

### Negative

- Registry is single point of failure for NEW container deploys (image cache on each node mitigates restart scenarios)
- Registry GC is manual — requires scheduled maintenance LaunchAgent
- htpasswd credential rotation is manual until Alpha-6 vault phase
- Staggered cert-renewal schedule adds 3 LaunchAgent configurations to maintain
- `~/.docker/config.json` inconsistency between nodes is a real drift risk — verification step required on install

### Neutral

- Registry port (5000 default) is non-negotiable at `registry:2` level; firewall via Tailscale ACL, not port change
- Compose v5's `!override` feature remains available if the architecture grows beyond 3 nodes or gains significant per-environment variation
- OrbStack update channel does not affect these choices — all are Compose- and Docker-standard

## Follow-ups and Forge Backlog

| ID | Task | Priority |
|---|---|---|
| F-058 | `registry:2` deployment on Brain with TLS + htpasswd + garbage-collection LaunchAgent | P1 (blocks container migrations) |
| F-059 | `deploy/.env` centralized image-tag scheme + rollback procedure doc | P2 |
| F-060 | Verify `credsStore: osxkeychain` on each node post-OrbStack install | P2 |
| F-061 | Cert-renewal LaunchAgent on each node with staggered schedule | P2 |
| F-062 | Migrate registry pull auth to token-based when Phase 5c vault lands | P3 |

## References

- ADR-0001: Adopt Docker deployment
- ADR-0002: State Native, Compute Containerized
- ADR-0003: Progressive Secrets Management
- Perplexity validation transcript (session 2026-04-21)
- Docker Distribution (CNCF) project docs
- OrbStack documentation: `https://docs.orbstack.dev/docker/`
- Tailscale CLI reference: `tailscale cert` and `--min-validity`
- Tailscale security best practices documentation
- Docker registry authentication documentation
- CNCF Harbor project (deferred upgrade path)
- Docker Compose v5.0.2 release notes (Jan 2026)
