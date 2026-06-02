"""Model-fit check CLI — scan model/node pairs, report fit, optionally enforce.

Usage:
    python -m jarvis_standards.checks.model_fit [--node HOST] [--ctx N]
                                                [--enforce] [MODEL_REF ...]

Modes (dual-role, ADR-0020 §2 / ADR-0013):
    advisory (default)  print a verdict table, exit 0. Local + Forge preflight.
    --enforce           exit 1 iff a production-pinned model `wont_fit` its
                        assigned node. Deterministic gate — no AI in the verdict,
                        so it does not violate "AI verdicts never block".

Target selection:
    --node + refs   each ref on that node.
    --node only     every catalogued model on that node.
    refs only       each ref on its catalogue `assigned_node`.
    neither         every production pin on its assigned node (assignment audit).

Backend is the pure-Python estimator by default; set
JARVIS_MODEL_FIT_BACKEND=llm_checker to select the (stub) llm-checker adapter.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence

from jarvis_standards.adapters.model_fit.llm_checker import LlmCheckerModelFit
from jarvis_standards.adapters.model_fit.pure_python import PurePythonModelFit
from jarvis_standards.registry import Registry, load_registry
from ports.model_fit import FitStatus, FitVerdict, ModelFitPort

_ENV_BACKEND = "JARVIS_MODEL_FIT_BACKEND"


def select_backend(registry: Registry, backend: str | None = None) -> ModelFitPort:
    """Resolve the ModelFitPort adapter from an explicit name or the env flag."""
    name = backend if backend is not None else os.environ.get(_ENV_BACKEND, "pure_python")
    if name == "llm_checker":
        return LlmCheckerModelFit(registry)
    if name == "pure_python":
        return PurePythonModelFit(registry)
    raise SystemExit(f"unknown {_ENV_BACKEND}='{name}' (expected pure_python | llm_checker)")


def select_targets(
    registry: Registry, model_refs: Sequence[str], node: str | None
) -> list[tuple[str, str]]:
    """Resolve (model_ref, node) pairs to check from the CLI selection."""
    if node is not None:
        refs = list(model_refs) if model_refs else list(registry.models)
        return [(ref, node) for ref in refs]

    if model_refs:
        targets: list[tuple[str, str]] = []
        for ref in model_refs:
            spec = registry.get_model(ref)
            if spec is None or spec.assigned_node is None:
                # Unknown model, or no assignment and no --node to fall back on.
                # Pair it with a sentinel so the verdict row reports UNKNOWN.
                targets.append((ref, "<unassigned>"))
            else:
                targets.append((ref, spec.assigned_node))
        return targets

    return [(m.model_ref, m.assigned_node or "<unassigned>") for m in registry.production_pins()]


def _format_table(verdicts: list[FitVerdict]) -> str:
    headers = ("MODEL", "NODE", "STATUS", "MEM_GB", "TPS", "CTX_MAX", "REASON")
    rows: list[tuple[str, ...]] = [headers]
    for v in verdicts:
        rows.append(
            (
                v.model_ref,
                v.node,
                v.status.value,
                f"{v.est_mem_gb:.1f}",
                "—" if v.est_tps is None else f"{v.est_tps:.0f}",
                str(v.ctx_max),
                v.reason,
            )
        )
    # Width per column from the non-reason fields; reason is free-flowing last.
    fixed = len(headers) - 1
    widths = [max(len(r[i]) for r in rows) for i in range(fixed)]
    lines = []
    for r in rows:
        cells = [r[i].ljust(widths[i]) for i in range(fixed)]
        cells.append(r[fixed])
        lines.append("  ".join(cells))
    return "\n".join(lines)


def run(
    model_refs: Sequence[str],
    node: str | None,
    ctx_tokens: int,
    enforce: bool,
    backend: str | None = None,
    registry: Registry | None = None,
) -> tuple[int, list[FitVerdict]]:
    """Execute the check. Returns (exit_code, verdicts). Pure of argv/printing."""
    reg = registry if registry is not None else load_registry()
    port = select_backend(reg, backend)

    targets = select_targets(reg, model_refs, node)
    verdicts = [port.check(ref, host, ctx_tokens) for ref, host in targets]

    exit_code = 0
    if enforce:
        # The gate set is the production pins on their assigned nodes, regardless
        # of the display selection — enforcement must not be silently narrowed.
        gate = [
            port.check(m.model_ref, m.assigned_node or "<unassigned>", ctx_tokens)
            for m in reg.production_pins()
        ]
        if any(v.status is FitStatus.WONT_FIT for v in gate):
            exit_code = 1
    return exit_code, verdicts


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m jarvis_standards.checks.model_fit",
        description="Validate local-model pins against node hardware (advisory by default).",
    )
    parser.add_argument(
        "model_refs", nargs="*", help="model refs to check (default: production pins)"
    )
    parser.add_argument("--node", help="check the given node (Tailscale hostname)")
    parser.add_argument("--ctx", type=int, default=8192, help="context tokens (default 8192)")
    parser.add_argument(
        "--enforce",
        action="store_true",
        help="exit 1 if any production-pinned model wont_fit its assigned node",
    )
    args = parser.parse_args(argv)

    exit_code, verdicts = run(args.model_refs, args.node, args.ctx, args.enforce)

    if not verdicts:
        print("model-fit: no targets selected (no production pins, no --node, no refs).")
    else:
        print(_format_table(verdicts))

    if args.enforce:
        failed = [v for v in verdicts if v.status is FitStatus.WONT_FIT]
        if exit_code != 0:
            print(
                f"\nmodel-fit: ENFORCE FAIL — {len(failed) or 'one or more'} "
                "production-pinned model(s) wont_fit their assigned node.",
                file=sys.stderr,
            )
        else:
            print("\nmodel-fit: enforce OK — no production pin wont_fit its node.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
