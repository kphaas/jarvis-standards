"""Unit tests for the pure-Python estimator, registries, and the CLI."""

from __future__ import annotations

from jarvis_standards.adapters.model_fit.llm_checker import LlmCheckerModelFit
from jarvis_standards.adapters.model_fit.pure_python import (
    PurePythonModelFit,
    bytes_per_param,
    estimate_memory_gb,
)
from jarvis_standards.checks import model_fit as cli
from jarvis_standards.registry import (
    ModelSpec,
    NodeCapability,
    Registry,
    load_registry,
)
from ports.model_fit import FitStatus, ModelFitPort


def _node(
    hostname: str, ram: float, reserved: float, *, metal: bool, bw: float = 200.0
) -> NodeCapability:
    return NodeCapability(
        hostname=hostname,
        chip="test",
        ram_gb=ram,
        reserved_os_gb=reserved,
        mem_bandwidth_gbps=bw,
        unified=True,
        metal=metal,
        ollama_native=False,
    )


def _model(
    ref: str,
    total: float,
    active: float,
    *,
    assigned: str | None = None,
    production: bool = False,
) -> ModelSpec:
    return ModelSpec(
        model_ref=ref,
        params_total_b=total,
        params_active_b=active,
        quant="q4",
        ctx_max=8192,
        kv_per_1k_ctx_gb=None,
        notes="",
        assigned_node=assigned,
        production=production,
    )


# ── registry loading ────────────────────────────────────────────────────


def test_default_registry_loads_and_has_seeds() -> None:
    reg = load_registry()
    assert "jarvis-brain" in reg.nodes
    assert "qwen3-coder:30b" in reg.models
    # Brain seeded conservatively at 128 GB (ADR-0021 T3).
    assert reg.nodes["jarvis-brain"].ram_gb == 128
    # Three seeded production pins.
    assert len(reg.production_pins()) == 3


def test_pure_python_satisfies_port_protocol() -> None:
    port: ModelFitPort = PurePythonModelFit(load_registry())
    assert isinstance(port, ModelFitPort)


# ── documented verification cases ───────────────────────────────────────


def test_verify_qwen3_coder_30b_tight_on_sandbox() -> None:
    port = PurePythonModelFit(load_registry())
    v = port.check("qwen3-coder:30b", "jarvis-sandbox")
    assert v.status is FitStatus.TIGHT, v.reason
    assert v.est_tps is not None  # Metal node → has a throughput estimate


def test_verify_qwen3_6_moe_wont_fit_cpu_unraid() -> None:
    port = PurePythonModelFit(load_registry())
    v = port.check("qwen3.6:35b-a3b", "unraid")
    assert v.status is FitStatus.WONT_FIT, v.reason
    assert v.est_tps is None  # CPU-only → no throughput estimate
    assert "CPU-only" in v.reason


# ── estimator behavior ──────────────────────────────────────────────────


def test_moe_memory_sizes_on_total_not_active() -> None:
    reg = Registry(
        nodes={"big": _node("big", 64, 4, metal=True)},
        models={
            "moe": _model("moe", total=35, active=3),
            "dense": _model("dense", total=35, active=35),
        },
    )
    port = PurePythonModelFit(reg)
    moe = port.check("moe", "big")
    dense = port.check("dense", "big")
    # Same total → identical memory; active params change only throughput.
    assert moe.est_mem_gb == dense.est_mem_gb
    assert moe.est_tps is not None and dense.est_tps is not None
    assert moe.est_tps > dense.est_tps


def test_unknown_model_and_node_are_unknown_not_crash() -> None:
    port = PurePythonModelFit(load_registry())
    assert port.check("does-not-exist", "jarvis-brain").status is FitStatus.UNKNOWN
    assert port.check("qwen3-coder:30b", "nowhere").status is FitStatus.UNKNOWN


def test_bytes_per_param_unknown_quant_is_none() -> None:
    assert bytes_per_param("q4") == 0.6
    assert bytes_per_param("q3_k_xxl") is None


def test_memory_includes_kv_growth_with_context() -> None:
    small = estimate_memory_gb(8, 0.6, 0.12, 1000)
    large = estimate_memory_gb(8, 0.6, 0.12, 100_000)
    assert large > small


# ── llm_checker stub ────────────────────────────────────────────────────


def test_llm_checker_stub_returns_unknown() -> None:
    port = LlmCheckerModelFit(load_registry())
    v = port.check("qwen3-coder:30b", "jarvis-sandbox")
    assert v.status is FitStatus.UNKNOWN
    assert "stub" in v.reason.lower()


# ── CLI / enforce ────────────────────────────────────────────────────────


def test_run_advisory_default_targets_production_pins() -> None:
    code, verdicts = cli.run([], None, 8192, enforce=False)
    assert code == 0
    assert {v.model_ref for v in verdicts} == {
        "llama3.1:8b",
        "qwen2.5-coder:7b",
        "qwen3-coder:30b",
    }


def test_run_enforce_passes_on_seed_data() -> None:
    code, _ = cli.run([], None, 8192, enforce=True)
    assert code == 0  # no seeded production pin wont_fit its node


def test_run_enforce_fails_when_pin_wont_fit() -> None:
    reg = Registry(
        nodes={"tiny": _node("tiny", 8, 2, metal=True)},
        models={"big": _model("big", total=30, active=30, assigned="tiny", production=True)},
    )
    code, _ = cli.run([], None, 8192, enforce=True, registry=reg)
    assert code == 1


def test_run_node_selects_all_models_on_node() -> None:
    code, verdicts = cli.run([], "jarvis-brain", 8192, enforce=False)
    assert code == 0
    assert len(verdicts) == len(load_registry().models)


def test_main_advisory_exits_zero(capsys) -> None:  # type: ignore[no-untyped-def]
    rc = cli.main(["--node", "jarvis-sandbox", "qwen3-coder:30b"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "qwen3-coder:30b" in out
    assert "tight" in out
