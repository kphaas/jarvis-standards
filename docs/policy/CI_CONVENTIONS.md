# CI Conventions

Authoritative conventions that the JARVIS uniform CI workflow
(`scripts/_templates/workflows/ci.yml`, propagated to every consumer
repo per `docs/DEPLOYMENT.md` §15.2) assumes about repo source code and
test layout. Repos that diverge from these conventions either need a
local override or will see substrate CI fail in ways the substrate
cannot diagnose.

Companion to `docs/policy/RULESET_CANONICAL.md` (branch protection /
push policy) and `docs/DEPLOYMENT.md` §15.2 (substrate mechanism
catalog).

For private-repo self-hosted runner policy, see
`docs/policy/TRUSTED_SANDBOX_CI.md`. That document covers the Sandbox trust
boundary, repo enable variable, branch-prefix gate, and Forge-owned runner
fleet monitoring.

## Marker convention for integration tests (TD-X48)

The substrate's `test` job invokes pytest with marker filter
`-m "not integration"` by default. The intent is to keep PR-time signal
**fast, portable, and reproducible** — the substrate workflow runs on
GitHub-hosted Linux runners with no service containers (no Postgres, no
Redis, no S3 mock, no outbound network expectations beyond pip / PyPI).

### Rule

Tests that require external infrastructure to run **MUST** be marked
`@pytest.mark.integration`. Concretely, this includes (non-exhaustive):

- Tests that connect to a real database (Postgres, MySQL, SQLite-on-disk,
  etc.) at module-import or fixture-setup time.
- Tests that bind to a TCP port or expect a service on `localhost:<port>`.
- Tests that talk to a third-party API over the network (Stripe, OpenAI,
  cloud SDKs, webhooks, anything that resolves DNS at test time).
- Tests that read or write outside the repo working tree.
- Tests that depend on Docker, an external CLI like `psql` / `redis-cli`,
  or any subprocess that isn't a pure Python tool already installed by
  `uv sync`.

Tests that are pure-Python, hermetic, and only touch the repo's own code
+ stdlib + declared dependencies do NOT need the marker — these are the
default population the substrate runs.

### Marker registration

Repos using the integration marker must register it in `pyproject.toml`
to silence pytest's "unknown marker" warnings:

```toml
[tool.pytest.ini_options]
markers = [
    "integration: requires external infrastructure (DB, network, etc.); skipped in default CI",
]
```

Without registration, pytest treats unknown markers as a warning by
default and as an error under `--strict-markers` — tests will still run,
but the convention surface is fragile.

## Repo-level override

Repos that need a different default — for example, a repo whose tests
genuinely never need external services and where the `not integration`
filter is just dead weight, or a repo that wants to additionally exclude
slow tests — override the substrate via a GitHub **repository-level
variable** (Settings → Secrets and variables → Actions → Variables tab):

| Variable | Effect |
|---|---|
| `JARVIS_PYTEST_MARKERS` unset | Default: `-m "not integration"` |
| `JARVIS_PYTEST_MARKERS=""` | Run all tests regardless of marker |
| `JARVIS_PYTEST_MARKERS="not integration and not slow"` | Add `slow` exclusion |
| `JARVIS_PYTEST_MARKERS="integration"` | **Only** run integration tests (e.g. for a nightly job) |

The substrate reads `vars.JARVIS_PYTEST_MARKERS` at workflow expand time
and falls back to `not integration` when the variable is empty or unset.
No workflow-file edit is required to change the filter — keeps the
substrate identical across repos and preserves Phase 3 propagation
without per-repo divergence.

### Repos with 100%-integration test suites (TD-X48 v2)

Some repos — particularly those whose every test depends on a real
database or service fixture (e.g. `jarvis-family`'s 34 tests, all
session-scoped on a Postgres pool + JWT keyfile) — have **no**
non-integration tests today. Under the substrate default, the marker
filter excludes every collected test, and `pytest` exits with code 5
("no tests collected"). Without special handling, `bash -e` would
propagate that as a job failure and the substrate's own default would
red-line the repo.

The substrate handles this in TD-X48 v2: pytest is invoked with `set +e`
around it, the exit code is captured, and code 5 is treated as success
with a `::notice::` annotation (visible in the GitHub Actions run UI).
Every other exit code propagates unchanged. Net effect: a repo with
zero unit/contract tests still gets a green substrate `test` job — and
the notice annotation is the operational signal that the suite is
fully integration-deferred and PR-time coverage is therefore lighter
than usual. Repos that *intend* to have unit coverage should treat the
notice as a prompt to add it.

## Why Philosophy B (default-skip)

Two architecturally consistent choices existed at TD-X48 decision time:

- **Philosophy A — substrate runs everything; provision services in CI.**
  The substrate workflow declares Postgres / Redis / etc. service
  containers. Pro: zero per-repo opt-in cost; integration tests run on
  every PR. Con: substrate becomes coupled to whatever infrastructure
  any consumer needs (Postgres version drift, Redis vs Valkey,
  multi-DB-per-repo, etc.). Substrate stops being portable.
- **Philosophy B — substrate runs unit/contract tests only; integration
  is opt-in (chosen).** The substrate is dependency-free at runtime
  beyond Python + uv. Integration tests stay close to the repo that owns
  them and run in a separate workflow (TD-X50, future) under the repo's
  own service-container choices.

Philosophy B keeps the substrate a small, sharp tool: every consuming
repo gets the same fast PR-time signal regardless of what
infrastructure their integration tests need, and integration suites
evolve at the repo's own cadence without dragging the substrate
template along with them.

## Future work

- **TD-X50 (planned):** A reusable workflow `jarvis-standards/.github/workflows/integration.yml`
  that consuming repos call from their own `integration.yml`, providing
  a single place to standardize service-container patterns (Postgres
  major version, Redis vs Valkey, network policy). At that point repos
  with integration tests will have a substrate-blessed path to running
  them on PRs without each repo reinventing the service-container shape.
- **TD-X46 (deferred):** Tombstone or delete `requirements.txt` shims in
  repos that have migrated their runtime deps to `[project.dependencies]`
  per TD-X44 v2 (family) — the dual-source-of-truth shape is a transient
  artifact of the pre-`uv sync` era.
