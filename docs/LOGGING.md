# JARVIS Python Logging Standard

> Authoritative pattern: **structlog with a JSON renderer, initialized before pydantic-settings load.** See [ADR-0008](adr/ADR-0008-structlog-as-python-logging-standard.md) for the decision rationale and alternatives considered.
>
> **Status:** ADR-0008 supersedes the prior stdlib `logging` + `from server.logging_config import get_logger` pattern. Existing services on the old pattern migrate per the schedule in TD-X36 ([#33](https://github.com/kphaas/jarvis-standards/issues/33)); new code in any repo follows this doc.

---

## TL;DR

- Use `structlog`, not stdlib `logging`.
- Initialize logging **first** in `main()`, before any import or call that triggers pydantic-settings.
- Emit JSON lines to stderr.
- Required processors: `merge_contextvars` → `add_log_level` → `TimeStamper(fmt="iso")` → `dict_tracebacks` → `JSONRenderer`.
- Bind `service` and `node` once at config time via `bind_contextvars`; never pass them to individual `logger.info` calls.
- For services whose startup failures need a durable Pg row beyond the stderr line, use the canonical `fatal.py` recovery-path helper (own asyncpg connection, 5s wall-clock budget, never raises).

---

## Required `pyproject.toml` dependency

Every Python service entry-point package declares structlog directly:

```toml
[project]
name = "jarvis-<service>"
requires-python = ">=3.12"
dependencies = [
    "structlog>=24.1",
    # ...
]
```

Pin the major version (`>=24.1`) and bump deliberately. Workspace siblings re-export from the entry point's resolution; no per-package re-pin needed.

---

## Canonical `log_setup.py`

Reference implementation: jarvis-financial `services/worker/worker_app/log_setup.py` (PR #59, commit `68bf7a9`). Copy into each new service; do not fork.

```python
"""Worker structured-logging configuration.

Called as the FIRST thing in `main()`, before `get_worker_settings()`.
Two reasons for the ordering:

1. If `WorkerSettings()` raises (e.g. missing env var on a misconfigured
   LaunchAgent install), the validation error needs to land as a
   structured JSON line on stderr — not a raw Python traceback. The
   structlog config has to be live before that exception is caught.

2. Structlog's default is `ConsoleRenderer`, which is human-friendly
   but unscrapable. Operators tail the worker log with
   `tail -f worker.out.log | jq -c`; that workflow only works when
   every line is JSON. Mirrors the API's `configure_observability`.

Idempotent: structlog.configure replaces any prior config, so calling
this twice (e.g. once at module import, once inside `main()` after a
test reset) is safe.

Static fields (`service`, `node`) are bound via contextvars so every
log line carries them without each `logger.info` having to repeat the
kwargs. Rebinding inside the same process is a no-op for the same key
— `bind_contextvars` overwrites.
"""

from __future__ import annotations

import logging
import socket

import structlog


def configure_worker_logging(level: str = "INFO") -> None:
    """Wire structlog to emit JSON lines to stdout.

    `level` is a logging-module name (`DEBUG`, `INFO`, `WARNING`, ...).
    Unknown values fall through to `INFO` rather than raising — we'd
    rather log too much than crash the worker on a typo'd config.
    """
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

    # Static fields: every line tells the operator which service and
    # which host emitted it. socket.gethostname is best-effort — falls
    # back to a sentinel rather than blowing up if the OS call fails.
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

When porting into a new service, change exactly two things:

1. The function name — e.g. `configure_api_logging`, `configure_planner_logging`.
2. The `service=` value bound at the bottom — e.g. `"alpha-brain-auth"`, `"forge-planner"`. Naming convention is `<repo-prefix>-<module>`, lowercase, hyphen-separated.

Everything else (processor list, wrapper class, logger factory, contextvars handling) is fixed. Diverging from the processor chain breaks downstream `jq` filters and is treated as a regression.

---

## Canonical `fatal.py` recovery-path helper

For services whose startup failures must be recorded durably — anything running under LaunchAgent, anything where the operator may not see stderr in real time — pair `log_setup.py` with the `fatal.py` recovery-path pattern below. CLI scripts and short-lived jobs without a Pg-side fatal table can skip this.

Reference implementation: jarvis-financial `services/worker/worker_app/fatal.py` (PR #59, commit `68bf7a9`).

```python
"""Recovery-path fatal-event recorder.

Called from the worker's startup `try/except` after structured logging
emits the JSON FATAL line. The helper:

1. Opens its OWN minimal asyncpg connection (NOT through the worker's
   SQLAlchemy engine — that may not exist if engine construction is
   what failed).
2. INSERTs one row into `worker_fatal_events`.
3. Closes the connection.
4. Returns None.

It NEVER raises. The crash path is already inside an `except` block;
the worker is on its way out. If the helper itself trips (Pg down,
table missing pre-migration, schema drift, etc.), it logs a structured
WARNING to stderr and returns. The structured JSON line that preceded
the helper call is the durable record — observability degrades
gracefully, never disappears.

Time budget: 5 seconds total wall-clock for connect + INSERT + close,
enforced by `asyncio.wait_for`. The asyncpg-level `timeout=2.0` on
connect is the inner defense — even if `wait_for` somehow does not
fire (it always does), asyncpg gives up after 2s. ThrottleInterval in
the LaunchAgent plist is 60s, so a 5s recovery cost is well within
budget.

DSN sourced from `os.environ["JARVIS_FIN_POSTGRES_DSN"]` directly —
not via WorkerSettings, since that's what may have failed. If the env
var is missing, the helper logs and returns without attempting Pg.

Crash-loop detection is a separate concern from "did we record the
fatal" — the COUNT query lives in `heartbeat.py` and runs BEFORE this
helper inserts, so the inserted row's `fatal_class` already reflects
"crash_loop_detected" when applicable.
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
from typing import Any

import asyncpg
import structlog
from sqlalchemy.engine.url import make_url

logger = structlog.get_logger()

# Hard ceiling on the entire recovery-path call. Mirrors the value
# documented in the architecture review: connect + INSERT + close,
# with 2s of asyncpg-internal connect timeout as the inner defense.
_RECOVERY_TIMEOUT_SECONDS = 5.0
_CONNECT_TIMEOUT_SECONDS = 2.0


def _asyncpg_dsn_from_env() -> str | None:
    """Return a non-SQLAlchemy asyncpg DSN, or None if env var missing.

    `JARVIS_FIN_POSTGRES_DSN` carries SQLAlchemy's `+asyncpg` driver
    suffix (`postgresql+asyncpg://...`). asyncpg.connect itself wants
    the bare `postgresql://...` form. `make_url` strips the suffix
    cleanly without us hand-rolling string surgery.
    """
    raw = os.environ.get("JARVIS_FIN_POSTGRES_DSN")
    if not raw:
        return None
    url = make_url(raw)
    bare = url.set(drivername="postgresql")
    return bare.render_as_string(hide_password=False)


async def _do_insert(
    dsn: str,
    *,
    worker_id: str,
    node_hostname: str,
    fatal_class: str,
    error_type: str,
    error_message: str,
    structured_data: dict[str, Any],
    process_pid: int,
    parent_pid: int,
) -> None:
    conn = await asyncpg.connect(dsn, timeout=_CONNECT_TIMEOUT_SECONDS)
    try:
        await conn.execute(
            """
            INSERT INTO worker_fatal_events (
                worker_id,
                node_hostname,
                fatal_class,
                error_type,
                error_message,
                structured_data,
                process_pid,
                parent_pid
            ) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8)
            """,
            worker_id,
            node_hostname,
            fatal_class,
            error_type,
            error_message,
            json.dumps(structured_data),
            process_pid,
            parent_pid,
        )
    finally:
        await conn.close()


async def record_fatal_event(
    *,
    fatal_class: str,
    exc: BaseException,
    worker_id: str,
    structured_data: dict[str, Any] | None = None,
) -> None:
    """Insert a fatal-event row. Never raises.

    `fatal_class` must be one of the values in the migration's CHECK:
    `config_validation_failed`, `startup_unexpected`, or
    `crash_loop_detected`. A typo would land as a CHECK violation and
    the helper would swallow it; the structured WARNING below makes
    that diagnosable.
    """
    payload = dict(structured_data or {})
    dsn = _asyncpg_dsn_from_env()
    if dsn is None:
        # Stderr structured event is the durable record when we can't
        # reach Pg. The caller already emitted a FATAL line — this
        # WARNING just notes that the Pg-side row was skipped.
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
        # Catches asyncio.TimeoutError, asyncpg errors, anything else.
        # Stderr WARNING is the fallback record — the FATAL log line
        # the caller emitted is the primary one.
        logger.warning(
            "worker.fatal.record_failed",
            fatal_class=fatal_class,
            recovery_error_type=type(inner).__name__,
            recovery_error=str(inner)[:500],
        )
```

When porting into a new service:

1. Replace `JARVIS_FIN_POSTGRES_DSN` with the service's own DSN env var.
2. Replace `worker_fatal_events` with the service's fatal-event table name.
3. Adjust the `fatal_class` CHECK values to match that service's migration.
4. Keep the `_RECOVERY_TIMEOUT_SECONDS` and `_CONNECT_TIMEOUT_SECONDS` constants and the "never raises" contract intact. These are the load-bearing parts.

---

## `main()` initialization order

Every Python service entry point follows the same three-step bootstrap. The order is **not negotiable** — it's the entire point of ADR-0008.

```python
import asyncio
import sys

import structlog

from .log_setup import configure_worker_logging
from .settings import get_worker_settings
from .runtime import run

logger = structlog.get_logger()


def main() -> None:
    # 1. Structured logging live BEFORE anything that can fail.
    configure_worker_logging()

    # 2. Settings load — may raise pydantic ValidationError.
    #    The except blocks emit structured FATAL via the logger
    #    we configured above. Without step 1, this traceback
    #    would land as a multi-line blob on stderr.
    try:
        settings = get_worker_settings()
    except Exception as exc:
        logger.fatal(
            "worker.startup.config_failed",
            error_type=type(exc).__name__,
            error_message=str(exc)[:4000],
        )
        # Optional: durable Pg-side row.
        asyncio.run(_record_startup_fatal(exc))
        sys.exit(1)

    # 3. Application start.
    asyncio.run(run(settings))


async def _record_startup_fatal(exc: BaseException) -> None:
    """Best-effort durable record of a startup failure."""
    from .fatal import record_fatal_event

    await record_fatal_event(
        fatal_class="config_validation_failed",
        exc=exc,
        worker_id="snapshot-worker",
    )


if __name__ == "__main__":
    main()
```

The pattern generalizes verbatim to FastAPI (call `configure_api_logging()` at the top of `main.py` before `app = FastAPI()`), CLI scripts (call it as the first line of `cli()`), and one-off batch jobs.

---

## Log-call ergonomics

Once configured, log calls use structlog's `kwargs`-as-fields style. **Do not** pass `extra={...}` (that's the stdlib `logging` API).

```python
import structlog

logger = structlog.get_logger()

logger.info("batch_started", batch_id=batch_id, feature_count=5)
logger.warning("budget_near_cap", used=8.50, cap=10.00)
logger.error("http_call_failed", url=url, status=resp.status_code)
```

Stable message string + dynamic kwargs. Dynamic data **never** goes in the message — it goes in kwargs. This keeps the message stable for grouping and alerting downstream.

### Exception handling

```python
try:
    risky_operation()
except Exception:
    logger.exception(
        "operation_failed",
        operation="risky_operation",
        context=relevant_context,
    )
    # Decide: re-raise, return None, or continue — NEVER silently pass.
```

`logger.exception` captures the chain via `dict_tracebacks` (already in the processor chain). The output includes structured `exception` field with frames and locals; `jq '.exception.frames[0].name'` works.

### Request/run-scoped fields

When a request id, run id, or user id should propagate to every log line within a scope, use `bind_contextvars`:

```python
async def handle_request(request_id: str) -> None:
    structlog.contextvars.bind_contextvars(request_id=request_id)
    try:
        # every logger.info inside this scope (including transitive
        # callees) carries request_id automatically
        await do_work()
    finally:
        structlog.contextvars.unbind_contextvars("request_id")
```

This replaces the stdlib pattern of threading a logger adapter through every function signature.

---

## Migration from the old `get_logger` pattern

For services migrating off `from server.logging_config import get_logger`:

1. **Add `structlog>=24.1` to `pyproject.toml`** in the service entry-point package.
2. **Create `<service>/log_setup.py`** by copying the canonical from jarvis-financial; rename `configure_worker_logging` and the `service=` binding.
3. **Replace logger acquisition** at the top of every module:

   ```diff
   -from server.logging_config import get_logger
   -logger = get_logger("forge-planner")
   +import structlog
   +logger = structlog.get_logger()
   ```

   (The `service=` field is bound globally in `log_setup.py`; per-module `get_logger("forge-planner")` is no longer needed.)

4. **Convert `extra=` calls to kwargs**:

   ```diff
   -logger.info("batch_started", extra={"batch_id": batch_id})
   +logger.info("batch_started", batch_id=batch_id)
   ```

5. **Convert `logger.exception(msg, extra={...})`** the same way:

   ```diff
   -logger.exception("op_failed", extra={"feature_id": feature_id})
   +logger.exception("op_failed", feature_id=feature_id)
   ```

6. **Move logging init to first line of `main()`.** If the service currently calls `get_logger` lazily on first import, the migration moves the equivalent call (`configure_<service>_logging()`) to the first executable line of the entry point — before settings load.

7. **Delete `server/logging_config.py`** once no module imports from it. Workspace siblings sharing the helper are migrated as a unit.

8. **Verify with a syntax check + a unit run**:

   ```bash
   python3 -c "import ast; ast.parse(open('<file>').read()); print('syntax ok')"
   pytest <service>/tests/ -k logging
   ```

Per-service migration size in financial's PR #59 was ~20 lines per module (logger acquisition + `extra=` to kwargs). Total per-service migration time is typically under an hour for a small service; longer only when modules use stdlib-specific features (`logging.LoggerAdapter`, custom handlers) that need rethinking.

---

## Anti-patterns

1. **`print()` for anything user-facing in server code.** Use `logger.info` / `logger.warning`. `print` bypasses the JSON renderer and breaks `jq` consumers.
2. **`except: pass`.** Hides real failures for weeks. Always log + decide (re-raise / return None / degrade).
3. **Dynamic data in the log message string.** Breaks alerting. Use kwargs.
4. **Logging secrets, tokens, passwords, PII.** Ever. The `dict_tracebacks` processor will happily render local variables — be deliberate about what's in scope at the failure site.
5. **`extra={...}` passed to a structlog logger.** That's the stdlib API. structlog will accept it without erroring (extra is added as a top-level dict field) but the convention is direct kwargs.
6. **Configuring logging after settings load.** The whole point of ADR-0008 is that this fails the most important class of bug. If you find yourself calling `configure_*_logging()` *anywhere* other than the first line of `main()`, the change is wrong.
7. **Two logger config files in one repo** (`logging_config.py` AND `log_setup.py`). Pick one (the structlog `log_setup.py`); delete the other.
8. **Building a custom `_log()` wrapper.** The structlog API is the wrapper. Adding another layer makes call sites non-grep-able.

---

## Side-effect writers (fire-and-forget logging)

For code that writes to a DB, cache, or external service as a **side effect** of a primary operation (recording metrics after a run, emitting an audit row), failure must be loud-but-not-fatal:

```python
async def _record_metrics(result: RunResult) -> None:
    """Fire-and-forget metrics writer.

    Failure is logged loudly but does NOT crash the caller.
    Losing a metrics row is bad; crashing the real operation is worse.
    """
    try:
        await db_write(result)
    except Exception:
        logger.exception(
            "metrics_write_failed",
            run_id=result.run_id,
            feature_id=result.feature_id,
        )
        # Do NOT re-raise. Degrade gracefully.
```

This pattern is identical to the prior LOGGING.md guidance modulo the kwargs migration. Never use it for the primary operation itself — there, exceptions must propagate.

---

## Quick reference

| Do | Don't |
|---|---|
| `import structlog; logger = structlog.get_logger()` | `from server.logging_config import get_logger` |
| `logger.info("event", key=value)` | `logger.info(f"event {value}")` |
| `logger.exception("op_failed", run_id=run_id)` | `logger.error(f"Failed: {e}")` |
| Stable message + kwargs | Dynamic f-string in message |
| `configure_*_logging()` first line of `main()` | Logging init after settings load |
| `bind_contextvars(request_id=...)` for scoped fields | Threading logger adapters through signatures |
| Always handle `except` explicitly | `except: pass` |

---

## Why structlog (brief)

- Structured fields are first-class kwargs, not stdlib `extra={}` glue.
- `bind_contextvars` propagates fields across awaits / transitive calls without explicit pass-through.
- Idempotent `configure` lets logging init move to the first line of `main()` — which is the load-bearing property for catching pydantic-settings failures with a parseable line.
- `dict_tracebacks` produces `jq`-drillable exception chains.
- API-stable at 24.x; one MIT-licensed pure-Python dependency with no novel transitive deps.

Full rationale, alternatives weighed, and reversal conditions: [ADR-0008](adr/ADR-0008-structlog-as-python-logging-standard.md).

---

## Related standards

- [ADR-0008](adr/ADR-0008-structlog-as-python-logging-standard.md) — the locking decision
- `SECURITY.md` (planned) — secrets handling; never log sensitive data
- `TESTING.md` (planned) — how to assert on log output in tests
- TD-X36 / [#33](https://github.com/kphaas/jarvis-standards/issues/33) (this repo) — non-financial Python services migration audit
