"""Shape tests for the ModelFitPort interface (mirrors test_ports_protocol.py)."""

from __future__ import annotations

from inspect import iscoroutinefunction

from ports import FitStatus, FitVerdict, ModelFitPort
from ports.model_fit import ModelFitPort as DirectPort


def test_fit_status_members() -> None:
    expected = {"FITS", "TIGHT", "WONT_FIT", "UNKNOWN"}
    actual = {m for m in dir(FitStatus) if not m.startswith("_")}
    assert expected <= actual, f"FitStatus missing members: {expected - actual}"
    assert FitStatus.FITS.value == "fits"
    assert FitStatus.WONT_FIT.value == "wont_fit"


def test_fit_verdict_fields_declared() -> None:
    expected = {
        "model_ref": str,
        "node": str,
        "status": FitStatus,
        "est_mem_gb": float,
        "ctx_max": int,
        "reason": str,
    }
    actual = FitVerdict.__annotations__
    for name, typ in expected.items():
        assert name in actual, f"FitVerdict missing field: {name}"
        assert actual[name] is typ, f"FitVerdict.{name} should be {typ}, got {actual[name]}"


def test_fit_verdict_is_frozen() -> None:
    v = FitVerdict("m", "n", FitStatus.FITS, 1.0, None, 8192, "ok")
    try:
        v.status = FitStatus.TIGHT  # type: ignore[misc]
    except AttributeError:
        return
    raise AssertionError("FitVerdict must be frozen")


def test_model_fit_port_check_present_and_sync() -> None:
    assert hasattr(ModelFitPort, "check")
    assert ModelFitPort is DirectPort
    assert not iscoroutinefunction(ModelFitPort.check), "check must be sync (deterministic)"
