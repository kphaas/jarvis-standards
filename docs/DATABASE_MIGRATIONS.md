# Database Migrations — JARVIS Convention

**Status:** Active · **Owner:** Ken · **Applies to:** jarvis-family (live), jarvis-alpha (if/when needed)

---

## Principles

- **Forward-only.** No down migrations. Problems fixed with forward corrections.
- **Atomic.** Every migration wrapped in `BEGIN; ... COMMIT;`.
- **Idempotent where safe.** `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, etc.
- **Tracked.** Every DB gets a `schema_migrations` table. Runner skips what's already applied.
- **Test + prod in lockstep.** Runner applies to both `<db>` and `<db>_test` on every deploy.

---

## File Naming

Pattern: `YYYYMMDD_HHMMSS_short_description.sql`

Examples:

- `20260414_000000_init.sql`
- `20260417_100000_pet_health.sql`
- `20260419_000000_fix_audit_is_synthetic.sql`

Filenames are sorted lexicographically by the runner, so timestamps guarantee order.

---

## Superseded Migrations

When a migration ships broken and its fix is a new file (not an edit):

1. Rename the broken file from `.sql` → `.sql.superseded`
2. Keep it in git history for the record
3. The runner's glob only picks up `*.sql`, so `.sql.superseded` files are ignored

**Do not edit migration files in place after they've shipped.** If a live DB has the filename in its tracker, editing the file produces drift between DBs.

Example: `20260415_140000_custody_audit_foundation.sql.superseded` — superseded by `_v3.sql`.

---

## Tracker Table

Created automatically by the runner on first use:

```sql
CREATE TABLE jarvis_family.schema_migrations (
    filename   TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

One row per applied migration. Runner consults this before every apply.

---

## Required Elements in Every Migration

1. `BEGIN;` at the top, `COMMIT;` at the bottom
2. Header comment: purpose, author, date
3. All DDL ideally `IF NOT EXISTS` / `IF EXISTS` guarded
4. Do **not** insert into `schema_migrations` from inside the migration — the runner handles that

---

## Runner Contract

Scripts that act as runners must conform to:

- Read `.sql` files in sorted order from a migrations directory
- Skip any filename already in `schema_migrations`
- Apply with `psql -v ON_ERROR_STOP=1` (halt on any SQL error)
- On success, insert the filename into `schema_migrations`
- On failure, halt immediately — **no partial state**
- Emit to stdout: `OK:<n_new>:<n_skipped>` on success, `FAIL:<filename>` on failure
- Human-readable progress to stderr only (keeps stdout machine-parseable)

---

## Services Using This Convention

| Service | Runner | Notes |
|---|---|---|
| jarvis-family | `scripts/apply_migrations.sh` | Live, dual-DB (prod + test) |
| jarvis-alpha | — | Not yet; may adopt when TaskGraph migrations land |
| jarvis-forge | n/a | SQLite only, no migration runner needed |

---

## When to Share the Runner Script

Rule of three: when a **third** service needs a Postgres migration runner, promote the family version to:
jarvis-standards/scripts/_templates/apply_migrations.template.sh

and propagate via `scripts/propagate_scripts.sh`.

Until then, copy the convention (this doc), not the code. Each service's topology may differ — shared script is premature abstraction.

---

## See Also

- `jarvis-family/scripts/apply_migrations.sh` — reference implementation
- `jarvis-family/db/migrations/` — example migrations
- DEBT-046 (closed) — created `apply_migrations.sh` and added test DB sync
