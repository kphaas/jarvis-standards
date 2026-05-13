# ADR-0011: Kill-Switch, Pre-Trade Gate, and Governance Layer

- **Status:** Accepted
- **Date:** 2026-05-12
- **Deciders:** Ken Phaas (architect)
- **Amends:** ADR-0010 §8 (failure mode now governed by this ADR)
- **Scope:** jarvis-financial (canonical owner) + jarvis-alpha (signal sender)
- **Supersedes:** ADR-0011 v2 (poll-based design with alpha as source-of-truth)
- **External validation:** Perplexity Pro multi-lens review 2026-05-12 (institutional risk, fintech platform, regulatory compliance, exchange SRE)
- **Related TDs:** TD-B' (PR-A5 implementation), TD-D, TD-E, TD-F (existing P1s), plus 11 new TDs filed alongside this ADR

---

## Document Structure

This ADR has three parts:

- **Part 1 — Kill-Switch Mechanics** (§1–§5): What halts trading and how
- **Part 2 — Pre-Trade Gate + Degraded Modes** (§6–§9): What lets orders through and what happens in partial failures
- **Part 3 — Governance Layer** (§10–§15): How we prove the controls work

Each Part is followed by **§MV-X — Minimum Viable Subset** marking what is mandatory for solo-operator scope vs aspirational for institutional scope.

---

## Context

### The discovered gap

On 2026-05-12, the `agent_kill_switch_cache` row in `jarvis_fin` was found 2 days 19 hours stale. State `open`, `expires_at` lapsed 22+ hours prior. Agent was making BUY proposals on a cache never touched since a smoke test.

Read-only investigation established:
1. **Reader was fail-open by design** — pinned by test, stale row returns "not engaged"
2. **No writer existed anywhere** — schema + reader in financial, contract "Proposed" in standards, no endpoint in alpha
3. **Source of truth (`alpha_system_flags`)** existed in jarvis-alpha but was unexposed

### Why this ADR exists

The current state is safe **only because** the agent operates in shadow mode (no money at risk). Any transition to paper or live without resolving this creates a trading system with a decorative kill-switch — institutionally indefensible per SEC Rule 15c3-5.

External validation (Perplexity Pro, 4-lens review) concluded: *"Your kill-switch is strong, but your pre-trade gate and governance layer are not yet strong enough to match the seriousness of the kill-switch."* This ADR closes all three gaps in a single design.

### Why a single ADR (vs separate documents)

The three concerns (kill-switch, pre-trade gate, governance) are interlocking: governance procedures reference kill-switch state transitions; pre-trade gate references operator override mechanism; halt behavior references pre-trade gate cancellation paths. A single ADR is the right level of granularity to keep these consistent.

---

# PART 1 — KILL-SWITCH MECHANICS

## §1. Ownership and Architecture

### D1.1 — Financial owns the kill-switch source of truth

**Decision:** `jarvis-financial` is the sole authoritative owner of the trading-system kill-switch state. `jarvis-alpha` is a *signal sender*, not a *source of truth*.

**Rationale (per SEC 15c3-5 "direct and exclusive control"):** The entity that can place orders to market must own the final gating logic. Cross-system dependency on alpha would mean an alpha bug could halt or un-halt trading without financial's consent — violating the "direct and exclusive control" requirement.

**Implication:** Financial operates correctly even if alpha is fully down. Alpha is a *convenience signal*, not a dependency.

### D1.2 — Three halt sources

Three independent halt-signal sources exist:

| Source | Origin | Trigger |
|---|---|---|
| `alpha_operator` | Webhook POST from jarvis-alpha | Operator pulls "halt everything" from JARVIS UI |
| `financial_operator` | Internal POST from financial admin UI | Operator pulls local kill button at `:5443/admin/halt` |
| `risk_monitor_*` | Internal services within financial | Risk detector (P&L, position, market, broker, etc.) — see §3 |

Each source writes to its own row in `halt_sources` table (one row per source). State is computed by SQL VIEW as the most-restrictive across all sources, filtered by active overrides.

### D1.3 — Most-restrictive-wins aggregation

**Restriction levels** (explicit, encoded):

| State | Level | Meaning |
|---|---|---|
| `halted` | 3 | No new orders; cancel resting orders within 30s |
| `conservative` | 2 | Reduce position sizes by 50%; no new positions in volatile instruments |
| `degraded` | 1 | Trading allowed but monitor flags risk elevated (audit-visible) |
| `open` | 0 | Normal operation |

A new `degraded` state is added (was not in v2). Per Perplexity exchange-SRE feedback, an explicit "DEGRADED" state in the state machine is easier to reason about under audit than implicit precedence.

**Aggregation rule:** `MAX(restriction_level) across active, non-overridden sources`.

### D1.4 — Operator override semantics

Operator override creates a row in `halt_overrides` table that *ignores* a specific halted source for a bounded time.

| Property | Value |
|---|---|
| Scope | Single `source_id` (no blanket overrides) |
| Required justification | Free-text reason ≥ 20 characters |
| TTL | Default 1 hour, **maximum 4 hours** (reduced from v2's 24h per Perplexity finding) |
| Re-extension | Requires new override row + new justification + audit log entry |
| Audit | `who, when, why, source_id, expires_at, revoked_at` |
| Underlying signal | NOT cleared — still recorded; only ignored for trading decisions |
| Re-engagement | When override expires, original halt source re-engages automatically if still active |

**Rationale (per Perplexity §1-Q2-MAJOR):** Institutional practice favors short-lived, mandatory re-approval overrides. A 24-hour override that masks a live safety issue is the failure mode this rule prevents.

### D1.5 — Mode-aware fail behavior with paper fail-safe

**Critical revision per Perplexity §1-Q2-MAJOR finding:**

| Mode | Reader error / cache stale | Source signal halted |
|---|---|---|
| `shadow` | Fail-OPEN | Honor halt |
| `paper` | **Fail-SAFE** (NOT fail-open) | Honor halt |
| `live` | Fail-CLOSED | Honor halt |

**"Fail-SAFE" in paper mode** means: same control path as live (halt the agent), but log as a control-path test rather than a real halt. This ensures paper mode exercises the same code paths as live, preventing the "false confidence" failure mode Perplexity flagged. Paper mode operator can clear the fail-safe with logged reason.

This is a deviation from v2 (which had paper = fail-open). Paper must train the same muscle memory as live.

---

## §2. Webhook Protocol (Alpha → Financial)

### D2.1 — Endpoints

Financial exposes two endpoints on its FastAPI service:

| Endpoint | Method | Purpose |
|---|---|---|
| `/v1/halt-signal` | POST | Alpha or operator POSTs halt/clear signal |
| `/v1/halt-signal-heartbeat` | POST | Alpha POSTs every 60s as liveness signal |

Both require RS256 service identity per ADR-0010 §3.

### D2.2 — Payload contract

Halt-signal payload:

```json
{
  "idempotency_key": "uuid-v4",
  "nonce": "32-byte-base64",
  "issued_at": "2026-05-12T18:30:00.000Z",
  "source_id": "alpha_operator | financial_operator | risk_monitor_pnl | ...",
  "state": "open | degraded | conservative | halted",
  "reason": "string >= 20 chars",
  "metadata": { "operator_id": "...", "trace_id": "..." }
}
```

### D2.3 — Replay protection and clock skew

- **Replay window:** Reject if `now() - issued_at > 5 minutes` OR `issued_at > now() + 5 minutes` (clock-skew tolerance ±5 min)
- **Nonce tracking:** Each nonce stored in `webhook_nonces` table for 10 minutes after acceptance; duplicate nonce rejected
- **Idempotency:** Duplicate `idempotency_key` returns HTTP 200 with prior result, no audit-log dupe

### D2.4 — Delivery semantics

Alpha-side retry policy on failed POST:

| Attempt | Backoff |
|---|---|
| 1 | Immediate |
| 2 | 5 seconds |
| 3 | 15 seconds |
| 4 | 45 seconds |
| 5 | 2 minutes |
| Final | 5 minutes |

After final failure (6 attempts total over ~8 minutes), alpha:
1. Writes to `webhook_delivery_failures` log on alpha side
2. Alerts operator via existing alpha alerting (Pushover / email)
3. Stops retrying that specific message
4. Continues sending new signals — does not block on one failure

### D2.5 — Separated heartbeat thresholds

Different heartbeat sources have different staleness tolerances:

| Heartbeat | Source | Threshold | Action when stale |
|---|---|---|---|
| `alpha_supervision_heartbeat` | Alpha → financial /v1/halt-signal-heartbeat | 5 min | Live: fail-closed. Paper/shadow: log only. |
| `broker_connection_heartbeat` | Financial → Alpaca API (existing) | 30 sec | Live: fail-closed immediately. Paper/shadow: log. |
| `market_data_heartbeat` | Financial bar fetcher (existing) | 2 min (configurable per symbol) | Live: fail-closed for affected symbols only. |
| `internal_db_heartbeat` | Financial → Postgres health check | 10 sec | Live: fail-closed immediately. |

Each heartbeat has its own column, alert, and runbook. **No single "5 min threshold" applies to everything.**

---

## §3. Risk Monitor Sources (Local to Financial)

### D3.1 — Independent detector services

Each risk monitor is a separate service writing to its own `halt_sources` row. **No detector is a strategy module.** Per SEC 15c3-5, pre-trade controls must be independent of strategy.

| Source ID | Service | Trigger |
|---|---|---|
| `risk_monitor_pnl` | P&L breach detector | Realized + unrealized loss exceeds daily limit |
| `risk_monitor_position` | Position size detector | Single position exceeds size limit OR concentration limit |
| `risk_monitor_market` | Market halt detector | Detects market-wide LULD halt / trading suspension |
| `risk_monitor_broker` | Broker connectivity detector | Alpaca API health degraded (latency / errors / disconnect) |
| `risk_monitor_data` | Data freshness detector | Bar feed stale beyond per-symbol threshold |
| `risk_monitor_velocity` | Order velocity detector (Knight-Capital control) | Outgoing orders exceed intended-order rate by configurable multiplier (default 10x) |

**Critical Perplexity-mandated addition:** `risk_monitor_velocity` is the **Knight Capital control**. Knight sent 4 million orders from 212 intended. A velocity detector that halts when actual/intended ratio breaches threshold would have stopped Knight in milliseconds.

### D3.2 — Detector implementation guarantees

Every detector must:
- Run as its own LaunchAgent (independent process)
- Write heartbeat to `halt_sources.last_heartbeat_at` every 30 seconds
- Be testable via fault injection (chaos harness — see §13)
- Have its own runbook for halted state (see §15)
- Be reviewable by the periodic control review (see §11)

---

## §4. Storage Schema

### D4.1 — Tables

```sql
-- One row per source — UPSERT on signal received
CREATE TABLE halt_sources (
    source_id           TEXT PRIMARY KEY,
    state               TEXT NOT NULL CHECK (state IN ('open','degraded','conservative','halted')),
    restriction_level   INTEGER NOT NULL CHECK (restriction_level BETWEEN 0 AND 3),
    reason              TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_heartbeat_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    heartbeat_interval_seconds INTEGER NOT NULL DEFAULT 30,
    heartbeat_stale_threshold_seconds INTEGER NOT NULL DEFAULT 90,
    metadata            JSONB
);

-- Operator overrides — append-only after creation
CREATE TABLE halt_overrides (
    override_id         BIGSERIAL PRIMARY KEY,
    source_id           TEXT NOT NULL REFERENCES halt_sources(source_id),
    operator_id         TEXT NOT NULL,
    reason              TEXT NOT NULL CHECK (length(reason) >= 20),
    issued_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    revoked_reason      TEXT,
    CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '4 hours')
);

-- DB-enforced append-only audit
CREATE TABLE halt_signal_log (
    id                  BIGSERIAL PRIMARY KEY,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_id           TEXT NOT NULL,
    prior_state         TEXT,
    new_state           TEXT NOT NULL,
    reason              TEXT,
    idempotency_key     UUID,
    payload             JSONB NOT NULL
);

-- DB-enforced append-only audit
CREATE TABLE halt_override_log (
    id                  BIGSERIAL PRIMARY KEY,
    logged_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    override_id         BIGINT,
    event_type          TEXT NOT NULL CHECK (event_type IN ('created','revoked','expired','extended')),
    operator_id         TEXT,
    reason              TEXT,
    metadata            JSONB
);

-- State transition log — every edge transition
CREATE TABLE halt_state_transitions (
    id                  BIGSERIAL PRIMARY KEY,
    observed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    prior_effective_state TEXT,
    new_effective_state TEXT NOT NULL,
    triggering_source   TEXT NOT NULL,
    triggering_reason   TEXT,
    halt_sources_snapshot JSONB NOT NULL,
    halt_overrides_snapshot JSONB NOT NULL,
    order_book_snapshot JSONB
);

-- Replay protection
CREATE TABLE webhook_nonces (
    nonce               TEXT PRIMARY KEY,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '10 minutes')
);
CREATE INDEX idx_webhook_nonces_expires ON webhook_nonces(expires_at);
```

### D4.2 — DB-enforced append-only

Per Perplexity §1-Q3 finding, application-layer append-only is insufficient. Database-level enforcement:

```sql
REVOKE UPDATE, DELETE ON halt_signal_log FROM jarvis_fin_app;
REVOKE UPDATE, DELETE ON halt_override_log FROM jarvis_fin_app;
REVOKE UPDATE, DELETE ON halt_state_transitions FROM jarvis_fin_app;
```

Superuser retains admin access (separate path), but the application role cannot rewrite history.

### D4.3 — Canonical state via SQL VIEW

```sql
CREATE VIEW v_effective_halt_state AS
WITH active_sources AS (
    SELECT s.source_id, s.state, s.restriction_level, s.reason, s.updated_at,
           (s.last_heartbeat_at + (s.heartbeat_stale_threshold_seconds || ' seconds')::interval > now()) AS is_alive
    FROM halt_sources s
    WHERE NOT EXISTS (
        SELECT 1 FROM halt_overrides o
        WHERE o.source_id = s.source_id
          AND o.expires_at > now()
          AND o.revoked_at IS NULL
    )
)
SELECT
    COALESCE(
        (SELECT state FROM active_sources WHERE is_alive ORDER BY restriction_level DESC LIMIT 1),
        'halted'
    ) AS effective_state,
    (SELECT restriction_level FROM active_sources WHERE is_alive ORDER BY restriction_level DESC LIMIT 1) AS effective_restriction_level,
    (SELECT array_agg(jsonb_build_object('source', source_id, 'state', state, 'reason', reason))
     FROM active_sources WHERE is_alive AND restriction_level > 0) AS contributing_sources,
    (SELECT array_agg(source_id) FROM active_sources WHERE NOT is_alive) AS stale_sources,
    now() AS computed_at;
```

**No cache.** View computes on every read. Eliminates "cache vs sources disagree" failure mode.

---

## §5. Reader Implementation (Agent Runtime)

### D5.1 — Mode-aware reader

```python
async def get_effective_halt_state(pool, agent_mode: AgentMode) -> HaltState:
    try:
        row = await pool.fetchrow("SELECT * FROM v_effective_halt_state")
        return HaltState(row)
    except Exception as e:
        if agent_mode == AgentMode.LIVE:
            log.error("kill_switch_read_failed_live", error=str(e))
            return HaltState.fail_closed(reason=f"reader_error: {e}")
        elif agent_mode == AgentMode.PAPER:
            log.warning("kill_switch_read_failed_paper", error=str(e))
            return HaltState.fail_safe(reason=f"reader_error: {e}")
        else:
            log.info("kill_switch_read_failed_shadow", error=str(e))
            return HaltState.fail_open(reason=f"reader_error: {e}")
```

### D5.2 — Halt behavior on engaged kill-switch

**When `effective_state ∈ {halted}`:**

1. **Stop placing new orders immediately** (within the next decision tick)
2. **Cancel resting orders** with explicit ACK monitoring (see §8):
   - Issue cancel for each open order
   - Wait for broker ACK with 30s timeout per order
   - If ACK not received: escalate to operator alert + retry once
   - If still no ACK: log as "cancel ambiguous" — operator must intervene manually
3. **Do NOT auto-flatten existing positions by default** (operator decides)
4. **`risk_emergency_flatten` flag exists but defaults OFF**:
   - When enabled (via separate operator override), flatten is permitted on halt
   - Default: disabled
   - Reasoning: incorrect auto-flatten during transient bridge blip could realize losses worse than original risk

**When `effective_state ∈ {conservative, degraded}`:**

- `conservative`: reduce position sizes by 50%; no new positions in symbols flagged by detectors
- `degraded`: continue trading; raise audit-visible flag; log every decision with `degraded_mode=true`

---

## §MV-1 — Minimum Viable Subset (Solo-Operator Today)

The full ADR-0011 v3 design is the institutional target. The **minimum viable subset** for solo-operator scope today (sufficient to be regulator/insurer/investor defensible per Perplexity §6):

| Component | MV-1 status |
|---|---|
| 3 halt sources (alpha_operator, financial_operator, ONE risk monitor) | REQUIRED. Risk monitor minimum: `risk_monitor_velocity` (Knight Capital control) |
| `halt_sources` table + `v_effective_halt_state` view | REQUIRED |
| `halt_signal_log` + DB-enforced append-only | REQUIRED |
| `halt_overrides` + 4h max TTL | REQUIRED |
| Webhook with RS256 + idempotency + nonce + skew tolerance | REQUIRED |
| Mode-aware reader (shadow fail-open, paper fail-safe, live fail-closed) | REQUIRED |
| Separated heartbeats (alpha, broker, market data, DB) | REQUIRED |
| Halt behavior: stop new + cancel-with-ACK | REQUIRED. Auto-flatten can default OFF (MV-acceptable). |
| Full risk monitor suite (pnl, position, market, broker, data) | DEFERRED — each detector its own follow-up PR |
| State transition log (`halt_state_transitions`) | REQUIRED (governance evidence) |

**MV-1 is what PR-A5-financial-1 implements.** Full detector suite is PR-A5-financial-2 + later.

---

# PART 2 — PRE-TRADE GATE AND DEGRADED MODES

## §6. Pre-Trade Order Validation Gate

### D6.1 — Why an independent gate

Per Perplexity §1-Q3 (BLOCKING for live) and SEC Rule 15c3-5:

> "Pre-trade controls must prevent erroneous orders and limit exposure before orders reach the market."

The kill-switch stops trading at a system-state level. The **pre-trade gate** validates each individual order before submission, even when the system is healthy. Knight Capital sent 4 million orders from 212 intended because their strategy logic produced bad orders and **no independent gate caught them**.

**Critical principle:** The gate is **separate from strategy logic and cannot be bypassed by strategy logic**. A strategy bug producing million-share orders must be blocked by the gate regardless of how the strategy thinks the order is correct.

### D6.2 — Gate placement in the order lifecycle

```
Strategy decision
↓
Generate order payload
↓
Kill-switch check (§5) — if halted: reject, log, exit
↓
PRE-TRADE GATE (§6) — independent of strategy, hard-block on any failure, logged with full payload
↓
Submit to broker (Alpaca)
↓
Broker ACK monitoring (§8)
```

The gate runs **AFTER** the kill-switch check (kill-switch is a faster filter). Kill-switch handles system state; gate handles order-level correctness.

### D6.3 — Mandatory gate checks

Every order, regardless of source, must pass ALL of the following before submission:

| # | Check | Failure action | Configurable? |
|---|---|---|---|
| 1 | **Symbol allowlist** | Reject — symbol not in `pretrade_symbol_allowlist` table | Yes — operator manages list |
| 2 | **Size limit (absolute)** | Reject — quantity > `max_order_quantity` (per symbol) | Yes — per-symbol override allowed |
| 3 | **Size limit (notional)** | Reject — quantity × last_price > `max_order_notional_usd` | Yes |
| 4 | **Price sanity** | Reject — limit_price outside ±N% of last_price (default ±10%) | Yes |
| 5 | **Stale data check** | Reject — bar data older than `max_data_staleness_seconds` (per symbol) | Yes |
| 6 | **Session state** | Reject — order outside permitted session (extended hours flag) | Yes |
| 7 | **Duplicate order detection** | Reject — identical order (symbol+side+qty+price) within last 60s | No (hardcoded) |
| 8 | **Order velocity (Knight control)** | Reject — order count in last 60s exceeds `max_orders_per_minute` | Yes — high default |
| 9 | **Daily order count** | Reject — total orders today exceeds `max_daily_orders` | Yes |
| 10 | **Position concentration** | Reject if order would push single-position concentration above `max_concentration_pct` | Yes |
| 11 | **Account buying power** | Reject if order would exceed available buying power × safety margin | No (hardcoded margin) |
| 12 | **Open order coherence** | Reject if open orders (resting + new) would exceed `max_open_orders_per_symbol` | Yes |

**ALL checks must pass.** Hard-fail on any single check. Failure is logged with full payload, gate decision, and failed check ID.

### D6.4 — Gate implementation requirements

- **Service:** Independent Python module `pretrade_gate.py` — NOT inside strategy module
- **Stateless where possible:** Each check is a pure function of (order, market state, account state, limits config)
- **Limits stored in DB:** `pretrade_limits` table with per-symbol overrides
- **Limits change requires audit:** Any update to `pretrade_limits` logged to `pretrade_limits_log` (append-only, DB-enforced)
- **Latency budget:** <50ms total for all 12 checks (synchronous in the order path)
- **Cannot be bypassed by strategy:** No "skip gate" parameter. Even backtests run with gate enabled (different limits config, but same code path).

### D6.5 — Storage schema (pre-trade gate)

```sql
CREATE TABLE pretrade_limits (
    id                          BIGSERIAL PRIMARY KEY,
    symbol                      TEXT,
    max_order_quantity          INTEGER NOT NULL,
    max_order_notional_usd      NUMERIC(20,2) NOT NULL,
    price_sanity_pct            NUMERIC(5,2) NOT NULL DEFAULT 10.00,
    max_data_staleness_seconds  INTEGER NOT NULL DEFAULT 60,
    max_orders_per_minute       INTEGER NOT NULL,
    max_daily_orders            INTEGER NOT NULL,
    max_concentration_pct       NUMERIC(5,2) NOT NULL,
    max_open_orders_per_symbol  INTEGER NOT NULL,
    extended_hours_allowed      BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                  TEXT NOT NULL,
    UNIQUE(symbol)
);

CREATE TABLE pretrade_limits_log (
    id              BIGSERIAL PRIMARY KEY,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    symbol          TEXT,
    prior_values    JSONB,
    new_values      JSONB NOT NULL,
    changed_by      TEXT NOT NULL,
    reason          TEXT NOT NULL CHECK (length(reason) >= 20)
);

CREATE TABLE pretrade_decisions (
    id                  BIGSERIAL PRIMARY KEY,
    decided_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    order_payload       JSONB NOT NULL,
    decision            TEXT NOT NULL CHECK (decision IN ('pass','fail')),
    failed_check_id     INTEGER,
    failed_check_name   TEXT,
    check_details       JSONB,
    market_snapshot     JSONB,
    account_snapshot    JSONB,
    latency_ms          INTEGER
);

REVOKE UPDATE, DELETE ON pretrade_limits_log FROM jarvis_fin_app;
REVOKE UPDATE, DELETE ON pretrade_decisions FROM jarvis_fin_app;
```

### D6.6 — Symbol allowlist

The most powerful pre-trade control is the allowlist. Strategy bugs that produce orders for unknown symbols (e.g., typo, hallucination, off-by-one in symbol mapping) are caught by allowlist check before any other validation runs.

| Operating phase | Allowlist size |
|---|---|
| Initial paper testing | 5-10 symbols (operator-curated) |
| Expanded paper | Up to ~50 symbols |
| Live (initial) | Operator-set explicit list, NOT "all S&P 500" |
| Live (scaled) | Per-strategy allowlists with operator approval |

**No "allow all symbols" mode exists.** Even backtests use an explicit allowlist (typically larger).

---

## §7. Degraded-Mode Matrix

Per Perplexity §1-Q3 (MAJOR — Knight lesson), Knight's failure was driven by treating "component still running" as "component working correctly." For each failure type, define the **safe-state behavior** — not just whether to halt, but what halt looks like.

### D7.1 — Matrix

| Failure Type | Detection | Effective state | Order behavior | Cancel behavior | Operator alert |
|---|---|---|---|---|---|
| **Market data feed lost (one symbol)** | `risk_monitor_data` heartbeat stale | `halted` for that symbol; `open` for others | Reject new orders for affected symbol | Cancel resting orders in affected symbol | YES (page) |
| **Market data feed lost (all symbols)** | All `risk_monitor_data` stale | `halted` system-wide | Reject all new orders | Cancel all resting orders | YES (page) |
| **Broker connection degraded** | `risk_monitor_broker`: error rate / latency above threshold | `degraded` initially; escalate to `halted` if persists 60s | Slow order pace; require explicit broker ACK before next order | Issue cancels with extended timeout; escalate if no ACK | YES (page on `halted`) |
| **Broker connection lost** | `risk_monitor_broker`: connection failure | `halted` immediately | Reject all new orders | Cannot cancel — log positions as "broker-side ambiguous"; alert operator for manual reconciliation | YES (page) |
| **Broker ACK ambiguous (cancel timeout)** | Cancel issued, no ACK within 30s; retry, still no ACK | `degraded` (specific symbol) | Reject new orders for affected symbol | Log as "cancel-ambiguous"; require operator confirmation to resume | YES (page) |
| **Postgres read failure** | DB query error | `halted` system-wide (live); `degraded` (paper) | Reject all new orders | Cancel attempts logged; broker reconciliation required if DB stays down | YES (page) |
| **Postgres write failure (audit log)** | Cannot write to `halt_signal_log`, `pretrade_decisions`, etc. | `halted` system-wide | Reject all new orders | Cancel attempts logged to in-memory ring buffer; replayed when DB restored | YES (page critical) |
| **Clock skew (financial ↔ Postgres)** | Financial host clock differs from Postgres `now()` by >5s | `halted` system-wide (live) | Reject all new orders | N/A (cannot reliably timestamp anything) | YES (page) |
| **Clock skew (financial ↔ alpha)** | Webhook timestamp validation fails repeatedly | Alpha-source halt signals rejected; **local halt sources still honored** | Continue trading on local sources | Continue per local source state | YES (page; degraded confidence) |
| **Bridge poller dead (alpha)** | `alpha_supervision_heartbeat` stale > 5 min | Live: `halted` (cannot hear alpha). Paper: `degraded`. Shadow: log only. | Live: reject new orders | Live: cancel resting orders | YES (page on live) |
| **Risk monitor crashed** | Detector LaunchAgent not running OR heartbeat stale | `halted` system-wide (live; cannot validate risk) | Reject all new orders | Cancel resting orders | YES (page) |
| **Strategy module exception** | Caller error caught in strategy code | Order generation aborts for that tick; system stays `open` | No order produced this tick | N/A | NO (log only); pages if exception rate > threshold |
| **Pretrade gate exception** | Gate code itself throws | Live: `halted` (cannot validate orders safely). Paper: `degraded`. | Reject the failing order; pause new orders until gate verified healthy | Cancel any pending order being validated | YES (page on live) |

### D7.2 — Per-symbol vs system-wide halt scope

**Critical design choice:** failures are scoped to the narrowest reasonable level.

- Symbol-specific failure (data feed for AAPL stale) → halt AAPL only
- Account-level failure (broker disconnect) → halt all symbols
- System-level failure (DB error, clock skew) → halt everything

This avoids the failure mode where one stale feed halts the entire system unnecessarily.

### D7.3 — Storage schema (degraded mode tracking)

The degraded-mode matrix is enforced by `risk_monitor_*` services writing to `halt_sources` with appropriate state. Per-symbol scope is stored in `metadata` JSONB:

```sql
UPDATE halt_sources SET
    state = 'halted',
    restriction_level = 3,
    reason = 'market_data_stale',
    metadata = jsonb_build_object('scope', 'symbol', 'symbols', '["AAPL"]')
WHERE source_id = 'risk_monitor_data_aapl';
```

The pre-trade gate (§6) reads `halt_sources` and applies per-symbol filters in addition to system-wide kill-switch state.

---

## §8. Cancel-ACK Monitoring

### D8.1 — Why ACK monitoring matters

"Cancel order" is a request, not a guarantee. The broker may:
- ACK the cancel and successfully cancel (happy path)
- ACK the cancel but fail to actually cancel (rare but real)
- NACK the cancel (order already filled, etc.)
- Not respond at all (network blip, broker overload)

A halt that thinks it cancelled all orders but didn't is **the most dangerous failure mode after a runaway algo**.

### D8.2 — Protocol

For each cancel issued during a halt:

```
Issue cancel_order(order_id)
↓
Record in cancel_attempts table (cancel_initiated_at = now())
↓
Wait for broker ACK (timeout: 30 seconds)
↓
ACK received?
├── YES, cancelled: Update cancel_attempts.status = 'cancelled'
├── YES, not cancellable (filled): Update cancel_attempts.status = 'order_filled_before_cancel'
├── NO ACK after 30s:
│      └── Retry cancel ONCE (no longer wait — second attempt async)
│             └── Still no ACK after 60s total:
│                    ├── Update cancel_attempts.status = 'ambiguous'
│                    ├── Page operator IMMEDIATELY
│                    └── Set system state to 'cancel_ambiguous' (degraded sub-state)
└── BROKER ERROR: Update cancel_attempts.status = 'error', operator alert
```

### D8.3 — Storage schema

```sql
CREATE TABLE cancel_attempts (
    id                      BIGSERIAL PRIMARY KEY,
    order_id                TEXT NOT NULL,
    symbol                  TEXT NOT NULL,
    cancel_initiated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancel_initiated_by     TEXT NOT NULL,
    triggering_halt_source  TEXT,
    ack_received_at         TIMESTAMPTZ,
    ack_status              TEXT,
    retry_count             INTEGER DEFAULT 0,
    final_status            TEXT,
    operator_resolution     TEXT,
    operator_resolved_at    TIMESTAMPTZ
);
```

Ambiguous cancellations require explicit operator resolution before the system returns to `open` state on the affected symbol.

---

## §9. Deployment / Change Management Controls

### D9.1 — Why this lives in this ADR

SEC explicitly cited Knight Capital for inadequate deployment controls (dormant code activated). FINRA Rule 3110 requires change management. Per Perplexity §3-Q3 (BLOCKING), this gap is non-negotiable for live trading.

### D9.2 — Mandatory controls (live mode prerequisites)

| Control | Implementation |
|---|---|
| **Signed prod deploys** | Each deployment to production requires operator's signed commit (GPG or SSH key); commit SHA recorded |
| **Immutable deployment log** | `deployment_log` table (DB-enforced append-only); every deploy logged with SHA, operator, timestamp, mode at time of deploy, rollback target |
| **Rollback procedure** | Documented + tested: `scripts/rollback_to.sh <commit_sha>` restores prior state including DB schema if needed |
| **Pre-deploy verification** | All tests pass + smoke test in paper mode for 1 hour minimum before promoting to live |
| **No live code activation without explicit operator gesture** | A code change that adds a new strategy or signal source requires explicit `enable_in_live` operator action AFTER deploy; default is "deployed but disabled in live" |
| **Dormant code review** | Quarterly: grep codebase for unused functions / disabled flags / unreachable code; document with status |
| **Audit chain** | Git commit → CI pipeline log → deployment_log → audit log entries form unbroken chain |

### D9.3 — Storage schema (deployment audit)

```sql
CREATE TABLE deployment_log (
    id                  BIGSERIAL PRIMARY KEY,
    deployed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deployed_by         TEXT NOT NULL,
    commit_sha          TEXT NOT NULL,
    prior_commit_sha    TEXT,
    branch              TEXT,
    target_environment  TEXT NOT NULL CHECK (target_environment IN ('paper','live')),
    operating_mode_at_deploy TEXT NOT NULL,
    deploy_reason       TEXT NOT NULL,
    rollback_target_sha TEXT,
    ci_pipeline_url     TEXT,
    smoke_test_result   JSONB,
    verified_by         TEXT,
    verified_at         TIMESTAMPTZ
);

REVOKE UPDATE, DELETE ON deployment_log FROM jarvis_fin_app;

CREATE TABLE strategy_feature_flags (
    flag_id             TEXT PRIMARY KEY,
    description         TEXT NOT NULL,
    enabled_in_shadow   BOOLEAN NOT NULL DEFAULT TRUE,
    enabled_in_paper    BOOLEAN NOT NULL DEFAULT FALSE,
    enabled_in_live     BOOLEAN NOT NULL DEFAULT FALSE,
    enabled_by          TEXT,
    enabled_at          TIMESTAMPTZ,
    enabled_reason      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE strategy_feature_flag_log (
    id                  BIGSERIAL PRIMARY KEY,
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    flag_id             TEXT NOT NULL,
    prior_state         JSONB,
    new_state           JSONB,
    changed_by          TEXT NOT NULL,
    reason              TEXT NOT NULL CHECK (length(reason) >= 20)
);

REVOKE UPDATE, DELETE ON strategy_feature_flag_log FROM jarvis_fin_app;
```

### D9.4 — Knight-specific protections encoded

The Knight Capital failure was a dormant code path (Power Peg) being accidentally activated by a deployment that reused the flag for new logic. Our protections:

1. **No code path runs in live without explicit `strategy_feature_flags.enabled_in_live = TRUE`**
2. **A flag enabling code in live mode is a separate operator gesture from deployment** — deploy first (deployed but disabled), then explicit enable (with reason)
3. **Flag history is immutable** — historical reuse of flag IDs visible in audit log
4. **Pre-trade gate's velocity detector** (§3.1 `risk_monitor_velocity`) is the second-line defense — even if dormant code activates, velocity halt fires within milliseconds

---

## §MV-2 — Minimum Viable Subset (Phase B)

| Component | MV-2 status |
|---|---|
| Pre-trade gate with all 12 checks | REQUIRED for live |
| Pre-trade gate with 6 critical checks (symbol allowlist, size absolute, size notional, price sanity, daily count, velocity) | REQUIRED for paper |
| `pretrade_limits` + `pretrade_decisions` tables | REQUIRED |
| Symbol allowlist (operator-curated, ≤10 symbols initially) | REQUIRED for paper |
| Degraded-mode matrix: at minimum cover (a) broker disconnect, (b) data feed stale, (c) DB error, (d) clock skew | REQUIRED for paper |
| Full degraded-mode matrix (13 scenarios) | REQUIRED for live |
| Cancel-ACK monitoring with 30s timeout + retry + ambiguous-flag | REQUIRED for paper |
| Deployment log (immutable) | REQUIRED for any trading |
| Feature flags with `enabled_in_live=FALSE` default | REQUIRED for live |
| Signed prod deploys (GPG or SSH key) | REQUIRED for live |
| Quarterly dormant code review | REQUIRED for live |

---

# PART 3 — GOVERNANCE LAYER

## §10. Written Supervisory Procedures (WSP)

### D10.1 — Purpose

Per Perplexity §3-Q2 (BLOCKING) and FINRA Rules 3110 / 3120:

> "FINRA expects written procedures that define WHO reviews WHAT, HOW often, and HOW issues are remediated."

The WSP is a **one-page operator-facing document** that lives in the repo and is referenced by every operator action. It is not a long policy doc — it is the answer to "who is responsible for what, and when."

### D10.2 — Required content (template)

File location: `docs/governance/WSP.md`

The template includes:
- Roles (Kill-Switch Owner, Backup Owner, Auditor)
- Daily Reviews (5 items, ~5 min)
- Weekly Reviews
- Monthly Reviews
- Quarterly Reviews
- Annual Certification
- Incident Response severity levels
- Escalation Path

### D10.3 — WSP versioning

WSP is committed to the repo. Every WSP update logged to `wsp_revisions` table:

```sql
CREATE TABLE wsp_revisions (
    id              BIGSERIAL PRIMARY KEY,
    revised_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    revised_by      TEXT NOT NULL,
    commit_sha      TEXT NOT NULL,
    revision_reason TEXT NOT NULL CHECK (length(revision_reason) >= 20),
    prior_sha       TEXT
);

REVOKE UPDATE, DELETE ON wsp_revisions FROM jarvis_fin_app;
```

### D10.4 — WSP enforcement

The WSP is **only valuable if followed.** Enforcement:

- Daily-review activities have corresponding admin UI pages (one-click checklist)
- Completion logged to `wsp_compliance_log` table (append-only)
- Weekly review surfaces "skipped daily reviews" — operator must acknowledge
- Live mode flag check: `agent_runtime_config.live_eligible = TRUE` requires "all WSP daily reviews complete for last 7 days" to be true

```sql
CREATE TABLE wsp_compliance_log (
    id              BIGSERIAL PRIMARY KEY,
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    review_type     TEXT NOT NULL CHECK (review_type IN ('daily','weekly','monthly','quarterly','annual')),
    completed_by    TEXT NOT NULL,
    notes           TEXT,
    artifacts       JSONB
);

REVOKE UPDATE, DELETE ON wsp_compliance_log FROM jarvis_fin_app;
```

---

## §11. Periodic Review + Annual Certification

### D11.1 — Why this exists

Per Perplexity §3-Q2 (MAJOR) and SEC 15c3-5:

> "SEC explicitly required annual review and CEO certification. Knight was cited for failing to review the effectiveness of controls adequately."

Even solo-operator scope benefits from this discipline: it creates evidence that controls were not just *built* but *operating*.

### D11.2 — Quarterly self-assessment

Every quarter, operator completes self-assessment checklist covering kill-switch, pre-trade gate, degraded modes, cancel monitoring, deployment, feature flags, WSP compliance, chaos testing.

### D11.3 — Annual attestation packet

Annually, operator produces an attestation packet:

| Component | Source |
|---|---|
| Signed cover page | "I attest these controls operated as designed during the period [start - end]" |
| Quarterly self-assessments (4) | `quarterly_attestations` table |
| Deployment audit | All entries in `deployment_log` for the year |
| Override audit | All entries in `halt_overrides` with justifications |
| Incident summary | All `incidents` with severity, resolution, lessons learned |
| Chaos test results | Quarterly chaos runs |
| WSP revisions | All `wsp_revisions` for the year |
| Pretrade gate effectiveness | Aggregate stats: total orders, fail rate by check, average latency |

### D11.4 — Storage schema

```sql
CREATE TABLE quarterly_attestations (
    id                  BIGSERIAL PRIMARY KEY,
    attested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    quarter             TEXT NOT NULL,
    attested_by         TEXT NOT NULL,
    findings            JSONB NOT NULL,
    open_items          JSONB,
    signature_hash      TEXT NOT NULL
);

CREATE TABLE annual_attestations (
    id                  BIGSERIAL PRIMARY KEY,
    attested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    year                INTEGER NOT NULL,
    attested_by         TEXT NOT NULL,
    packet_path         TEXT NOT NULL,
    packet_hash         TEXT NOT NULL,
    summary             JSONB,
    signature_hash      TEXT NOT NULL
);

REVOKE UPDATE, DELETE ON quarterly_attestations FROM jarvis_fin_app;
REVOKE UPDATE, DELETE ON annual_attestations FROM jarvis_fin_app;
```

---

## §12. Incident Response Procedures

### D12.1 — Severity levels

| Severity | Definition | Response timer | Documentation deadline |
|---|---|---|---|
| **SEV-1** | Live trading affected; potential or actual financial impact | Immediate (page operator within 60s) | Within 24h |
| **SEV-2** | Paper trading anomaly; control-path failure; security event | Within 1h business; same day if business hours | Within 48h |
| **SEV-3** | Shadow trading anomaly; informational; non-control failure | Within 24h | Within 7 days |

### D12.2 — SEV-1 response protocol

```
0 sec    — System pages operator (multiple channels: Pushover, SMS, email)
< 60s    — Operator acknowledges page
< 5 min  — Operator on system; review state via /admin/halt
< 10 min — Operator decision: kill-switch already engaged? OR pull manual kill?
< 30 min — Initial diagnosis: which detector fired? what's the data?
< 1h     — Incident report initiated in incidents table (live document)
< 24h    — Post-incident write-up + lessons learned + runbook updates
```

### D12.3 — Storage schema

```sql
CREATE TABLE incidents (
    id                  BIGSERIAL PRIMARY KEY,
    detected_at         TIMESTAMPTZ NOT NULL,
    detected_by         TEXT NOT NULL,
    severity            TEXT NOT NULL CHECK (severity IN ('SEV-1','SEV-2','SEV-3')),
    title               TEXT NOT NULL,
    summary             TEXT,
    operating_mode      TEXT NOT NULL,
    triggering_source   TEXT,
    halt_engaged        BOOLEAN,
    operator_actions    JSONB,
    timeline            JSONB,
    root_cause          TEXT,
    impact              TEXT,
    resolution          TEXT,
    lessons_learned     TEXT,
    runbook_updates     JSONB,
    related_logs        JSONB,
    closed_at           TIMESTAMPTZ,
    closed_by           TEXT,
    post_review_at      TIMESTAMPTZ
);

CREATE TABLE incident_updates (
    id                  BIGSERIAL PRIMARY KEY,
    incident_id         BIGINT NOT NULL REFERENCES incidents(id),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          TEXT NOT NULL,
    update_type         TEXT NOT NULL CHECK (update_type IN ('status_change','timeline_entry','action_taken','observation')),
    content             JSONB NOT NULL
);

REVOKE UPDATE, DELETE ON incident_updates FROM jarvis_fin_app;
```

### D12.4 — Post-incident review

Within 7 days of SEV-1 closure (within 14 days of SEV-2): timeline review, root cause analysis, control gaps, runbook updates, code/config changes filed as TDs or PRs, lessons learned summary.

---

## §13. Chaos Test Harness

### D13.1 — Why automated chaos testing

Per Perplexity §2-Q3 (MAJOR) and Knight Capital lesson:

> "A financial control plane should be regularly tested for network loss, DB read failure, duplicate webhooks, delayed heartbeats, and out-of-order messages."

Code that "should halt on X" is unverified until X has been simulated and observed.

### D13.2 — Mandatory chaos scenarios

18 scenarios covering: alpha halt signal, webhook duplicate, replay, skew, heartbeat lost, broker disconnect, broker cancel no-ack, market data stale (per-symbol + all), DB read failure, DB write failure, clock skew, pretrade gate exception, dormant code activation attempt, velocity breach, runaway strategy, override expiry, override blanket attempt.

### D13.3 — Execution

- **Daily:** 3 random scenarios in paper mode
- **Weekly:** Full scenario sweep in paper mode
- **Pre-deployment:** Affected scenarios run as part of CI
- **Quarterly:** Manual operator-led chaos day

### D13.4 — Storage schema

```sql
CREATE TABLE chaos_test_runs (
    id                  BIGSERIAL PRIMARY KEY,
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at            TIMESTAMPTZ,
    scenario_id         TEXT NOT NULL,
    triggered_by        TEXT NOT NULL,
    expected_outcome    TEXT NOT NULL,
    actual_outcome      TEXT,
    pass_fail           TEXT CHECK (pass_fail IN ('pass','fail','inconclusive')),
    timeline            JSONB,
    artifacts           JSONB,
    notes               TEXT
);
```

### D13.5 — Failure response

If a chaos scenario FAILS in paper mode:
- Live mode promotion is BLOCKED until fix
- File SEV-2 incident
- Update runbook if needed
- Re-run scenario after fix to confirm

---

## §14. Evidence Retention + SLOs

### D14.1 — Evidence retention policy

| Data type | Retention | Storage |
|---|---|---|
| `halt_signal_log` | 7 years (regulatory parallel) | Postgres + nightly backup to Unraid |
| `halt_state_transitions` | 7 years | Postgres + backup |
| `pretrade_decisions` | 7 years | Postgres + backup |
| `cancel_attempts` | 7 years | Postgres + backup |
| `deployment_log` | 7 years | Postgres + backup |
| `incidents` + `incident_updates` | 7 years | Postgres + backup |
| `quarterly_attestations` | 7 years | Postgres + filesystem |
| `annual_attestations` | 7 years + permanent archive | Postgres + filesystem + offsite |
| `chaos_test_runs` | 2 years | Postgres + backup |
| `wsp_compliance_log` | 3 years | Postgres + backup |
| `webhook_nonces` | 10 minutes (then purged) | Postgres |
| `pretrade_limits_log` | 7 years | Postgres + backup |
| `strategy_feature_flag_log` | 7 years | Postgres + backup |

Backup strategy: nightly `pg_dump` to Unraid SMB share; weekly verified restore; quarterly restore on alternate hardware.

### D14.2 — SLOs for kill-switch itself

| Metric | SLO | Alert threshold |
|---|---|---|
| Halt propagation latency | 99% < 500ms | > 1s for 5 min |
| Cancel completion latency | 95% < 2s | > 5s for 5 min OR ambiguous > 0 |
| False-halt rate | 100% chaos pass rate per week | Any chaos failure |
| Heartbeat freshness | 99% within threshold | Stale > threshold for 2 min |
| Webhook delivery success rate | 99% on first attempt | < 95% over 1h |
| Pre-trade gate latency | 99% < 50ms | > 100ms for 5 min |
| DB read latency for view | 99% < 10ms | > 50ms for 5 min |
| WSP daily review completion | 100% within 24h grace | Missed review |
| Deployment audit completeness | 100% of deploys logged | Any unlogged deploy |
| Override compliance (TTL ≤ 4h) | 100% | Any override > 4h |

### D14.3 — Metrics surfacing

All metrics surfaced on `:5443/admin/observability` dashboard with real-time gauges, 24h/7d/30d trends, alert state per metric, direct links to underlying audit log queries. Prometheus-compatible `/metrics` endpoint for future external observability.

---

## §15. Operator Runbooks

### D15.1 — Runbook structure

Per Perplexity §4-Q3, every halted-state scenario has a 1-page runbook in `docs/runbooks/`. Template covers: trigger, severity, initial assessment, decision tree, resolution steps, post-resolution.

### D15.2 — Required runbooks (initial set)

| Runbook | Scenario |
|---|---|
| `RB-001_halt_engaged_unknown_source.md` | Halt engaged but operator doesn't know why |
| `RB-002_broker_disconnect.md` | Alpaca connection lost |
| `RB-003_cancel_ambiguous.md` | Cancel issued, no broker ACK |
| `RB-004_market_data_stale.md` | Bar feed stale for one or more symbols |
| `RB-005_alpha_heartbeat_lost.md` | jarvis-alpha unreachable |
| `RB-006_db_failure.md` | Postgres unreachable or write-failing |
| `RB-007_pnl_breach.md` | Daily loss limit hit |
| `RB-008_position_anomaly.md` | Position size exceeds limit |
| `RB-009_velocity_breach.md` | Order rate exceeded — runaway strategy suspected |
| `RB-010_pretrade_gate_exception.md` | Gate code throwing |
| `RB-011_clock_skew.md` | Time drift detected |
| `RB-012_override_expired_still_halted.md` | Override expired, underlying halt persists |
| `RB-013_chaos_test_failure.md` | Automated chaos scenario failed |

Each runbook is one page. Total: 13 pages.

---

## §MV-3 — Minimum Viable Subset (Phase C / Governance)

For solo-operator scope today:

| Component | MV-3 status |
|---|---|
| WSP one-page document (§10.2) | REQUIRED for any trading |
| Daily review (5 items, ~5 min) | REQUIRED for paper |
| Weekly + monthly review | REQUIRED for live |
| Quarterly self-assessment | REQUIRED for live |
| Annual attestation | REQUIRED for live |
| SEV-1 incident response (basic) | REQUIRED for paper |
| Full SEV-1/2/3 protocol | REQUIRED for live |
| Chaos harness: 5 initial scenarios | REQUIRED for paper |
| Chaos harness: full 18 scenarios | REQUIRED for live |
| Evidence retention (7-year for audit logs) | REQUIRED from paper-mode start |
| SLO instrumentation (key metrics only) | REQUIRED for paper |
| Full SLO suite | REQUIRED for live |
| 5 critical runbooks (RB-001, 002, 005, 006, 009) | REQUIRED for paper |
| All 13 runbooks | REQUIRED for live |

---

# CONSEQUENCES

## Positive

- Failure semantics, pre-trade controls, and governance all defined in one document — internal consistency guaranteed
- 11 institutional gaps identified by Perplexity all addressed
- Knight Capital failure pattern explicitly defended against (velocity detector + cancel-ack monitoring + dormant code controls)
- MV checkpoints make scope tractable for solo operator
- Evidence retention from day 1 of paper means no "we should have logged that" gaps later
- SLO instrumentation makes the kill-switch a service with measurable reliability
- WSP compliance becomes machine-verifiable
- Chaos testing catches "we built it but never tested it" failure mode

## Negative

- Significant implementation scope — 4 PRs across financial + alpha + standards
- 20 new database tables — operational complexity increase
- More runbooks to maintain (13 initially)
- Quarterly + annual attestation cycle adds operational overhead (~2 hours/quarter, 1 day/year)
- Chaos test failures will block live promotion — slower velocity but safer
- Pre-trade gate latency budget (50ms) constrains strategy timing

## Neutral

- Push-based webhook delivery deferred to future ADR if sub-second halt propagation is ever required
- External vault (Infisical/Bitwarden per ADR-0003) not in scope here
- Multi-region considerations deferred (single operator scope)
- Risk monitor detector implementations deferred to PR-A5-financial-2 (only velocity required in MV-1)
- Assumes solo-operator scope; managed-money or multi-trader expansion would require revisiting against SEC 15c3-5, FINRA 3110, MiFID II Art 17

---

# IMPLEMENTATION ROADMAP

| # | Repo | PR | Description |
|---|---|---|---|
| 1 | jarvis-standards | PR-S-ADR-0011 | This ADR + ADR-0010 §8 amendment |
| 2 | jarvis-alpha | PR-A5-alpha | Webhook sender service + retry policy + delivery audit + heartbeat poster + LaunchAgent |
| 3 | jarvis-financial | PR-A5-financial-1 | MV-1 + MV-2 + MV-3 minimum subset |
| 4 | jarvis-financial | PR-A5-financial-2 | Live-mode prerequisite items: full pre-trade gate, full degraded-mode matrix, full risk monitor suite, full chaos harness, all 13 runbooks, attestation tooling, full SLO suite, admin UI |

PR sequence is gated. PR-A5-alpha cannot merge until standards ADR merged. PR-A5-financial-1 cannot merge until alpha endpoint live. PR-A5-financial-2 cannot merge until -financial-1 stable for 24h.

Mode transition gates:

| Transition | Gate |
|---|---|
| `shadow → paper` | All MV-1 + MV-2 + MV-3 REQUIRED-for-paper rows + 24h continuous paper operation without anomalies |
| `paper → live` | All REQUIRED-for-live items + M-09 DR delivered + dual-poller redundancy + chaos full sweep passing + 6-month paper window per `docs/calibration_criteria.md` |

---

# OPEN QUESTIONS

| ID | Question | Defer to |
|---|---|---|
| OQ-1 | Should `agent_runtime_config.mode` changes require T1-T5 approval-gateway sign-off? | PR-A5-financial-1 design review |
| OQ-3 | If live mode is ever multi-region, does dual-M4 redundancy generalize to N-way? | When relevant |
| OQ-4 | Push-based webhook overlay — when, if ever? | Post-paper-window retro |
| OQ-5 | External vault adoption (Infisical/Bitwarden per ADR-0003) — when? | Alpha-6 |
| OQ-6 | Multi-strategy support — does each strategy get its own pre-trade limits scope? | When second strategy is built |
| OQ-7 | Integration with managed observability (Datadog / Grafana Cloud) — when? | When solo-host observability proves insufficient |

---

# ALTERNATIVES CONSIDERED

| Option | Status | Reason |
|---|---|---|
| Always fail-OPEN | Rejected | Indefensible for live trading per SEC 15c3-5 |
| Always fail-CLOSED | Rejected | Kills dev velocity in shadow/paper |
| Hybrid mode-aware | **Accepted** | Right behavior per risk level |
| Alpha as canonical source of truth | Rejected | Violates 15c3-5 "direct and exclusive control" |
| Financial-local only (no alpha signals) | Rejected | Loses "halt everything from one place" capability |
| Hybrid: financial owns, alpha can signal | **Accepted** | Decoupled but coordinated |
| Push-based webhook only | Deferred | Heartbeat-style sufficient for solo scope |
| Postgres LISTEN/NOTIFY for cross-repo | Rejected | Requires shared/replicated DB |
| Single mega-ADR | **Accepted** | Internal consistency between three concerns |
| Split into ADR-0011 + ADR-0012 + ADR-0013 | Rejected | Coordination overhead across 3 docs |
| Bypass pre-trade gate in backtests | Rejected | Knight lesson — every code path must run gate |
| Auto-flatten on halt (default) | Rejected | Could realize losses worse than original risk during transient blip |
| Pre-trade gate inside strategy module | Rejected | Violates 15c3-5 separation of concerns |

---

# REFERENCES

## External standards
- SEC Rule 15c3-5 (Risk Management Controls for Brokers or Dealers With Market Access)
- FINRA Rule 3110 (Supervision)
- FINRA Rule 3120 (Supervisory Control System)
- MiFID II Article 17 (Algorithmic Trading)
- MiFID II RTS 6 (Annual self-assessment)

## Postmortems
- Knight Capital 2012 — SEC Litigation Release & FINRA Order — $460M loss in 45 minutes from dormant code activation + no order velocity controls

## Validation
- Perplexity Pro multi-lens review 2026-05-12 (4 lenses: institutional risk officer, fintech platform engineer, regulatory compliance specialist, exchange SRE)

## jarvis ecosystem
- ADR-0010 (jarvis-standards): Cross-Repo Runtime Bridge Contract — §8 amended by this ADR
- `docs/calibration_criteria.md` (jarvis-financial): Paper→live gates — canonical, referenced not duplicated
- M-09 (jarvis-financial): DR architecture — dual M4 redundancy
- M-04 (jarvis-financial): Portfolio module — concentration limits referenced by pre-trade gate check #10
- Investigation findings 2026-05-12 (this session)

## Related TDs (filed alongside this ADR)
- TD-B' (jarvis-financial): PR-A5 implementation tracking
- TD-D, TD-E, TD-F (jarvis-financial): existing P1s
- TD-K (jarvis-standards): This ADR tracking
- TD-L through TD-W (jarvis-financial): component-level tracking TDs
