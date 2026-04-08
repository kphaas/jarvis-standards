# LOGGING Standard

Structured JSON logging pattern for all JARVIS services.

## 30-Second Summary

```python
from server.logging_config import get_logger
logger = get_logger("forge-<service-name>")

logger.info("event_name", extra={"key": value})
logger.warning("something_off", extra={"feature_id": "F-123"})
logger.exception("write_failed", extra={"run_id": run_id})  # in except blocks
```

Never use `import logging` + `logging.getLogger(...)` in new code. Always use the shared `get_logger` helper.

---

## Why

- **Consistency** — every log line has the same structure: `timestamp / level / service / node / message / extra`
- **Machine-readable** — JSON logs are grep-able, parseable by Loki/Datadog/CloudWatch without a regex
- **Single source of truth** — one `logging_config.py` means format changes happen in one place
- **Production-grade from day one** — no cleanup pass needed later

---

## The Standard Pattern

### Import at top of file

```python
from server.logging_config import get_logger

logger = get_logger("<repo>-<service>")
```

Service naming convention: `<repo-prefix>-<module>`. Examples:
- `forge-claude-runner`
- `forge-planner`
- `alpha-brain-auth`
- `alpha-gateway-unifi`

Use hyphens, not dots. Lowercase only.

### Log calls

```python
logger.info("batch_started", extra={"batch_id": batch_id, "feature_count": 5})
logger.warning("budget_near_cap", extra={"used": 8.50, "cap": 10.00})
logger.error("http_call_failed", extra={"url": url, "status": resp.status_code})
```

**Always put dynamic fields in `extra={}`**, not f-strings inside the message. This keeps the message stable for grouping/alerting.

### Exception handling

```python
try:
    risky_operation()
except Exception:
    logger.exception(
        "operation_failed",
        extra={"operation": "risky_operation", "context": relevant_context},
    )
    # Decide: re-raise, return None, or continue — NEVER silently pass
```

`logger.exception()` automatically captures the full traceback. Use it in `except` blocks.

---

## Good vs Bad

### ✅ Good

```python
from server.logging_config import get_logger
logger = get_logger("forge-planner")

def plan_feature(feature_id: str) -> Plan:
    logger.info("planning_started", extra={"feature_id": feature_id})
    try:
        plan = generate_plan(feature_id)
        logger.info("planning_succeeded", extra={"feature_id": feature_id, "step_count": len(plan.steps)})
        return plan
    except Exception:
        logger.exception("planning_failed", extra={"feature_id": feature_id})
        raise
```

### ❌ Bad

```python
import logging
logger = logging.getLogger("jarvis.forge.planner")  # Bypasses the shared helper

def plan_feature(feature_id):
    print(f"Planning {feature_id}")                 # Never use print
    try:
        plan = generate_plan(feature_id)
        logger.info(f"Planned {feature_id} with {len(plan.steps)} steps")  # Dynamic data in message
        return plan
    except Exception as e:
        logger.error(f"Failed: {e}")                # Loses stack trace
        pass                                        # SILENT FAILURE — never do this
```

---

## Quick Reference Table

| Do | Don't |
|---|---|
| `from server.logging_config import get_logger` | `import logging` |
| `logger = get_logger("forge-X")` | `logger = logging.getLogger("X")` |
| `logger.info("event_name", extra={...})` | `logger.info(f"event {var}")` |
| `logger.exception(...)` in `except` | `logger.error(f"Failed: {e}")` |
| Stable message + dynamic `extra` | Dynamic f-string in message |
| Always handle `except` explicitly | `except: pass` |
| Return `None` or re-raise after log | Silent continue without log |

---

## Error Handling Pattern (Side-Effect Writers)

For code that writes to a DB, cache, or external service as a **side effect** of a primary operation (e.g., recording metrics after a run completes):

```python
def _record_metrics(result: RunResult) -> None:
    """Fire-and-forget metrics writer.

    Failure is logged loudly but does NOT crash the caller.
    Losing a metrics row is bad; crashing the real operation is worse.
    """
    try:
        db_write(result)
    except Exception:
        logger.exception(
            "metrics_write_failed",
            extra={"run_id": result.run_id, "feature_id": result.feature_id},
        )
        # Do NOT re-raise. Degrade gracefully.
```

This pattern is used in production at Google/Meta/Netflix for observability writers. Never use it for the primary operation itself — there, exceptions must propagate.

---

## Migration Guide (Old Files)

Converting an old `import logging` file to the standard:

1. Replace `import logging` with `from server.logging_config import get_logger`
2. Replace `logger = logging.getLogger("jarvis.forge.X")` with `logger = get_logger("forge-X")`
3. Run: `grep -n "logger\." <file>` — verify all log calls still valid
4. Run: `python3 -c "import ast; ast.parse(open('<file>').read()); print('syntax ok')"`
5. No other changes needed — the logger API is identical

Reference migration: jarvis-forge commit `c0fdefb` migrated `auto_tester.py`, `auto_reviewer.py`, `cost_estimator.py` in 7 insertions / 6 deletions.

---

## The `get_logger` Helper

Lives at `server/logging_config.py` in each repo. Canonical implementation in jarvis-alpha (pending consolidation per F-187). Copy — do not fork — when spinning up a new repo.

Signature:

```python
def get_logger(name: str) -> logging.Logger:
    """Return a logger configured with structured JSON output.
    
    Format: {timestamp, level, service, node, message, ...extra}
    """
```

---

## Anti-Patterns (Never Do These)

1. `print()` for anything user-facing in server code
2. `except: pass` — hides real failures for weeks (actually happened in jarvis-forge F-165)
3. Building your own `_log()` function instead of using `get_logger` (claude_runner.py did this — removed in F-165)
4. Putting dynamic data in the log message f-string — breaks alerting and grouping
5. Two logger files in one repo (`logger.py` AND `logging_config.py`) — pick one, delete the other
6. Logging secrets, tokens, passwords, or PII — ever

---

## Related Standards

- `SECURITY.md` (planned) — secrets handling, never log sensitive data
- `TESTING.md` (planned) — how to assert on log output in tests

