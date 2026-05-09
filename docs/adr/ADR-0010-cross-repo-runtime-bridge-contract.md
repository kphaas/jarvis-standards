# ADR-0010: Cross-Repo Runtime Bridge Contract

**Repo:** `jarvis-standards`
**Status:** Proposed (pending review)
**Date:** 2026-05-09
**Author:** Ken Haas (architecture reviewer: Claude Opus 4.7)
**Supersedes:** —
**Related:**
- ADR-0002 (this repo) — State native, compute containerized (foundation for hybrid pattern this contract operates within)
- ADR-0005 (this repo) — Multi-writer coordination & branching (governs cross-repo PR flow)
- ADR-0006 (this repo) — OrbStack default container runtime (callers run in containers per this standard)
- ADR-0007 (this repo) — Pull-based GitOps sync (deployment model for both server and callers)
- ADR-0008 (this repo) — Structlog as Python logging standard (mandatory for trace propagation in this contract)
- ADR-0009 (this repo) — Ruff-S as static security standard (CI gate for caller and server code)
- ADR-0010 (jarvis-financial) — Path A — Day-Trading Agent Architecture *(first consumer of this contract)*

---

## 1. Context

### 1.1 What this ADR is

`jarvis-financial` Path A (per ADR-0010 in that repo) introduces the **first cross-repo runtime dependency** in the JARVIS ecosystem: the agent will call `jarvis-alpha`'s approval gateway over Tailscale HTTPS at runtime to authorize trades.

This pattern — one module repo making runtime calls to a service in another repo — will recur. `jarvis-family`, `jarvis-council`, future modules, and any other module needing cross-cutting concerns (approval, identity, costs, secrets, audit) will face the same shape.

This ADR defines the **standard contract** for such bridges: authentication, payload structure, lifecycle, failure modes, versioning, and operational expectations. ADR-0010 (jarvis-financial Path A) is the first concrete instantiation; future modules adopt this pattern by default.

### 1.2 Why a standards-repo ADR

Until now, `jarvis-financial` and other modules have been clients of `jarvis-alpha` only at deploy/coordination time (registering in `node_registry`, reporting `/api/costs/report`). These are batch / advisory integrations.

A **runtime** dependency is fundamentally different:
- A failed call blocks user-facing functionality
- Latency directly affects user experience or trading outcomes
- Security boundary becomes a hot path
- Schema evolution must preserve backward compatibility
- Operational coupling becomes real (alpha downtime → financial degraded)

These properties demand a deliberate, documented contract. Without it, every new module reinvents the pattern with subtle variations and the JARVIS ecosystem fractures.

### 1.3 Scope

| In scope | Out of scope |
|---|---|
| Wire protocol (endpoints, payloads, status codes) | Per-module business logic |
| Authentication and service identity | UI-facing API contracts |
| Versioning policy | Internal-only RPC between services on the same node |
| Failure modes and degradation patterns | Cross-cloud / external-vendor integrations |
| Operational expectations (SLOs, observability) | Specific approval policies (those live in module ADRs) |
| Caller responsibilities | Server (alpha) implementation details |

---

## 2. Decision Drivers

| Driver | Implication |
|---|---|
| Pattern repeats across modules | Define once, reuse everywhere |
| Modules must function during partial outages | Fail-closed defaults; bounded blast radius |
| Schema evolution is inevitable | Versioned contract; backward compatibility rules |
| Audit trail is institutional-grade requirement | All cross-repo calls traced + logged (per ADR-0008) |
| Service identity is non-negotiable | Per-caller cryptographic auth (RS256) |
| Different domains have different payload shapes | Generic envelope; domain-specific payload |
| Single approver-of-record across JARVIS | Alpha is server; modules are clients |
| Solo dev | Operational simplicity; minimize moving parts |

---

## 3. Decision Summary

### 3.1 Roles

- **Server:** `jarvis-alpha` (the central runtime hosting cross-cutting services, e.g., approval gateway, identity, future shared services)
- **Caller (client):** any module repo (`jarvis-financial`, `jarvis-family`, `jarvis-council`, future)
- **Transport:** HTTPS over Tailscale mesh; Tailscale magic DNS for hostnames
- **Auth:** RS256 service-identity JWT per caller
- **Envelope:** versioned generic envelope with domain-specific JSONB payload
- **Lifecycle:** signed short-lived intent; caller must use intent token at execution within expiry window
- **Failure default:** fail-closed at caller; no operation proceeds if bridge unhealthy
- **Versioning:** semver on contract; alpha must support last 2 minor versions
- **Logging:** structured per ADR-0008 (structlog) on both ends; trace_id propagated end-to-end

### 3.2 What the contract guarantees

| Guarantee | Mechanism |
|---|---|
| Caller is who it claims to be | RS256 keypair, public key registered with alpha |
| Request reached a specific approver | Server returns `approval_id` per request |
| Approval was for the exact submitted payload | `intent_token` is signed over the payload hash |
| Stale approvals cannot be replayed at execution | `intent_expires_at` short window; alpha tracks consumed tokens |
| Network partition does not produce ghost approvals | Idempotent submit (caller_idempotency_key required) |
| Audit trail is complete | All requests + outcomes logged on both sides; trace_id propagated |

### 3.3 What the contract does not guarantee

- That a request will be approved (that's policy, not contract)
- That alpha will be reachable at any given moment (caller must handle bridge unhealthy)
- That latency is bounded better than SLO targets (best-effort, not real-time)
- That payload semantics across versions are unchanged (each domain owns its payload schema)

---

## 4. Wire Protocol

### 4.1 Base URL

```
https://jarvis-brain.tail40ed36.ts.net:8186/v1/bridge
```

(Path is namespaced under `/v1/bridge` to distinguish cross-repo bridge endpoints from alpha's internal `/v1/...` routes used by alpha-internal services and the Endpoint UI.)

### 4.2 Endpoints

#### 4.2.1 POST `/v1/bridge/approvals/submit`

Submit an intent for approval. Idempotent on `caller_idempotency_key`.

**Request:**
```json
{
  "envelope_version": "1.0.0",
  "domain": "jarvis-financial",
  "domain_version": "1.0.0",
  "intent_kind": "trade_proposal",
  "tier_requested": "T2",
  "expires_at_window_seconds": 60,
  "caller_idempotency_key": "<uuid v4>",
  "trace_id": "<uuid v4>",
  "service_caller": "jarvis-fin-agent",
  "submitted_at": "2026-05-09T14:30:00Z",
  "payload": {
    "<domain-specific>": "..."
  }
}
```

**Response (200 OK):**
```json
{
  "approval_id": "<uuid v4>",
  "status": "pending | auto_approved | approved | rejected | expired",
  "tier_assigned": "T2",
  "intent_token": "<signed JWT-like string, present iff status in [auto_approved, approved]>",
  "intent_expires_at": "2026-05-09T14:31:00Z",
  "decided_at": "2026-05-09T14:30:00Z | null",
  "decided_by": "auto_t1 | human:ken | policy_engine | null",
  "rejection_reason": "<string | null>"
}
```

**Status codes:**
| Code | Meaning |
|---|---|
| 200 | Submitted; payload validated; outcome included in body |
| 400 | Envelope or payload schema invalid |
| 401 | Service-identity JWT missing or invalid |
| 403 | Caller not authorized for this domain or intent_kind |
| 409 | `caller_idempotency_key` already used (returns prior outcome in body) |
| 422 | Tier requested but policy says higher tier required (returns required tier) |
| 503 | Alpha gateway temporarily unavailable; caller must retry with backoff |

**Idempotency:** repeat submission with same `caller_idempotency_key` returns the prior response body and 200 (or 409 if the body has been re-issued in idempotency mode). Callers MUST persist the `caller_idempotency_key` before submitting and MUST use the same key on retry.

#### 4.2.2 GET `/v1/bridge/approvals/{approval_id}`

Poll for outcome on a pending approval. Used when the initial submit returned `status=pending`.

**Response (200 OK):**
```json
{
  "approval_id": "...",
  "status": "pending | approved | rejected | expired",
  "tier_assigned": "...",
  "intent_token": "<present iff status=approved>",
  "intent_expires_at": "...",
  "decided_at": "...",
  "decided_by": "...",
  "rejection_reason": "<string | null>"
}
```

**Polling cadence:** caller-controlled. Recommended: 1s, 2s, 4s, 8s exponential up to 30s ceiling. Alpha SHOULD provide a notification channel in v1.1 (server-sent events or Postgres NOTIFY relay) to remove polling.

#### 4.2.3 POST `/v1/bridge/approvals/{approval_id}/cancel`

Cancel a pending or approved-but-not-yet-consumed approval. Used when conditions change between submit and execution and the caller needs to abort.

**Response (200 OK):**
```json
{
  "approval_id": "...",
  "status": "cancelled",
  "cancelled_at": "..."
}
```

**Constraint:** can only cancel approvals where `status IN ('pending','approved')`. Already-consumed (executed) approvals return 409.

#### 4.2.4 POST `/v1/bridge/approvals/{approval_id}/consume`

Marks the approval as consumed (intent token used at execution). Required to prevent replay. Caller invokes this as part of the execution path immediately before broker submission.

**Request:**
```json
{
  "intent_token": "...",
  "consumer_trace_id": "<uuid>",
  "execution_attempt_id": "<uuid>"
}
```

**Response (200 OK):**
```json
{
  "approval_id": "...",
  "status": "consumed",
  "consumed_at": "..."
}
```

**Errors:**
| Code | Meaning |
|---|---|
| 409 | Already consumed; double-spend attempt |
| 410 | Intent expired |
| 401 | Intent token signature invalid |

#### 4.2.5 GET `/v1/bridge/health`

Caller heartbeat probe. Returns alpha's current bridge health.

**Response (200 OK):**
```json
{
  "status": "healthy | degraded | halted",
  "kill_switch_state": "open | conservative | halted",
  "kill_switch_updated_at": "...",
  "version_supported_min": "1.0.0",
  "version_supported_max": "1.0.0",
  "ts": "..."
}
```

Callers SHOULD probe this every 30-60s and cache the result (especially `kill_switch_state`). It is the data feeding caller-side fail-closed logic.

### 4.3 Authentication

**Mechanism:** RS256 service-identity JWT in `Authorization: Bearer <token>` header.

**Per-caller keys:**
- Each caller (e.g., `jarvis-fin-agent`, `jarvis-fin-execution`) has its own RS256 keypair
- Private key on the caller node (e.g., Sandbox) at `~/jarvis/pki/services/<service-name>_private.pem`
- Public key registered in `jarvis-alpha/brain/pki/services/` and trusted by alpha

**JWT claims:**
```json
{
  "iss": "jarvis-fin-agent",
  "sub": "jarvis-fin-agent",
  "aud": "jarvis-alpha-bridge",
  "exp": <epoch + 5min>,
  "iat": <epoch>,
  "jti": "<unique per token>",
  "domain": "jarvis-financial",
  "domain_version": "1.0.0"
}
```

**Token lifetime:** 5 minutes. Callers regenerate per request or cache briefly (no longer than the lifetime).

**Authorization:** alpha maintains a mapping `service_identity → allowed_domains_and_intent_kinds`. Out-of-scope calls return 403.

### 4.4 Intent token

When alpha approves an intent (auto or via human), it returns an `intent_token`. This token is the proof-of-approval that the caller's execution path presents at consume time.

**Form:** signed (RS256) compact JWT-like string with claims:
```json
{
  "approval_id": "...",
  "domain": "...",
  "intent_kind": "...",
  "payload_hash": "<sha256 of payload>",
  "tier_assigned": "...",
  "issued_at": "...",
  "expires_at": "<window from §4.2.1 request>",
  "issuer": "jarvis-alpha-bridge"
}
```

**Verification:** the caller's execution path verifies signature, expiry, and `payload_hash` matches the intended trade BEFORE submitting to broker. If hash mismatch, abort and write a security event.

This closes the "approval was for X, but caller submitted X-prime" attack vector.

### 4.5 Versioning

**Policy:** semver on `envelope_version` and on `domain_version` independently.

**Compatibility rules:**
- Alpha MUST support the **last 2 minor versions** of the envelope (e.g., 1.0.x, 1.1.x simultaneously)
- Alpha MAY drop support for older versions on **major version increment only**, with 90-day deprecation notice in `/v1/bridge/health`
- Domain payload schemas evolve independently — each domain owns its payload schema versioning, but MUST follow the same compatibility rule (alpha keeps last 2 minor versions of each `domain_version`)

**Breaking changes** to the envelope require a major version bump and a coordinated deploy: alpha ships v2-supporting code first, callers upgrade once alpha is on v2, then alpha may drop v1 support.

---

## 5. Caller Responsibilities

Every caller MUST:

### 5.1 Identity & secrets
- Maintain its own RS256 keypair; rotate per `~/jarvis/secrets.d/` rotation policy (see ADR-0003 jarvis-standards)
- Never share keys across services within a module
- Never commit private keys to repo

### 5.2 Idempotency
- Generate `caller_idempotency_key` (UUIDv4) BEFORE submission
- Persist the key with its associated business object (e.g., `agent_proposals.bridge_idempotency_key`)
- Replay the same key on retry until the business object reaches a terminal state (approved/rejected/expired/cancelled)

### 5.3 Failure handling
- Fail-closed by default: if bridge unhealthy or unreachable, halt operations that require approval
- Cache `/v1/bridge/health` response with explicit freshness (≤5min); use cached `kill_switch_state` for local pre-flight checks
- On 503 from any endpoint: exponential backoff with jitter; alert at >5 consecutive failures
- On 401/403: alert immediately (likely identity / authz misconfiguration, not transient)
- On 409 idempotency conflict: treat as success; the prior outcome is canonical

### 5.4 Observability
- Generate and propagate `trace_id` end-to-end through the bridge call
- Log every bridge call (submit, poll, consume, cancel) with structured fields per ADR-0008 (structlog): `trace_id`, `approval_id`, `status`, `latency_ms`, `caller_service`
- Emit Prometheus metrics:
  - `bridge_request_total{endpoint, status_code}`
  - `bridge_request_duration_seconds{endpoint}` histogram
  - `bridge_health_status{state}` gauge
  - `bridge_approvals_pending{tier}` gauge

### 5.5 Audit
- Record approval outcome on the caller's business object (e.g., `agent_proposals.approval_id`, `agent_proposals.intent_expires_at`, `agent_proposals.approval_decided_by`)
- Record consumption event before broker submission
- Verify intent_token signature and payload_hash before consuming

### 5.6 Schema discipline
- Payload schemas owned by the calling domain
- Schema changes documented in domain ADR + payload version bump
- Tests against the bridge use a contract test suite (see §7)

### 5.7 Static security
- Caller code passes ruff-S CI gate per ADR-0009 (jarvis-standards)
- Boundary discipline (e.g., agent has no broker SDK; execution has no LLM SDK) verified by import-graph rules

---

## 6. Server (Alpha) Responsibilities

`jarvis-alpha` MUST:

### 6.1 Endpoints
- Implement the endpoints in §4.2 with the response shapes specified
- Validate envelope and dispatch payload to domain-specific policy handlers
- Sign intent tokens with alpha's bridge signing key (separate from JWT auth keys)

### 6.2 Persistence
- Store every submission in `alpha_bridge_approvals` (or equivalent) with full payload, outcome, timestamps, caller_idempotency_key
- Enforce uniqueness on `(service_caller, caller_idempotency_key)` to make submit idempotent
- Append-only after initial creation; status transitions tracked in a separate table

### 6.3 Versioning
- Support last 2 minor versions of the envelope simultaneously
- Reject unknown envelope versions with 400 + `version_supported_min`/`version_supported_max` in error body
- Emit deprecation header (`Sunset: <date>`) when a caller is on a soon-to-be-dropped version

### 6.4 Security
- Validate JWT signature against registered public key for `iss`
- Reject expired or future-dated `iat`/`exp`
- Authorize on `(service_identity, domain, intent_kind)` tuple
- Rate-limit per `service_identity` to bound single-caller blast radius

### 6.5 Observability
- Log every request with trace_id, caller, domain, decision (per ADR-0008)
- Emit metrics symmetric to caller's (`bridge_server_request_*`)
- Provide a query endpoint or DB view for audit reconstruction

### 6.6 Operational
- `/v1/bridge/health` MUST reflect actual approval queue health, not just process up
- Kill switch state in `/v1/bridge/health` MUST be ≤5s stale
- Alpha downtime windows announced via `Sunset` header where possible

---

## 7. Testing Requirements

### 7.1 Contract tests (per caller)

Each caller repo SHIPS a contract test suite that exercises:
- Submit happy path → approved → consume
- Submit happy path → pending → poll → approved → consume
- Submit → rejected
- Submit → expired (waits past window)
- Idempotent retry: same key returns same outcome
- Cancel pending
- Consume already-consumed → 409
- Stale intent_token → 410
- Payload_hash mismatch on consume → security event
- Bridge 503 handling → backoff + alert
- Bridge 401/403 → immediate alert

### 7.2 Chaos drills (operational)

Quarterly:
- Block alpha→caller network for 5 minutes; verify caller fail-closes correctly
- Stop alpha bridge service; verify `/v1/bridge/health` reflects degraded
- Submit with intentionally invalid signature; verify 401 + alert
- Submit duplicate idempotency key concurrently; verify only one outcome materializes

Drills documented in `jarvis-standards/docs/runbooks/bridge-chaos-drill.md` (forthcoming).

---

## 8. Failure Modes and Mitigations

| Failure | Symptom | Caller behavior | Mitigation |
|---|---|---|---|
| Alpha process down | All endpoints return connection error | Fail-closed; halt approvals; alert | Restart alpha; cached kill switch state preserves recent context |
| Alpha network partition | Connection timeout | Same as above | Tailscale healing; cached state |
| JWT signing key compromised on caller | Forged requests possible | N/A from caller side | Key rotation procedure; alpha revokes public key |
| Payload schema drift mid-deploy | 400 errors on submit | Halt; alert | Versioning + last-2-minor-versions support |
| Intent token leaked | Replay possible | Token is single-use + expiring | `consumed` state; expiry window |
| Race: caller retries while server still processing | Duplicate idempotency key | Server returns same outcome | Idempotency key uniqueness constraint |
| Caller crashes after submit, before persisting approval_id | Lost association | Caller queries with idempotency key on restart | Store idempotency key BEFORE submit |
| Time skew between caller and alpha | JWT exp validation fails | Alert; sync NTP | NTP monitoring on all nodes |

---

## 9. Consequences

### 9.1 Positive

- One contract; future modules adopt without redesign
- Single approver-of-record (alpha) across JARVIS — clean audit
- Explicit failure semantics; no ambiguity in degradation
- Service-identity auth means each caller is independently revocable
- Versioning policy supports zero-downtime evolution
- Idempotency closes the retry-induces-double-trade attack

### 9.2 Negative

- Alpha becomes a load-bearing service for all modules — alpha downtime is now multi-module downtime
- Adds latency (5-50ms cross-Tailscale) to approval path
- Each new caller requires keypair setup + alpha-side key registration
- Schema versioning policy is real ongoing discipline

### 9.3 Accepted risks

| Risk | Why accepted |
|---|---|
| Alpha SPOF for cross-repo runtime | Single approver-of-record is strictly better than divergent systems; mitigated by fail-closed |
| Network latency on hot path | Approval is not bar-tick-frequency in any current consumer; budget is acceptable |
| Operational coupling | Cost is small relative to audit-trail and security gain |
| Per-caller key management overhead | Maps to existing `~/jarvis/secrets.d/` pattern |

---

## 10. Alternatives Considered

### 10.1 Local approval per module

Each module hosts its own approval queue, RBAC, and UI.

**Rejected because:** sprawl; multiple UIs to monitor; multiple audit trails; replicated logic; future modules face same build cost; user experience fragments.

### 10.2 Shared library, not service

Modules import a Python package providing approval logic, hitting a shared DB.

**Rejected because:** library version skew across modules; tight coupling at deploy time; no service-identity boundary; harder to evolve.

### 10.3 Synchronous direct integration (no envelope)

Each consumer hits domain-specific alpha endpoints (e.g., `/v1/financial/trade-approval`).

**Rejected because:** alpha grows N domain-specific endpoints, duplicated infrastructure; no version policy; doesn't scale to next module.

### 10.4 Asynchronous queue (Postgres NOTIFY / NATS)

Caller writes to a queue; alpha consumes; alpha writes outcome back to a different queue.

**Rejected for V1 because:** more moving parts; harder to reason about at solo-dev scale. **Reconsider for V2** when number of in-flight approvals justifies it.

---

## 11. Migration & Rollout

### 11.1 Pre-flight (alpha-side work)

Before any caller can use this contract, alpha needs:

1. `alpha_bridge_approvals` schema created
2. `/v1/bridge/*` endpoints implemented per §4
3. Bridge signing keypair generated + integrated
4. Per-caller authorization mapping established
5. `/v1/bridge/health` wired to actual queue + kill-switch state
6. Contract test suite exercised against alpha sandbox

This is a non-trivial alpha-side PR. **Coordinate before any module starts integration.**

### 11.2 First adopter: jarvis-financial Path A

Per ADR-0010 (jarvis-financial), PR-A5 introduces the bridge call. Alpha-side pre-flight work above must complete first.

### 11.3 Future adopters

Each future caller:
1. Generate RS256 keypair
2. Register public key with alpha (manual step today; automate later)
3. Implement contract test suite (template in `jarvis-standards/templates/bridge-contract-tests/`)
4. Submit alpha-side authorization update PR
5. Integrate per §5

### 11.4 Versioning discipline

Envelope `1.0.0` ships with the first caller integration. Subsequent changes:
- Additive (new optional fields): bump to 1.1.0; both versions supported
- Breaking (renamed/removed fields): bump to 2.0.0; 90-day deprecation with `Sunset` header

---

## 12. Compliance & Verification

How we know the contract is upheld:

| Invariant | Verification |
|---|---|
| All cross-repo runtime calls use `/v1/bridge/*` | Audit alpha access logs for non-bridge cross-repo paths |
| Every caller has unique service identity | `alpha_service_identities` table; CI check against repo configs |
| Idempotency keys are persisted before submit | Caller-side test in contract suite |
| Intent tokens are verified before consume | Caller-side test for hash-mismatch case |
| `/v1/bridge/health` freshness ≤5s | Server-side metric + alert |
| Versioning policy followed | CI check on envelope_version monotonicity |
| Logs comply with ADR-0008 (structlog) | Both ends; CI gate via log-format checker |

---

## 13. Open Questions (defer; track in this ADR)

1. **Server-sent events or Postgres NOTIFY relay for push updates?** v1.1 candidate. Currently polling.
2. **Per-domain rate limits** vs. per-caller? Currently per-caller; per-domain may be needed at scale.
3. **Multi-region alpha** for HA? Out of scope; single-Sandbox-style topology assumed.
4. **Cross-repo trace propagation tooling** — OpenTelemetry headers should carry through. Verify in §7 contract tests once OTel is wired.
5. **Token revocation channel** — if a caller key is compromised, how is it revoked in real time? Manual today; consider automated revocation list.

---

## 14. References

### External
- RFC 7519 (JWT)
- RFC 8725 (JWT Best Current Practices)
- RFC 8628 (OAuth 2.0 Device Authorization Grant) — for inspiration on idempotency patterns
- HashiCorp Vault: service identity patterns
- Google's BeyondCorp: service-to-service auth principles

### Internal — jarvis-standards
- ADR-0002 — State native, compute containerized
- ADR-0003 — Progressive secrets management
- ADR-0005 — Multi-writer coordination & branching
- ADR-0006 — OrbStack default container runtime
- ADR-0007 — Pull-based GitOps sync
- ADR-0008 — Structlog as Python logging standard
- ADR-0009 — Ruff-S as static security standard

### Internal — jarvis-financial
- ADR-0010 (jarvis-financial) — first consumer of this contract

### Forthcoming
- `jarvis-standards/templates/bridge-contract-tests/`
- `jarvis-standards/docs/runbooks/bridge-chaos-drill.md`
- `jarvis-alpha/docs/BRIDGE_IMPLEMENTATION.md`

---

*Architecture decision record · jarvis-standards · ADR-0010 · 2026-05-09 · Proposed*
