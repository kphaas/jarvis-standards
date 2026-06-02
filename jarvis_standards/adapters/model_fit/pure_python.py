"""Pure-Python model-fit estimator — the DEFAULT ModelFitPort adapter.

Deterministic, dependency-free (beyond the registry loader), no network, no
LLM. Given a model spec and a node capability, it estimates resident memory and
a coarse throughput figure, then bands the result into a FitStatus.

All tuning constants below are HEURISTIC SEEDS, not physical guarantees
(ADR-0021 T1). They are calibrated so the two documented verification cases
hold (qwen3-coder:30b → tight on jarvis-sandbox; qwen3.6:35b-a3b → wont_fit on
unraid). Adjust the constants or the registries to recalibrate — the math is
intentionally simple and first-order.

Memory model (unified memory; Apple Silicon has no separate VRAM pool):
    weight_gb = params_total_b * bytes_per_param(quant)        # MoE: TOTAL params
    kv_gb     = kv_per_1k_ctx_gb * (ctx_tokens / 1000)
    mem_gb    = weight_gb + kv_gb + OVERHEAD_GB
    usable_gb = ram_gb - reserved_os_gb

Throughput model (memory-bandwidth-bound decode, first-order):
    tps ≈ mem_bandwidth_gbps / (params_active_b * bytes_per_param)   # MoE: ACTIVE
    CPU-only nodes (metal=false): tps is None (impractical to estimate usefully).
"""

from __future__ import annotations

from jarvis_standards.registry import (
    DEFAULT_CATALOG_PATH,
    DEFAULT_NODES_PATH,
    ModelSpec,
    NodeCapability,
    Registry,
    load_registry,
)
from ports.model_fit import FitStatus, FitVerdict

# Effective bytes per parameter by quantization. q4 is 0.6 (not the textbook
# 0.5) to reflect real Ollama q4_K_M footprints, which carry ~4.5 effective
# bits plus block scales — a correctness fix (#2) over the naive 4-bit figure.
BYTES_PER_PARAM: dict[str, float] = {
    "q4": 0.6,
    "q5": 0.65,
    "q6": 0.75,
    "q8": 1.0,
    "f16": 2.0,
}

OVERHEAD_GB = 1.0
"""Fixed runtime/framework overhead (weights buffers, runner, graph)."""

KV_PER_1K_DEFAULT_GB = 0.12
"""Default KV-cache GB per 1k context tokens when a model omits its own value."""

CPU_TOTAL_LIMIT_B = 13.0
"""On a CPU-only node, models larger than this are marked wont_fit: even when
they fit in RAM, decode throughput is impractical for interactive use."""

FITS_HEADROOM = 0.25
"""Fractional headroom over usable memory above which a model `fits`; 0..this
band is `tight`; negative headroom (mem > usable) is `wont_fit`."""


def bytes_per_param(quant: str) -> float | None:
    """Effective bytes/param for a quant tag, or None if unrecognized."""
    return BYTES_PER_PARAM.get(quant.lower())


def estimate_memory_gb(
    params_total_b: float,
    bpp: float,
    kv_per_1k_ctx_gb: float,
    ctx_tokens: int,
) -> float:
    """Resident memory estimate in GB. Pure; total over MoE params.

    Monotonic non-decreasing in ``params_total_b`` and ``ctx_tokens``; never
    negative for non-negative inputs (enforced by the property tests).
    """
    ctx = max(0, ctx_tokens)
    weight_gb = params_total_b * bpp
    kv_gb = kv_per_1k_ctx_gb * (ctx / 1000.0)
    return weight_gb + kv_gb + OVERHEAD_GB


def estimate_tps(params_active_b: float, bpp: float, node: NodeCapability) -> float | None:
    """Coarse tokens/sec estimate, or None on CPU-only nodes.

    First-order memory-bandwidth bound: bandwidth divided by the bytes that
    must be read per token. Uses ACTIVE params, so MoE models estimate fast.
    """
    if not node.metal:
        return None
    active_weight_gb = params_active_b * bpp
    if active_weight_gb <= 0:
        return None
    return node.mem_bandwidth_gbps / active_weight_gb


def _kv_per_1k(spec: ModelSpec) -> float:
    return spec.kv_per_1k_ctx_gb if spec.kv_per_1k_ctx_gb is not None else KV_PER_1K_DEFAULT_GB


class PurePythonModelFit:
    """Default, deterministic ModelFitPort implementation (see ports.model_fit)."""

    name = "pure_python"

    def __init__(self, registry: Registry | None = None) -> None:
        self._registry = (
            registry
            if registry is not None
            else load_registry(DEFAULT_NODES_PATH, DEFAULT_CATALOG_PATH)
        )

    @property
    def registry(self) -> Registry:
        return self._registry

    def check(self, model_ref: str, node: str, ctx_tokens: int = 8192) -> FitVerdict:
        spec = self._registry.get_model(model_ref)
        node_cap = self._registry.get_node(node)

        if spec is None:
            return _unknown(model_ref, node, ctx_tokens, f"model '{model_ref}' not in catalog")
        if node_cap is None:
            return _unknown(model_ref, node, spec.ctx_max, f"node '{node}' not in registry")

        bpp = bytes_per_param(spec.quant)
        if bpp is None:
            return _unknown(
                model_ref, node, spec.ctx_max, f"unknown quant '{spec.quant}' for {model_ref}"
            )

        mem_gb = estimate_memory_gb(spec.params_total_b, bpp, _kv_per_1k(spec), ctx_tokens)
        tps = estimate_tps(spec.params_active_b, bpp, node_cap)
        usable = node_cap.usable_gb
        moe = spec.params_active_b < spec.params_total_b

        status, reason = _band(mem_gb, usable, node_cap, spec, moe)

        return FitVerdict(
            model_ref=model_ref,
            node=node,
            status=status,
            est_mem_gb=round(mem_gb, 2),
            est_tps=None if tps is None else round(tps, 1),
            ctx_max=spec.ctx_max,
            reason=reason,
        )


def _band(
    mem_gb: float,
    usable: float,
    node: NodeCapability,
    spec: ModelSpec,
    moe: bool,
) -> tuple[FitStatus, str]:
    moe_note = (
        f" MoE: sized on {spec.params_total_b}b total, speed on {spec.params_active_b}b active."
        if moe
        else ""
    )

    # Memory is the hard wall regardless of CPU/GPU.
    if usable <= 0:
        return (
            FitStatus.WONT_FIT,
            f"misconfigured node: reserved_os_gb >= ram_gb (usable {usable:.1f} GB).{moe_note}",
        )
    if mem_gb > usable:
        return (
            FitStatus.WONT_FIT,
            f"needs ~{mem_gb:.1f} GB > {usable:.1f} GB usable on {node.hostname}.{moe_note}",
        )

    # CPU-only overlay: fits in RAM but too large for practical CPU decode.
    if not node.metal and spec.params_total_b > CPU_TOTAL_LIMIT_B:
        return (
            FitStatus.WONT_FIT,
            (
                f"CPU-only node (no Metal): {spec.params_total_b}b exceeds the "
                f"{CPU_TOTAL_LIMIT_B:.0f}b practical CPU limit; fits in RAM "
                f"(~{mem_gb:.1f}/{usable:.1f} GB) but decode is impractical.{moe_note}"
            ),
        )

    headroom = (usable - mem_gb) / usable
    cpu_note = "" if node.metal else " CPU-only (no Metal): expect slow decode."
    if headroom > FITS_HEADROOM:
        return (
            FitStatus.FITS,
            (
                f"~{mem_gb:.1f} GB of {usable:.1f} GB usable "
                f"({headroom * 100:.0f}% headroom).{cpu_note}{moe_note}"
            ),
        )
    return (
        FitStatus.TIGHT,
        (
            f"~{mem_gb:.1f} GB of {usable:.1f} GB usable "
            f"({headroom * 100:.0f}% headroom — tight).{cpu_note}{moe_note}"
        ),
    )


def _unknown(model_ref: str, node: str, ctx_max: int, reason: str) -> FitVerdict:
    return FitVerdict(
        model_ref=model_ref,
        node=node,
        status=FitStatus.UNKNOWN,
        est_mem_gb=0.0,
        est_tps=None,
        ctx_max=ctx_max,
        reason=reason,
    )
