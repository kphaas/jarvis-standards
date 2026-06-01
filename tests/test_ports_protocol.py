"""Protocol shape tests — ensures ports are importable and structurally complete."""

from __future__ import annotations

from inspect import iscoroutinefunction

from ports import AdapterRegistry, AlphaPort, LLMPort


def test_alpha_port_methods_present() -> None:
    expected = {"remember", "recall", "ask_buddy", "mint_tile_token"}
    actual = {m for m in dir(AlphaPort) if not m.startswith("_")}
    missing = expected - actual
    assert not missing, f"AlphaPort missing methods: {missing}"


def test_alpha_port_methods_async() -> None:
    for method_name in ("remember", "recall", "ask_buddy", "mint_tile_token"):
        method = getattr(AlphaPort, method_name)
        assert iscoroutinefunction(method), f"AlphaPort.{method_name} must be async"


def test_llm_port_methods_present() -> None:
    expected = {"complete", "chat", "estimate_cost"}
    actual = {
        m for m in dir(LLMPort) if not m.startswith("_") and callable(getattr(LLMPort, m, None))
    }
    missing = expected - actual
    assert not missing, f"LLMPort missing methods: {missing}"


def test_llm_port_required_attributes_declared() -> None:
    expected = {"name": str, "requires_baa": bool}
    actual = LLMPort.__annotations__
    for attr_name, attr_type in expected.items():
        assert attr_name in actual, f"LLMPort missing annotation: {attr_name}"
        assert actual[attr_name] is attr_type, (
            f"LLMPort.{attr_name} should be {attr_type}, got {actual[attr_name]}"
        )


def test_llm_port_async_methods() -> None:
    for method_name in ("complete", "chat"):
        method = getattr(LLMPort, method_name)
        assert iscoroutinefunction(method), f"LLMPort.{method_name} must be async"


def test_llm_port_estimate_cost_is_sync() -> None:
    method = getattr(LLMPort, "estimate_cost")
    assert not iscoroutinefunction(method), "estimate_cost must be sync"


def test_adapter_registry_methods_present() -> None:
    expected = {"get", "register"}
    actual = {m for m in dir(AdapterRegistry) if not m.startswith("_")}
    missing = expected - actual
    assert not missing, f"AdapterRegistry missing methods: {missing}"
