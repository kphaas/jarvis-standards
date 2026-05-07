# ADR-0008: structlog as the JARVIS Python services logging standard

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** Ken
- **Supersedes:** Original `LOGGING.md` guidance (stdlib `logging` via `from server.logging_config import get_logger`). The doc is rewritten in the same PR that lands this ADR.
- **Related:** TD-X9 (jarvis-financial handoff `HANDOFF_2026-05-02_01.md` ledger); jarvis-financial PR #59 (reference implementation, merged 2026-05-01, commit `68bf7a9`); TD-X36 / [#33](https://github.com/kphaas/jarvis-standards/issues/33) (this repo — non-financial migration audit, filed in this same PR)

---

## Context

The original `docs/LOGGING.md` standard prescribed Python's stdlib `logging` module via a per-repo `from server.logging_config import get_logger` helper. The pattern was good enough for the forge and alpha repos in 2025, where logging mistakes surfaced as developer-visible noise rather than as production-incident blind spots.

That assumption broke in jarvis-financial M2. The financial worker runs under a `launchd` LaunchAgent on Sandbox; its only failure-recording surface is whatever lands in `~/Library/Logs/jarvis-financial/worker.{out,err}.log`. On 2026-05-01 during the first end-of-day reconciliation, the worker's pydantic-settings load could have failed before any `import logging` configuration was reached. With stdlib `logging`, that path produces a multi-line Python traceback flushed to stderr — unparseable by `jq`, unscrapable by Loki, and silently dropped by every downstream filter that expects one JSON object per line. The operator would have had to manually `tail` the raw log, locate the traceback by eye, and reconstruct what failed.

PR #59 (merged 2026-05-01, commit `68bf7a9`) addressed this by inverting the bootstrap order: structlog with a JSON renderer is configured as the literal first executable line of `main()`, *before* any pydantic-settings instantiation. Any subsequent failure — a missing env var, a malformed DSN, a CHECK-violating migration — produces a single structured JSON line on stderr that the operator's existing `tail -f ... | jq -c` pipeline parses without modification. The `worker_fatal_events` Pg row is the durable secondary record; the JSON stderr line is the primary.

The pattern was production-validated on its first real fire (2026-05-01 EOD reconciliation against Alpaca paper account `PA3MVTJSIFL4`). The fix worked because logging was structured *and* it was live before settings load. Either property alone would have been insufficient: structured logging that boots after settings would have silently dropped the validation error; logging-before-settings with stdlib output would have produced an unparseable multi-line blob.

This ADR exists because the financial pattern is now provably better than the LOGGING.md prescription, and because every additional Python service started without a binding decision will inherit the older stdlib pattern by default. Two services have already been touched in M2 (api, reconciler) using structlog; one (worker) shipped the canonical pattern. The remaining JARVIS Python services (alpha, family, council, forge, possibly print-copilot) have not been audited. Without an architectural lock now, divergence compounds.

The architectural question is **which** Python logging library + bootstrap order is canonical, not whether structured logging is required (LOGGING.md already settled that). Three options were on the table:

1. **Keep stdlib `logging` + `get_logger`, document financial as a deviation.** Defers the divergence problem.
2. **Promote structlog + log-init-before-settings as canonical, rewrite LOGGING.md.** Codifies the production-tested pattern as the JARVIS-wide rule.
3. **Audit all services first, decide based on majority pattern.** Lets headcount decide an architecture call.

Option 2 is the only choice consistent with a "production-tested patterns win" rule. Financial is the only service with battle-test data. The "majority" doesn't get a vote when the minority has the only outage to learn from.

## Decision

**JARVIS adopts `structlog` (>= 24.1) as the canonical Python structured-logging library**, with two binding rules:

1. **Logging initialization runs before any pydantic-settings instantiation.** Every service entry point's `main()` (or `__main__.py`) calls its `configure_*_logging()` helper as the literal first executable line. Settings load second. Application start third. No exceptions for "small" scripts: the entry point ordering is the rule.
2. **JSON renderer is the wire format on stderr.** The structlog processor chain is fixed: `merge_contextvars` → `add_log_level` → `TimeStamper(fmt="iso")` → `dict_tracebacks` → `JSONRenderer`. Static fields (`service`, `node`) are bound via contextvars at config time, not passed to every log call.

The canonical reference implementation is `services/worker/worker_app/log_setup.py` and `services/worker/worker_app/fatal.py` in jarvis-financial (PR #59, commit `68bf7a9`). New services copy — do not fork — this pair. `LOGGING.md` is rewritten in the same PR that lands this ADR; the rewrite quotes both modules in full as the canonical bootstrap pair.

### Required `pyproject.toml` dependency

```toml
dependencies = [
    "structlog>=24.1",
    # ...
]
```

### Required entry-point ordering

```python
def main() -> None:
    configure_worker_logging()           # 1. structured logging live
    settings = get_worker_settings()     # 2. pydantic-settings load (may raise)
    asyncio.run(run(settings))           # 3. application start
```

The `try/except` around step 2 is mandatory in any service whose failure is operator-actionable. The `except` block emits a structured FATAL line (already possible because step 1 ran) and optionally calls a `record_fatal_event`-style helper to insert a durable Pg row. See `fatal.py` in financial for the recovery-path pattern (own asyncpg connection, 5s wall-clock budget, never raises).

### Canonical `log_setup.py` excerpt

The financial worker's helper is the reference. Quoting the core idiom (file is 69 lines total; see `LOGGING.md` for the full version):

```python
def configure_worker_logging(level: str = "INFO") -> None:
    """Wire structlog to emit JSON lines to stdout."""
    numeric_level = getattr(logging, level.upper(), logging.INFO)

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.dict_tracebacks,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(numeric_level),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )

    try:
        node = socket.gethostname()
    except OSError:
        node = "unknown"

    structlog.contextvars.clear_contextvars()
    structlog.contextvars.bind_contextvars(
        service="snapshot-worker",
        node=node,
    )
```

The function is **idempotent** by construction — `structlog.configure` replaces any prior config, and `bind_contextvars` overwrites by key. Calling it twice (once at module import, once after a test reset) is safe.

### Canonical recovery-path helper

The financial worker's `fatal.py` shows the pattern for services whose startup failures need a durable record beyond the stderr JSON line. Quoting the entry function (file is 167 lines; see `LOGGING.md` for the full version):

```python
async def record_fatal_event(
    *,
    fatal_class: str,
    exc: BaseException,
    worker_id: str,
    structured_data: dict[str, Any] | None = None,
) -> None:
    """Insert a fatal-event row. Never raises."""
    payload = dict(structured_data or {})
    dsn = _asyncpg_dsn_from_env()
    if dsn is None:
        logger.warning(
            "worker.fatal.dsn_missing",
            fatal_class=fatal_class,
            error_type=type(exc).__name__,
        )
        return

    try:
        await asyncio.wait_for(
            _do_insert(
                dsn,
                worker_id=worker_id,
                node_hostname=socket.gethostname(),
                fatal_class=fatal_class,
                error_type=type(exc).__name__,
                error_message=str(exc)[:4000],
                structured_data=payload,
                process_pid=os.getpid(),
                parent_pid=os.getppid(),
            ),
            timeout=_RECOVERY_TIMEOUT_SECONDS,
        )
    except Exception as inner:
        logger.warning(
            "worker.fatal.record_failed",
            fatal_class=fatal_class,
            recovery_error_type=type(inner).__name__,
            recovery_error=str(inner)[:500],
        )
```

Three properties matter:

1. **Own connection.** The helper uses `asyncpg.connect` directly, not the SQLAlchemy engine — the engine may not exist if engine construction is what failed.
2. **Hard wall-clock budget.** `asyncio.wait_for` ceiling (5s) plus `asyncpg.connect(timeout=2.0)` inner defense. The crash path can never block the LaunchAgent's restart cadence.
3. **Never raises.** Every internal failure (Pg down, table missing, schema drift, env var missing) downgrades to a structured WARNING and returns. The stderr FATAL line that preceded the call is the primary durable record; the row is the secondary.

### Service-name + node-name binding

`structlog.contextvars.bind_contextvars(service=<repo-prefix>-<module>, node=<hostname>)` is called once at the end of `configure_*_logging`. Naming convention matches the prior `LOGGING.md` rule: lowercase, hyphen-separated, e.g. `snapshot-worker`, `forge-planner`, `alpha-brain-auth`. Every log line carries both fields without each `logger.info` having to repeat them.

### Out of scope for this ADR

- **Log shipping / aggregation pipeline.** Loki / Grafana / Datadog ingest is a separate decision; this ADR fixes the wire format (JSON lines on stderr), not the destination.
- **Non-Python services.** Node, Go, or shell-script logging is unaffected. The Next.js web service has its own logging conventions.
- **Test-time logging assertions.** A future `TESTING.md` will define how to assert on log output; out of scope here.
- **Migration timing for existing services.** TD-X36 ([#33](https://github.com/kphaas/jarvis-standards/issues/33), filed in this same PR) tracks the audit + per-repo migration TDs. Existing services on stdlib `logging` continue running until touched.

## Consequences

### Positive

- A failure during settings load — the highest-leverage class of startup bug — produces a parseable JSON line on stderr instead of a multi-line traceback. Operator's `tail -f ... | jq -c` pipeline works on the failure case, not just the success path.
- Service identity (`service`, `node`) is bound once at config time and travels with every line; eliminates the "which host emitted this?" question that anonymous container logs leave open.
- Structlog's contextvars-based binding means request-scoped fields (request id, user id, run id) propagate without explicit pass-through, matching the ergonomics of OpenTelemetry's context propagation.
- Idempotent `configure_*_logging` lets tests reset logging state between cases without elaborate teardown.
- Pattern is production-tested. The 2026-05-01 EOD fire in financial validated it against a real failure mode, not a synthetic one.
- `dict_tracebacks` produces structured exception chains that `jq` can drill into (`.exception.frames[0].name`), instead of pre-formatted strings that require regex to parse.

### Negative

- One more dependency per Python service (`structlog>=24.1`). Mitigation: it's a single MIT-licensed pure-Python library with no transitive deps that aren't already present, and it's been at API-stable 24.x for a year. Tier 4 dependency cost; trivial.
- Existing services using `from server.logging_config import get_logger` need migration. Mitigation: deferred via TD-X36 to the next time each service is touched; no flag-day cutover. Each migration is mechanically small (PR #59 in financial showed it as a ~20-line delta per service module).
- Operators learning the pattern have to internalize "log init runs before settings load". Mitigation: the canonical `log_setup.py` docstring documents the rule in-place; copy-paste of the file carries the rationale.
- `dict_tracebacks` produces verbose output for deeply nested exceptions. Mitigation: that's the point — the operator wants the structured chain. If a downstream consumer trips on size, switch to `format_exc_info` with a custom truncator; out of scope for the standard.

### Neutral

- This ADR replaces, not supplements, the original LOGGING.md. There is no "two patterns coexist" period beyond the migration tail. New code, including new modules in repos that haven't migrated, follows the new standard.
- The structlog config is identical across services modulo the bound `service` name. Future cross-cutting changes (add a field, change timestamp format) edit the canonical `log_setup.py` and propagate by copy.
- The `fatal.py` recovery-path helper is **optional** for services without a "must record this failure to a durable store" requirement. A pure CLI script that crashes on bad config can rely on the stderr JSON line alone.

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| `structlog` (>= 24.1, PyPI) | Tier 4 (third-party Python lib, pinned in `pyproject.toml`) | Stdlib `logging` with the JSON formatter remains a viable fallback if structlog is ever yanked or compromised — config replacement is bounded to `log_setup.py`. The pattern (init-before-settings, JSON-on-stderr) is library-agnostic. |
| `asyncpg` (recovery-path helper, jarvis-financial-only) | Tier 4 (already a financial dependency) | Helper is optional. Services without a Pg-side fatal table skip it. |

structlog adds no new external service or network surface. The library is a code-path replacement for stdlib `logging`. PyPI access for `uv sync` is already required for every service's existing dependency tree; this ADR does not extend that requirement.

## Alternatives considered

### Option A — structlog + log-init-before-settings (SELECTED)

See Decision section above.

### Option B — Keep stdlib `logging` + `get_logger`; document jarvis-financial as a deviation

Leave LOGGING.md as-is, add a one-paragraph note that financial uses structlog. Other services continue on the stdlib pattern.

Rejected: defers divergence rather than resolving it. Two patterns coexist indefinitely; new services flip a coin or copy the wrong neighbour. The "deviation" framing also gets the production data backwards — financial has the pattern that survived contact with reality, so calling it the deviation lets the un-tested pattern set the rule. No advantage to keeping a less-capable standard.

### Option C — Audit all services first, decide based on majority pattern

Inventory every JARVIS Python service, count which use stdlib vs structlog vs custom, weight the decision by service count or LoC.

Rejected as inverted decision criteria. Production validation, not headcount, picks the canonical pattern. Financial is the only service with a real outage to learn from; treating that as one vote among five is a category error. The audit still happens — TD-X36 — but to drive migration, not to choose the standard.

### Option D — Rewrite LOGGING.md without an ADR

Update the doc directly; skip the ADR.

Rejected: loses the decision rationale, makes future divergence harder to challenge, and leaves no record of the alternatives weighed. ADRs are cheap; the rationale outlives the doc edit.

### Option E — Adopt OpenTelemetry logs as the primary Python logging surface

Wire OTel SDK as the logging backend, treat structured logs as a side product of trace export.

Rejected as premature. OTel logs are still an OTel-spec WIP and the financial worker doesn't yet emit traces at all. The right time to revisit OTel logs is when the JARVIS observability stack adopts a unified collector (out of scope for this ADR; tracked elsewhere). structlog and OTel are not mutually exclusive — structlog can be wired as an OTel log emitter later without changing the call sites.

## Reversal conditions

Revisit this ADR if any of the following occur:

1. **structlog upstream becomes unmaintained or compromised.** The library has a single maintainer; a 12-month gap in commits or a CVE without a patch within a reasonable window forces a fallback. Stdlib `logging` with a custom JSON formatter is the documented fallback; the JARVIS-side change is bounded to `log_setup.py` per service.
2. **A class of failure surfaces that the JSON-on-stderr wire format cannot capture.** Hypothetical example: a future binary-blob field that breaks `jq -c` line parsing. Trigger a re-evaluation of the wire format (probably toward something like CBOR or Protobuf logs), not necessarily of structlog itself.
3. **OTel logs reach SDK-stable status across Python and the JARVIS observability stack adopts a unified collector.** At that point, evaluate whether structlog should remain the call-site API with OTel as the backend, or whether OTel SDK calls replace structlog directly. Decision deferred to that point.
4. **Annual review.** Re-read this ADR at the next yearly standards review (target Q2 2027). Logging libraries and observability conventions move; explicit review prevents silent rot.

## References

- jarvis-financial PR #59 (reference implementation): <https://github.com/kphaas/jarvis-financial/pull/59>
- jarvis-financial commit `68bf7a9` (canonical `log_setup.py` + `fatal.py` source)
- jarvis-financial `services/worker/worker_app/log_setup.py` (in-repo canonical)
- jarvis-financial `services/worker/worker_app/fatal.py` (in-repo canonical recovery-path helper)
- jarvis-financial migration `infra/migrations/versions/0003_*` (creates `worker_fatal_events` + `worker_heartbeats`)
- structlog documentation: <https://www.structlog.org/en/stable/>
- structlog contextvars guide: <https://www.structlog.org/en/stable/contextvars.html>
- TD-X36 / [#33](https://github.com/kphaas/jarvis-standards/issues/33) (this repo) — non-financial Python services migration audit
- `docs/LOGGING.md` (this repo) — rewritten in the same PR; reflects the canonical pattern in code-quoting form
