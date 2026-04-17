# Two-Token Pattern

Authentication pattern for services that both **serve** inbound requests AND **call out** to other services.

## 30-Second Summary

| Service Role | Token Count | Why |
|---|---|---|
| Only serves users (e.g., web UI backend) | 1 token issued per user | One caller-identity boundary |
| Only calls out (e.g., Gateway egress proxy) | 1 service token | One caller-identity boundary |
| **Both serves AND calls out** (e.g., Brain) | **2 tokens** | **Two caller-identity boundaries** |

One token per caller-identity boundary. Mixing boundaries is the anti-pattern.

---

## Why

- **Blast radius** — if the inbound user token is compromised, attacker cannot make outbound service calls (no service scope on user token). If the outbound service token is compromised, attacker cannot impersonate a user.
- **Rotation cadence differs** — service tokens rotate on a fixed schedule (typically 90 days). User tokens rotate on re-auth + short expiry (typically 30 days). Forcing one token to honor both schedules means one side is always stale or one side is always over-rotated.
- **Audit clarity** — two tokens → two log streams → trivial to attribute any given outbound call to "service loop" vs "user initiated." With one token you lose that distinction.
- **Principle of least privilege** — user token holds user-facing scopes (`user.*`, `child.*`, `admin.*`). Service token holds service-internal scopes (`service.internal`, `cloud.call`, `health.read`). Neither carries the other's authority.

---

## The Pattern
              ┌─────────────────────────────────────┐
User request →  │                                     │ → Outbound service call
(User Token)     │        Service with both roles      │   (Service Token)
│        (e.g., Brain in JARVIS)      │
│                                     │
│   Inbound JWT = who the user is     │
│   Outbound JWT = who the service is │
└─────────────────────────────────────┘

Each token is **issued to** a different caller and **presented by** a different caller. The service holds both because it plays both roles.

---

## Concrete Example — JARVIS Alpha

| Node | Inbound Role | Outbound Role | Tokens Held |
|---|---|---|---|
| Brain | Serves users + agents (inbound) | Calls Gateway for cloud LLM (outbound) | **2** — `ALPHA_BRAIN_TOKEN` (user) + `ALPHA_BRAIN_SERVICE_TOKEN` (service) |
| Gateway | Serves Brain (inbound) | Calls cloud APIs (outbound-but-external) | **1** — `ALPHA_SERVICE_TOKEN` — external calls use API keys, not JWTs |
| Endpoint | Serves UI (inbound only) | None | **1** — shared with Brain via PIN auth |
| Sandbox (Forge) | Serves Air (inbound) | Calls Brain for LLM (outbound) | **2** (in theory; currently unified — tech debt) |

**Why Gateway only needs one:** Gateway's outbound calls go to **external** providers (Anthropic, Google, Perplexity) that use their own API-key auth, not JARVIS JWT. Internal JWT is only needed for inbound from Brain.

---

## Scope Assignment Rules

Scopes describe the **capability**, not the **holder**. Do NOT prefix scopes with the holder's name.

| ✅ Good | ❌ Bad |
|---|---|
| `cloud.call` | `gateway.cloud.call` |
| `health.read` | `brain.health.read` |
| `dream.plan` | `gateway.dream.plan` |

**Why capability-named:** multiple services may hold the same scope. Brain holds `cloud.call` in its service token. Gateway also holds `cloud.call` (it's the thing that fulfills cloud.call requests). If the scope were named `gateway.cloud.call`, Brain's service token would look wrong. Capability naming collapses the duplication.

**Precedent:** AWS IAM (`s3:GetObject`, not `ec2.s3.GetObject`), Google Cloud IAM (`storage.objects.get`), Stripe (`read_write` not `stripe.api.read_write`).

---

## Rotation Cadence

| Token Type | Rotation Interval | Trigger |
|---|---|---|
| Service token | 90 days (fixed) | Scheduled rotation script |
| User token | 30 days OR re-auth | PIN entry / login |
| Emergency | Immediate | Suspected compromise |

Rotation script must NOT share state between the two token types — rotating the service token should never invalidate user tokens, and vice versa.

---

## Audit Trail Benefits

With two tokens, every log line can be attributed to one of two flows:
iss=brain, sub=user_ken      → user-initiated request
iss=brain, sub=brain-service → brain-internal service loop

Correlating outbound cloud calls to the upstream user who triggered them becomes a join on trace-id, not a guess.

---

## Big-Tech Precedent

- **AWS** — EC2 instances commonly hold an instance-profile IAM role (outbound AWS API calls) AND a service account (application identity). Different callers, different credentials.
- **Google Cloud** — service accounts can both authenticate as the service AND impersonate users via domain-wide delegation; these are separate credentials with separate scopes.
- **Stripe** — publishable key (client-side, narrow scope) vs restricted key (server-side, capability-scoped). Two keys per application.
- **Kubernetes** — pods receive a service account token for outbound API-server calls, separate from any user tokens a web backend might handle.

---

## When NOT to Use This Pattern

- **Pure inbound service** (stateless web UI, static API) — one token is enough.
- **Pure outbound service** (cron job, batch ingester, egress proxy) — one token is enough.
- **Trust-boundary doesn't change between inbound and outbound** — if the same caller-identity drives both, collapse to one token. Adding a second just doubles the attack surface.

The pattern applies when and only when the caller-identity differs between inbound and outbound. If you can't articulate two different caller identities, you don't need two tokens.

---

## Cross-References

- **jarvis-alpha** — `docs/SERVICE_IDENTITY_MODEL.md` §7.7 documents the Brain two-token implementation.
- **LOGGING standard** — `docs/LOGGING.md` — service names in log output should match JWT `iss` claim for audit join.

---

*jarvis-standards · canonical reference*
