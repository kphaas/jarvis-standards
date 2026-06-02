# ADR-0021: Model-fit check — validate local-model pins against node hardware

- **Status:** Proposed
- **Date:** 2026-06-01
- **Deciders:** Ken Haas (drafted with Claude Code)
- **Supersedes:** N/A
- **Related:** ADR-0020 (Anti-Slop Engineering Quality Standard, §2 deterministic-gates principle), ADR-0013 (Forge Autonomous-Pass Execution & Merge-Gate), ADR-0003 (Progressive Secrets Management — no IPs in registries), `ports/model_fit.py`

---

## Context

JARVIS pins local models (Ollama / Aider / codegen) in several repos: the Alpha
model registry and `brain/tasks/dispatch.py`, jarvis-financial `config/agents.yaml`,
and the forge codegen config. Each pin assumes the target node can actually run
the model. Nothing checks that assumption. A 30B model pinned to a 16 GB node, or
a 35B MoE pinned to the CPU-only Unraid box, fails at runtime — late, on the node,
where it is most expensive to discover.

We want a single, shared, **deterministic** check that estimates whether a model
fits a node before it is deployed: advisory locally and in Forge preflight,
enforceable in CI for production pins. It must be reproducible (no network, no
LLM in the verdict path), follow the existing `ports/` hexagonal convention, and
add no parallel infrastructure.

A discovery pass over the live repo corrected several assumptions carried in the
task brief: the dual-role principle lives in **ADR-0020 §2** (not the Mattermost
ADR-0015); the repo is Pydantic-free and uses stdlib typing in `ports/`; security
scanning is **detect-secrets + ruff-S** (ADR-0009), not bandit; ADRs use this
bold-field markdown schema, not YAML frontmatter; and there was no prior node
hardware/capability registry (only `node_addresses.py` for IPs, in other repos).

## Decision

Add a model-fit check to `jarvis-standards`, hexagonal and pure-Python by default:

- **Port** — `ports/model_fit.py`: `ModelFitPort` (Protocol), `FitVerdict`
  (frozen `dataclass`, stdlib — consistent with the Pydantic-free ports layer),
  and `FitStatus` (`StrEnum`: `fits` / `tight` / `wont_fit` / `unknown`).
- **Default adapter** — `jarvis_standards/adapters/model_fit/pure_python.py`: a
  unified-memory-aware estimator. Memory sizes on **total** params (MoE included);
  a first-order memory-bandwidth bound estimates throughput on **active** params;
  CPU-only nodes (no Metal) take a slow path with no throughput estimate.
- **Optional adapter** — `llm_checker.py`: a feature-flagged **stub** only. It
  does not shell out, adds no Node/npm dependency, and returns `unknown`. The real
  `npx llm-checker` integration is deferred to a separate PR.
- **Registries** — `registries/node_capabilities.yaml` (capability-only, keyed by
  Tailscale hostname; **no IPs** — those stay in `node_addresses.py`) and
  `registries/model_catalog.yaml` (per-model sizing + a sparse set of production
  assignments so the check is runnable and self-testing).
- **CLI** — `python -m jarvis_standards.checks.model_fit [--node X] [--ctx N]
  [--enforce] [MODEL_REF ...]`.

**Dual-role modes:**

- *Advisory (default):* print the verdict table, **exit 0**. Local use + Forge preflight.
- *Enforce (`--enforce`):* **exit 1** iff a **production-pinned** model `wont_fit`
  its **assigned** node. The verdict is fully deterministic — there is no AI in it —
  so an enforcing CI gate does **not** violate the "AI verdicts never block"
  invariant (ADR-0020 §2). This PR ships the CLI only; wiring `--enforce` into any
  repo's CI is out of scope (separate PR).

**Estimator model** (constants in `pure_python.py`, all tunable):

```
weight_gb = params_total_b * bytes_per_param(quant)     # MoE → TOTAL params
kv_gb     = kv_per_1k_ctx_gb * (ctx_tokens / 1000)
mem_gb    = weight_gb + kv_gb + OVERHEAD_GB
usable_gb = ram_gb - reserved_os_gb                     # unified: no separate VRAM
tps       ≈ mem_bandwidth_gbps / (params_active_b * bytes_per_param)   # MoE → ACTIVE
bands: fits if headroom > 25% · tight if 0–25% · wont_fit if mem > usable
```

`bytes_per_param(q4)=0.6` reflects real Ollama q4_K_M footprints (≈4.5 effective
bits + block scales), not the textbook 0.5 — a correctness choice so verdicts match
observed memory.

## Consequences

### Positive
- One deterministic, reproducible fit check shared across the ecosystem, reusable
  as a CLI today and as a CI gate later.
- Catches infeasible pins before deployment instead of at runtime on the node.
- Establishes the first node **capability** registry (capability-only; addresses
  stay separate per ADR-0003).
- Pure-Python, stdlib-typed, mypy-strict, property-tested — no AI, no network.

### Negative
- Adds one runtime dependency (PyYAML) and two dev dependencies (Hypothesis,
  types-PyYAML) to a deliberately minimal repo.
- Introduces a small runtime package (`jarvis_standards/`) alongside the
  interface-only `ports/`; the repo now ships code, not just interfaces.
- The estimator is first-order; its accuracy depends on hand-maintained seed
  constants and registry data (see Known trade-offs).

### Neutral
- Registries are hand-edited YAML reference data, kept at repo top level, not in code.
- `mypy.files` widened to `["ports", "jarvis_standards"]` so `--strict` actually
  covers the new code.

## Known trade-offs (🟡 — accepted, tracked)

| # | Trade-off |
|---|---|
| **T1** | Estimator constants (`BYTES_PER_PARAM`, `OVERHEAD_GB`, `KV_PER_1K_DEFAULT_GB`, `CPU_TOTAL_LIMIT_B`, per-node `reserved_os_gb` / `mem_bandwidth_gbps`) are **heuristic seeds calibrated to known cases**, not physical guarantees. They are documented and tunable. |
| **T2** | `reserved_os_gb` folds OS **plus always-on resident-tooling headroom** into one number (jarvis-sandbox is seeded higher because Aider + Ollama + Claude Code are co-resident during codegen). There is no live process introspection — this is why qwen3-coder:30b lands `tight`, not `fits`, on sandbox. |
| **T3** | ✅ **Resolved.** Brain RAM **confirmed 128 GB** (Ken, 2026-06-01): the memory doc and the v2 docx agree on 128; Arch Review V1's **192 GB** is the stale outlier and is to be corrected to 128 separately. Registry note settled accordingly. |
| **T4** | The in-repo check validates **catalog ↔ node-assignment seed data only**. The live model pins live in the consuming repos (Alpha registry / dispatch, financial agents.yaml, forge codegen). Cross-repo pin scanning is **future wiring** (out of scope). |
| **T5** | `llm_checker` is a **stub**: no `npx llm-checker` call, no Node dependency, always `unknown`. Real adapter deferred. |
| **T6** | `est_tps` is a coarse memory-bandwidth-bound figure and is `None` on CPU-only nodes — **advisory only**, never a gate input. |

## Sovereignty First compliance

| Component | Tier | Fallback |
|---|---|---|
| Pure-Python estimator (default) | Tier 1 self-hosted, no external calls | None needed — fully local + deterministic |
| PyYAML (registry parsing) | Tier 1 vendored OSS library | stdlib `tomllib` migration possible if dropped |
| `llm_checker` / `npx llm-checker` (future, stubbed) | Tier 3 optional external tool | Pure-Python estimator is always the default backend |

The verdict path has no network and no LLM. The optional `llm-checker` backend is
the only external dependency and is stubbed, disabled by default, and never on the
critical path.

## Alternatives considered

### Option A — Pydantic `FitVerdict`
Rejected. The repo's `ports/` layer is Pydantic-free (TypedDict / Protocol); a
frozen `dataclass` + `StrEnum` matches convention and adds no dependency.

### Option B — `core/ports/` + scattered `adapters/` / `registries/` packages
Rejected. Ports already live at top-level `ports/`; the port stays there. Runtime
code is consolidated under one new package (`jarvis_standards/`) rather than three
new top-level code dirs, to avoid parallel infrastructure.

### Option C — A new `workflow_call` reusable CI workflow this PR
Deferred. The repo propagates **one uniform CI template by file-copy**; there is no
reusable-workflow precedent. Inventing one now would be parallel infra. The CLI ships
first; CI wiring (an optional gated job in the uniform template) is a follow-up.

### Option D — bandit as the security gate
Rejected as a misread of the stack. This repo's security gate is **detect-secrets
+ ruff-S** (ADR-0009); the check is covered by those, not bandit.

## Reversal conditions

1. The estimator's verdicts diverge materially from observed runtime behavior on
   real nodes and recalibrating the seed constants does not close the gap.
2. The node-capability registry drifts out of sync with hardware faster than it can
   be maintained by hand, warranting automated capability discovery.
3. The real `llm-checker` backend proves strictly better and the pure-Python path
   becomes redundant maintenance burden.

## References

- `ports/model_fit.py`, `jarvis_standards/adapters/model_fit/pure_python.py`
- `registries/node_capabilities.yaml`, `registries/model_catalog.yaml`
- `jarvis_standards/checks/model_fit.py`
- ADR-0020 §2 (deterministic gates), ADR-0013 (merge-gate), ADR-0009 (ruff-S), ADR-0003 (secrets / no IPs)
