"""ModelFitPort — canonical interface for local-model / hardware fit checks.

A model-fit check answers one question deterministically: *will this local
model run on this node, and roughly how well?* It is the hardware-feasibility
analogue of a cost-guard — a pure, reproducible estimate over a model catalog
and a node-capability registry, with no network and no LLM in the path.

Dual-role (ADR-0020 §2, ADR-0013):
  * Advisory by default — print a verdict table, never block.
  * Deterministic enough to gate CI under ``--enforce`` for production-pinned
    models. This is a *deterministic* gate, so it does not violate the
    "AI verdicts never block" invariant — there is no AI in the verdict.

Note: this module deliberately does NOT use ``from __future__ import
annotations`` so that ``FitVerdict.__annotations__`` and the Protocol store
real type objects (not strings). The shape test in
tests/test_model_fit_port.py inspects ``__annotations__`` directly, mirroring
the convention established in ports/llm.py.
"""

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol, runtime_checkable


class FitStatus(StrEnum):
    """How a model fits a node.

    Ordering note: ``UNKNOWN`` is distinct from a fit failure. It means the
    estimator lacked the inputs to decide (missing node or catalog data), and
    must never be treated as either a pass or a hard fail by an enforcing gate.
    """

    FITS = "fits"
    TIGHT = "tight"
    WONT_FIT = "wont_fit"
    UNKNOWN = "unknown"


@dataclass(frozen=True, slots=True)
class FitVerdict:
    """Result of one (model, node) fit check.

    All memory figures are in gibibyte-scale GB as produced by the estimator
    (see adapters/model_fit/pure_python.py for the exact definitions). ``est_tps``
    is a coarse advisory throughput estimate and is ``None`` on CPU-only nodes.
    """

    model_ref: str
    node: str
    status: FitStatus
    est_mem_gb: float
    est_tps: float | None
    ctx_max: int
    reason: str


@runtime_checkable
class ModelFitPort(Protocol):
    """Canonical port for model/hardware fit estimation.

    Implementations MUST be pure and deterministic: given the same registries
    and arguments, ``check`` returns an identical ``FitVerdict`` every time.
    No network, no subprocess to a remote, no LLM.
    """

    name: str

    def check(self, model_ref: str, node: str, ctx_tokens: int = 8192) -> FitVerdict:
        """Estimate whether ``model_ref`` fits ``node`` at ``ctx_tokens`` context.

        Returns a ``FitVerdict`` with ``status=UNKNOWN`` (never raises) when the
        model or node is absent from the registries, so callers can render a
        full table without special-casing missing data.
        """
        ...
