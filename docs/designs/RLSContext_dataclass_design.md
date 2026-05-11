# DESIGN — RLSContext frozen dataclass (Slab 4 Phase 3)

- **Status:** Draft for review (implementation deferred to paired session)
- **Date:** 2026-05-11
- **Author:** Claude Code (drafted from Phase 1a / 1b audit findings + TD-211 hotfix)
- **Companions:** Phase 1a (`DISCOVERY_2026-05-11_slab4_phase1a_secdef_audit.md`), Phase 1b (`DISCOVERY_2026-05-11_slab4_phase1b_caller_audit.md`), TD-211 (PR #87)
- **Implementation prerequisite:** Slab 4 Phase 2a/2b/2c SECDEF fleet writes (PRs #89/#90/#91) merged
- **Linked PRs (Phase 2):** kphaas/jarvis-alpha#89, #90, #91

## §1. Context

### 1.1 Where we are today

The canonical RLS helper is `brain/db/rls.py:rls_connection(request: Request)`. It:

1. Reads `user_id`, `role`, `max_rating`, `workspace_id` from `request.state` (populated by `JWTAuthMiddleware`).
2. Maps the JWT `role` to a `jarvis_role` enum (`platform_admin`, `user`, `child`).
3. Acquires a pool connection, `SET ROLE jarvis_alpha_app`, sets the four `rls.*` session GUCs, yields the connection in a transaction, `RESET ROLE` on exit.

It is **the** entrypoint for HTTP routes that touch FORCE-RLS tables. Background workers and middleware are told explicitly NOT to use it (rls.py:25-26): they must go through SECURITY DEFINER functions instead.

### 1.2 What broke

The Phase 1a and 1b audits exposed two failure modes:

- **Class A — SECDEF pattern hole.** 17 of 19 JARVIS-owned SECURITY DEFINER functions operate on FORCE-RLS tables without setting `rls.role` inside the body. Today they work only because the owner (`jarvisbrain`) has `BYPASSRLS`. Phase 2 (PRs #89/#90/#91) closes this hole by inserting `PERFORM set_config('rls.role','platform_admin',true)` at the top of each function.
- **Class B — caller-side pattern hole.** 9 callsites in `brain/routes/dream.py`, `brain/routes/watchdog.py`, and `brain/middleware/approval.py` query FORCE-RLS tables on raw pool connections without setting `rls.role`. Five of those are **CRITICAL writes** (`brain/routes/dream.py:65,132,160,261,356`) that are silently broken in production today (Phase 1b §4 empirical check). TD-211 hotfix landed an inline `set_config('rls.role','platform_admin',true)` for one of these surfaces.

### 1.3 Why a dataclass

TD-211's inline-`set_config` pattern is fragile. It scatters policy decisions across callsites, makes audit trails opaque (who elevated to `platform_admin` and why? where?), and leaves the JWT/role/admin coupling implicit. We have **two parallel patterns in production today**: `rls_connection(request)` (JWT-derived) and `_bind_executor_rls(conn)` (hardcoded `platform_admin` for the executor) — see Phase 1b §3a rows for `brain/tasks/executor.py:189,452,510`. A third pattern (inline set_config) is creeping in via TD-211 and `dream_invariant_checker.py:142,303` / `dream_cost_cap_service.py:43,125`.

A frozen `RLSContext` dataclass is the unifying primitive. It makes the question "who am I as far as RLS is concerned?" a first-class value object. Helpers like `rls_connection(ctx)` and `rls_admin_connection(origin)` then consume the dataclass. Audit attribution travels with the value rather than being lost in the connection-acquisition implementation.

## §2. Proposed dataclass

```python
from dataclasses import dataclass
from typing import Literal, Optional


RLSRole = Literal["platform_admin", "user", "child"]
RLSSource = Literal["jwt", "system", "background"]


@dataclass(frozen=True)
class RLSContext:
    """Immutable description of how to bind RLS GUCs on a pool connection.

    Constructed by the layer that knows identity (middleware, background
    worker, test fixture) and consumed by the layer that knows the pool
    (`rls_connection`). Frozen to prevent middleware downstream from
    silently elevating a 'user' context to 'platform_admin'.

    Fields:
        role:         One of 'platform_admin', 'user', 'child'. Drives the
                      `rls.role` GUC and gates RLS policies.
        user_id:      JWT sub for user/child roles. None for system role.
        profile_id:   Active child profile if applicable (drives content
                      filtering). None otherwise.
        max_rating:   Content rating ceiling for the child route. Defaults
                      to 'all_ages' for safety.
        workspace_id: Primary workspace from JWT claim. Empty string when
                      not workspace-scoped.
        source:       Where this context originated. Drives the audit
                      trail and is forbidden to be 'jwt' for any role
                      other than 'user'/'child' (admin elevation comes
                      from 'system' or 'background', not directly from
                      a JWT claim — see §8.2).
        audit_actor:  Who logically performs the operation. For 'jwt'
                      source this is just user_id; for 'system' this
                      should name the subsystem (e.g. 'buddy',
                      'executor', 'approval_consume').
        audit_origin: Free-text identifier for where the context was
                      constructed (e.g. 'RLSContextMiddleware',
                      'buddy_agent._expire_pending_approvals',
                      'tests.fixtures.admin_ctx').
    """

    role: RLSRole
    user_id: Optional[str] = None
    profile_id: Optional[str] = None
    max_rating: str = "all_ages"
    workspace_id: str = ""
    source: RLSSource = "jwt"
    audit_actor: Optional[str] = None
    audit_origin: Optional[str] = None

    def __post_init__(self) -> None:
        # Invariants the frozen-ness alone cannot enforce.
        if self.source == "jwt" and self.role == "platform_admin":
            raise ValueError(
                "RLSContext: source='jwt' cannot pair with role='platform_admin'. "
                "Admin elevation must come from source='system' or 'background', "
                "with audit_actor/audit_origin naming the elevating subsystem."
            )
        if self.role in ("user", "child") and not self.user_id:
            raise ValueError(f"RLSContext role={self.role!r} requires user_id")
```

## §3. Helper API surface

Three helpers, all `asynccontextmanager`:

```python
from contextlib import asynccontextmanager

@asynccontextmanager
async def rls_connection(ctx: RLSContext):
    """Acquire a pool connection and apply rls.* GUCs from `ctx`.

    This is the new primitive. All other helpers compose this.
    """
    pool = get_pool()
    async with pool.acquire() as conn:
        await conn.execute("SET ROLE jarvis_alpha_app")
        try:
            async with conn.transaction():
                await conn.execute("SELECT set_config('rls.user_id', $1, true)", ctx.user_id or "")
                await conn.execute("SELECT set_config('rls.role', $1, true)", ctx.role)
                await conn.execute("SELECT set_config('rls.max_rating', $1, true)", ctx.max_rating)
                await conn.execute("SELECT set_config('rls.workspace_id', $1, true)", ctx.workspace_id)
                # Emit a structured audit line — see §7.
                logger.debug(
                    "rls_connection.bind role=%s source=%s actor=%s origin=%s",
                    ctx.role, ctx.source, ctx.audit_actor, ctx.audit_origin,
                )
                yield conn
        finally:
            await conn.execute("RESET ROLE")


@asynccontextmanager
async def rls_connection_from_request(request: Request):
    """Convenience: extract RLSContext from request.state and acquire conn.

    Drop-in replacement for today's `rls_connection(request)`. Keeps the
    HTTP-route ergonomics identical while reading from a structured value.
    """
    ctx = _ctx_from_request(request)
    async with rls_connection(ctx) as conn:
        yield conn


@asynccontextmanager
async def rls_admin_connection(origin: str, *, audit_actor: str = "system"):
    """System-level admin connection. Explicit origin required for audit.

    Replaces today's three patterns:
      - `_bind_executor_rls(conn)` (brain/tasks/executor.py)
      - inline `set_config('rls.role','platform_admin',true)` (dream services, TD-211)
      - SECDEF-only paths that defensively set rls.role in the body

    Use only from background workers, scheduled jobs, internal middleware,
    or where the operation is fundamentally platform-level (not per-user).
    """
    ctx = RLSContext(
        role="platform_admin",
        source="system",
        audit_actor=audit_actor,
        audit_origin=origin,
    )
    async with rls_connection(ctx) as conn:
        yield conn
```

## §4. Construction sites

Who builds `RLSContext` objects:

### 4.1 `RLSContextMiddleware` (replaces today's JWTAuthMiddleware shim)

Already today, `JWTAuthMiddleware` sets `request.state.user_id / role / max_rating / workspace_id` from the JWT. The new middleware additionally constructs `request.state.rls: RLSContext`. `_ctx_from_request(request)` is then a trivial accessor.

This is additive: `JWTAuthMiddleware` keeps the existing flat fields for backward compat; `RLSContextMiddleware` adds the bundle.

### 4.2 Background workers — admin context

Three known constructors:

- `brain/tasks/executor.py` — replaces `_bind_executor_rls(conn)` (rls.py-44–) with `async with rls_admin_connection('executor.run_graph')`.
- `brain/agents/buddy_agent.py` — already calls SECDEFs; if it ever does a raw read, it gets `rls_admin_connection('buddy_agent.<method>')`.
- `brain/agents/watchdog_agent.py` — same pattern.
- `brain/services/dream_invariant_checker.py:142,303` and `brain/services/dream_cost_cap_service.py:43,125` — replace inline `set_config` with `rls_admin_connection('dream_invariant_checker.<method>')`.

### 4.3 Middleware (TD-211 sites)

`brain/middleware/approval.py:151,198` — replaces TD-211's inline `set_config` with `rls_admin_connection('approval.consume_approved_queue')` and `rls_admin_connection('approval.unique_violation_fallback')`. The composition becomes self-documenting (origin in the audit trail names exactly what failed).

### 4.4 Test fixtures

```python
def admin_ctx(origin: str = "tests") -> RLSContext:
    return RLSContext(
        role="platform_admin", source="system",
        audit_actor="test", audit_origin=origin,
    )

def user_ctx(user_id: str, *, workspace_id: str = "") -> RLSContext:
    return RLSContext(role="user", user_id=user_id, workspace_id=workspace_id, source="jwt", audit_actor=user_id)
```

Tests construct contexts explicitly; production code constructs them via middleware or `rls_admin_connection`.

## §5. Migration plan

Phased rollout to keep PRs reviewable and revertible.

### Phase 3.1 — Land the primitive (additive)

- Add `RLSContext` dataclass + `RLSRole`/`RLSSource` aliases in `brain/db/rls.py`.
- Add `rls_connection(ctx)`, `rls_admin_connection(origin, ...)`, `_ctx_from_request(request)`.
- Keep the legacy `rls_connection(request)` signature working as a thin wrapper:
  ```python
  @asynccontextmanager
  async def rls_connection(request_or_ctx):
      if isinstance(request_or_ctx, RLSContext):
          ...new path...
      else:
          ...delegate to rls_connection_from_request...
  ```
- Add unit tests for the dataclass invariants (§2 `__post_init__`).

**PR scope:** new code only; zero changes to existing callsites; CI must stay green.

### Phase 3.2 — Pilot: refactor approvals.py (validates TD-211 site)

- Replace TD-211's inline `set_config` at `brain/middleware/approval.py:151,198` with `rls_admin_connection('approval.consume_approved_queue')` / `rls_admin_connection('approval.unique_violation_fallback')`.
- Add a regression test: TD-211 stays fixed (the approval queue read under writer role still works) AND the audit trail now carries `audit_origin='approval.consume_approved_queue'`.

**PR scope:** approval.py + tests; one PR; ≤30 lines of code change.

### Phase 3.3 — Fan out

- Migrate `brain/routes/dream.py:65,132,160,201,261,356` — Phase 1b CRITICAL writes. Per Phase 1b §8 open question, Ken first decides between `rls_connection_from_request(request)` (JWT-derived) and `rls_admin_connection('dream.<route>')` (platform-level). The dataclass supports both equivalently.
- Migrate `brain/routes/watchdog.py:127,169` — add `request: Request`, use `rls_connection_from_request`.
- Migrate `brain/tasks/executor.py:189,452,510` — replace `_bind_executor_rls` with `rls_admin_connection('executor.<method>')`. Delete `_bind_executor_rls`.
- Migrate `brain/services/dream_invariant_checker.py` and `brain/services/dream_cost_cap_service.py` — replace inline set_config sites.

**PR scope:** can be one PR per file, or one consolidated PR if review burden is light. Each migration is a mechanical refactor with strong test coverage.

### Phase 3.4 — Deprecate the legacy signature

After all callsites migrated:

- Mark `rls_connection(request)` shim as deprecated; emit a `DeprecationWarning`.
- One release cycle later, remove the shim. `rls_connection` becomes ctx-only.
- Remove `_bind_executor_rls` and any other legacy patterns.

## §6. Convention codification

A short flowchart for any future code that needs DB access against FORCE-RLS tables:

```
Is this code reachable via an authenticated HTTP request?
├── YES  → `async with rls_connection_from_request(request) as conn:`
│         (role derives from JWT: admin → platform_admin, parent → user, child → child)
│
└── NO   → Is this a platform-level operation (background worker, cron, internal middleware,
          scheduled maintenance, executor)?
          ├── YES  → `async with rls_admin_connection('subsystem.method') as conn:`
          │         (always platform_admin; audit trail names the origin)
          │
          └── NO   → reconsider. If you can't classify the surface, ask: does this code
                    legitimately bypass user-level isolation? If not, it probably belongs
                    in an HTTP route. If yes, use rls_admin_connection — but be ready to
                    defend that in code review.
```

Tests construct `RLSContext` directly.

## §7. Test plan

### 7.1 Unit tests for the dataclass

- `RLSContext` is frozen (assert `dataclasses.FrozenInstanceError` on attribute set).
- `__post_init__` rejects `source='jwt'` + `role='platform_admin'`.
- `__post_init__` rejects `role='user'` without `user_id`, `role='child'` without `user_id`.

### 7.2 Unit tests for helpers

- `rls_connection(ctx)` sets the four `rls.*` GUCs to the ctx values, verified via `current_setting()` inside the yield block.
- `rls_connection_from_request(request)` builds a context that matches the request.state and yields a connection with the same GUCs as the legacy path.
- `rls_admin_connection('origin')` always sets `rls.role=platform_admin` and records `audit_actor='system'` / `audit_origin='origin'` in the log line.

### 7.3 Regression tests

- **TD-211 stays fixed.** Phase 3.2 must include an integration test that calls the approvals endpoint under writer-role pool and confirms the approval queue read succeeds. The current TD-211 test in `tests/brain/middleware/test_approval.py` (or equivalent) must remain green after the refactor.
- **Backward-compat shim.** Phase 3.1 must include a test that exercises the legacy `rls_connection(request)` signature; that test must stay green until Phase 3.4 removal.

### 7.4 Integration test

- Every existing `rls_connection`/`_bind_executor_rls`/inline-`set_config` callsite must continue to work post-migration. Phase 1b's §3a callsite inventory is the source of truth for the surfaces to cover. Add a CI job that fails if any new raw `pool.acquire()` against a FORCE-RLS table is introduced without going through `rls_connection` / `rls_admin_connection`.

## §8. Risk analysis

### 8.1 Audit trail loss

**Risk:** the `audit_actor` / `audit_origin` fields are advisory; if a caller forgets to set them, the audit trail is empty.

**Mitigation:** Make `audit_origin` required (not Optional) on `rls_admin_connection`. This is the helper most commonly used outside HTTP routes; forcing the origin string at the helper-call site guarantees it. For `rls_connection(ctx)` direct construction, `audit_origin=None` is acceptable as long as the helper logs which middleware constructed the context.

### 8.2 Admin elevation source check

**Risk:** A future contributor could construct `RLSContext(role='platform_admin', source='jwt', user_id=jwt_sub)` and silently bypass admin auth.

**Mitigation:** `__post_init__` raises if `source='jwt'` and `role='platform_admin'` (already encoded in §2). Admin elevation must always come from `system` or `background` source, naming the subsystem.

### 8.3 Performance: per-request dataclass construction

**Risk:** Allocating an `RLSContext` per request adds overhead.

**Mitigation:** Negligible — a frozen dataclass is a thin wrapper over a tuple; construction is sub-microsecond. The four `set_config` calls dominate the cost of the helper, not the dataclass. No mitigation needed beyond documenting expectations.

### 8.4 Backward compatibility during Phase 3.1–3.4

**Risk:** Callsites still using the old `rls_connection(request)` signature need to keep working during migration.

**Mitigation:** Phase 3.1's `request_or_ctx` shim handles both signatures. Deprecation warning lands in Phase 3.4, removal one release after. Confirmed safe by the existing Phase 1b audit which inventoried every callsite.

### 8.5 Inconsistent rls.role on existing background paths

**Risk:** The audit found `_bind_executor_rls` uses `rls.role=platform_admin` while inline-`set_config` sites also use `platform_admin` — but a defensive grep of policy USING/WITH CHECK clauses might surface tables where `platform_admin` doesn't match the expected privilege level.

**Mitigation:** Phase 1a/1b confirmed that every Class A SECDEF and every Class B callsite is targeting `platform_admin`. Phase 3 is not changing the privilege level, only the construction path. No new risk.

### 8.6 Slab 7c sequencing

**Risk:** If Slab 7c removes BYPASSRLS from owner roles before Phase 3 fans out, the inline-`set_config` sites that haven't been migrated still work (the inline call sets rls.role). But the dataclass refactor doesn't change RLS evaluation, only how the GUCs get set. So Phase 3 and Slab 7c are independent and can land in either order.

**Mitigation:** None needed; document the independence in the PR descriptions.

## §9. Open questions for Ken

Before paired implementation starts, these need a yes/no/option-X answer:

1. **Should `audit_actor` be required (not Optional) on `RLSContext`?** Required is stricter and makes the audit trail unconditional. Optional is more ergonomic for tests. Recommend: keep Optional for tests, but enforce non-None at production callsites via `rls_admin_connection`'s signature (which has `audit_actor: str = "system"` default).
2. **Should `source` be richer than `jwt`/`system`/`background`?** Possible additions: `temporal` (Temporal workflow), `cron` (LaunchAgent), `admin_action` (operator UI click), `dream_orchestrator`. Recommend: start with the 3-value enum; widen if needed.
3. **Migration cadence: parallel deprecation (Phase 3.1–3.4) or hard cutover?** Recommend parallel (Phase 3.1 ships additive, Phase 3.4 removes the shim after one release). Hard cutover would simplify but risks merging-rebase pain for any in-flight PRs.
4. **Dream routes auth model (Phase 1b §8 open Q #2 carried forward).** Should `brain/routes/dream.py` use `rls_connection_from_request` (JWT-derived, admin-only by default) or `rls_admin_connection('dream.<route>')` (platform-level, any authenticated user)? This shapes which helper the dream-routes migration in Phase 3.3 picks.
5. **Watchdog routes auth model (Phase 1b §8 open Q #3 carried forward).** Same question for `brain/routes/watchdog.py:127,169`. They have no `request: Request` today. Add auth (use `rls_connection_from_request`) or keep them unauth-only-platform-admin (use `rls_admin_connection`)?
6. **Should we add a guard against new raw `pool.acquire()` calls into FORCE-RLS tables?** A pre-commit / CI hook that greps for `pool.acquire` + any of the 21 FORCE-RLS table names in the same file, and fails if neither `rls_connection`/`rls_admin_connection` is present. Phase 1b found 70 callsites total — easy to scan; tooling makes Slab 7c-future-proof.
7. **Should `RLSContext` carry `max_rating` and `workspace_id` for all roles?** Currently the dataclass has them as defaults (`'all_ages'`, `''`). The child route needs `max_rating`; admin doesn't. Question: enforce that `max_rating` is set explicitly for `role='child'` (via `__post_init__`)? Recommend: yes, with a sensible default for non-child roles.

## §10. References

### Internal

- Phase 1a audit: `~/jarvis-alpha/docs/discovery/DISCOVERY_2026-05-11_slab4_phase1a_secdef_audit.md` (179 lines, on branch `claude-code/slab4-audit-1a-1b`)
- Phase 1b audit: `~/jarvis-alpha/docs/discovery/DISCOVERY_2026-05-11_slab4_phase1b_caller_audit.md` (153 lines, same branch)
- TD-211 caller-side hotfix: `kphaas/jarvis-alpha#87` (merged) — pattern this design generalizes from
- Slab 4 Phase 2a SECDEF fleet write — approval cluster: `kphaas/jarvis-alpha#89`
- Slab 4 Phase 2b SECDEF fleet write — memory cluster: `kphaas/jarvis-alpha#90`
- Slab 4 Phase 2c SECDEF fleet write — observability cluster: `kphaas/jarvis-alpha#91`
- Current `brain/db/rls.py` (HEAD `b97e425` 2026-05-11) — the helper this design replaces
- `brain/tasks/executor.py:_bind_executor_rls` (line 44–) — the second pattern this design unifies

### Conventions referenced

- ADR-0005 (branch naming + P-trait deploy)
- PATTERNS.md §15 (system sentinel convention used by buddy_events)

### Standards external

- PostgreSQL `set_config(name, value, is_local)` — `is_local=true` confines to current transaction; matches our `SET LOCAL ROLE` pattern
- Python `dataclasses.dataclass(frozen=True)` — immutable value semantics; `FrozenInstanceError` on attempted mutation
- `typing.Literal` — runtime-validated string enums (via `__post_init__` in our case)
