"""llm_checker adapter — STUB ONLY (ADR-0021 T5).

The intended implementation shells out to the Node tool ``npx llm-checker`` and
parses its JSON to produce a FitVerdict, giving a second, independent opinion
to cross-check the pure-Python estimator. That is deferred to a separate PR.

This PR ships the stub deliberately WITHOUT a subprocess call and WITHOUT adding
any Node/npm dependency to the project: it must not silently shell out, and it
must keep the secret/static-analysis scans clean. It is reachable only behind
an explicit feature flag and always returns an honest UNKNOWN verdict.

Enable (once implemented) via:  JARVIS_MODEL_FIT_BACKEND=llm_checker
"""

from __future__ import annotations

from jarvis_standards.registry import Registry
from ports.model_fit import FitStatus, FitVerdict

BACKEND_NAME = "llm_checker"

_STUB_REASON = (
    "llm_checker backend is a stub (ADR-0021 T5): the `npx llm-checker` "
    "integration is not implemented yet. Use the default pure_python backend."
)


class LlmCheckerModelFit:
    """Feature-flagged stub ModelFitPort. Never shells out; always UNKNOWN."""

    name = BACKEND_NAME

    def __init__(self, registry: Registry | None = None) -> None:
        # Registry accepted for interface symmetry with the real adapter; the
        # stub does not read it.
        self._registry = registry

    def check(self, model_ref: str, node: str, ctx_tokens: int = 8192) -> FitVerdict:
        spec = self._registry.get_model(model_ref) if self._registry is not None else None
        ctx_max = spec.ctx_max if spec is not None else ctx_tokens
        return FitVerdict(
            model_ref=model_ref,
            node=node,
            status=FitStatus.UNKNOWN,
            est_mem_gb=0.0,
            est_tps=None,
            ctx_max=ctx_max,
            reason=_STUB_REASON,
        )
