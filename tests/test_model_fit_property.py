"""Hypothesis property tests for the estimator's invariants.

These encode the estimator's contract independent of any specific numbers:
  * memory is never negative for non-negative inputs;
  * memory is monotonic non-decreasing in params and in context;
  * MoE memory sizes on TOTAL params, never on active.
"""

from __future__ import annotations

from hypothesis import given
from hypothesis import strategies as st

from jarvis_standards.adapters.model_fit.pure_python import (
    PurePythonModelFit,
    estimate_memory_gb,
)
from jarvis_standards.registry import ModelSpec, NodeCapability, Registry

_params = st.floats(min_value=0.0, max_value=500.0, allow_nan=False, allow_infinity=False)
_bpp = st.floats(min_value=0.1, max_value=2.0, allow_nan=False, allow_infinity=False)
_kv = st.floats(min_value=0.0, max_value=4.0, allow_nan=False, allow_infinity=False)
_ctx = st.integers(min_value=0, max_value=2_000_000)


@given(p=_params, bpp=_bpp, kv=_kv, ctx=_ctx)
def test_memory_never_negative(p: float, bpp: float, kv: float, ctx: int) -> None:
    assert estimate_memory_gb(p, bpp, kv, ctx) >= 0.0


@given(
    p1=_params,
    delta=st.floats(min_value=0.0, max_value=500.0, allow_nan=False, allow_infinity=False),
    bpp=_bpp,
    kv=_kv,
    ctx=_ctx,
)
def test_memory_monotonic_in_params(
    p1: float, delta: float, bpp: float, kv: float, ctx: int
) -> None:
    lo = estimate_memory_gb(p1, bpp, kv, ctx)
    hi = estimate_memory_gb(p1 + delta, bpp, kv, ctx)
    assert hi >= lo


@given(
    p=_params,
    bpp=_bpp,
    kv=_kv,
    ctx1=_ctx,
    grow=st.integers(min_value=0, max_value=2_000_000),
)
def test_memory_monotonic_in_context(p: float, bpp: float, kv: float, ctx1: int, grow: int) -> None:
    lo = estimate_memory_gb(p, bpp, kv, ctx1)
    hi = estimate_memory_gb(p, bpp, kv, ctx1 + grow)
    assert hi >= lo


@given(
    total=st.floats(min_value=1.0, max_value=200.0, allow_nan=False, allow_infinity=False),
    active_a=st.floats(min_value=0.1, max_value=200.0, allow_nan=False, allow_infinity=False),
    active_b=st.floats(min_value=0.1, max_value=200.0, allow_nan=False, allow_infinity=False),
)
def test_moe_memory_depends_only_on_total(total: float, active_a: float, active_b: float) -> None:
    # Cap active at total so both specs are physically valid MoE configs.
    aa = min(active_a, total)
    ab = min(active_b, total)
    node = NodeCapability(
        hostname="big",
        chip="t",
        ram_gb=1024.0,
        reserved_os_gb=8.0,
        mem_bandwidth_gbps=400.0,
        unified=True,
        metal=True,
        ollama_native=False,
    )

    def spec(ref: str, active: float) -> ModelSpec:
        return ModelSpec(ref, total, active, "q4", 8192, None, "", None, False)

    reg = Registry(nodes={"big": node}, models={"a": spec("a", aa), "b": spec("b", ab)})
    port = PurePythonModelFit(reg)
    assert port.check("a", "big").est_mem_gb == port.check("b", "big").est_mem_gb
