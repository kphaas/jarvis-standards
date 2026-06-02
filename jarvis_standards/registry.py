"""Loaders for the node-capability and model-catalog registries.

Pure I/O + validation. Returns frozen dataclasses so the estimator can rely on
fully-typed, immutable inputs (mypy --strict). No defaults are invented for
*required* fields — a malformed registry fails loudly rather than silently
producing a wrong fit verdict.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# Registry data lives at the repo top level (alongside this package), not
# inside it — it is hand-edited reference data, not code.
_REGISTRY_DIR = Path(__file__).resolve().parent.parent / "registries"
DEFAULT_NODES_PATH = _REGISTRY_DIR / "node_capabilities.yaml"
DEFAULT_CATALOG_PATH = _REGISTRY_DIR / "model_catalog.yaml"


class RegistryError(ValueError):
    """A registry file is missing, malformed, or has an invalid field."""


@dataclass(frozen=True, slots=True)
class NodeCapability:
    """One node's hardware capability (capability-only; no network address)."""

    hostname: str
    chip: str
    ram_gb: float
    reserved_os_gb: float
    mem_bandwidth_gbps: float
    unified: bool
    metal: bool
    ollama_native: bool

    @property
    def usable_gb(self) -> float:
        """Unified memory available to models = RAM minus reserved headroom."""
        return self.ram_gb - self.reserved_os_gb


@dataclass(frozen=True, slots=True)
class ModelSpec:
    """One catalogued model's sizing + optional production assignment."""

    model_ref: str
    params_total_b: float
    params_active_b: float
    quant: str
    ctx_max: int
    kv_per_1k_ctx_gb: float | None
    notes: str
    assigned_node: str | None
    production: bool


@dataclass(frozen=True, slots=True)
class Registry:
    """Resolved view over both registries."""

    nodes: dict[str, NodeCapability]
    models: dict[str, ModelSpec]

    def get_node(self, hostname: str) -> NodeCapability | None:
        return self.nodes.get(hostname)

    def get_model(self, model_ref: str) -> ModelSpec | None:
        return self.models.get(model_ref)

    def production_pins(self) -> list[ModelSpec]:
        """Models flagged ``production: true`` with an ``assigned_node``.

        These are the only entries an enforcing gate (``--enforce``) considers.
        """
        return [m for m in self.models.values() if m.production and m.assigned_node is not None]


def _require(mapping: dict[str, Any], key: str, where: str) -> Any:
    if key not in mapping:
        raise RegistryError(f"{where}: missing required field '{key}'")
    return mapping[key]


def _as_float(value: Any, key: str, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RegistryError(f"{where}: field '{key}' must be a number, got {value!r}")
    return float(value)


def _as_int(value: Any, key: str, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RegistryError(f"{where}: field '{key}' must be an integer, got {value!r}")
    return value


def _as_bool(value: Any, key: str, where: str) -> bool:
    if not isinstance(value, bool):
        raise RegistryError(f"{where}: field '{key}' must be a boolean, got {value!r}")
    return value


def _load_yaml_mapping(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise RegistryError(f"registry file not found: {path}")
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise RegistryError(f"{path}: top level must be a mapping, got {type(raw).__name__}")
    return raw


def load_nodes(path: Path = DEFAULT_NODES_PATH) -> dict[str, NodeCapability]:
    raw = _load_yaml_mapping(path)
    nodes: dict[str, NodeCapability] = {}
    for hostname, body in raw.items():
        where = f"{path.name}[{hostname}]"
        if not isinstance(body, dict):
            raise RegistryError(f"{where}: entry must be a mapping")
        nodes[hostname] = NodeCapability(
            hostname=hostname,
            chip=str(_require(body, "chip", where)),
            ram_gb=_as_float(_require(body, "ram_gb", where), "ram_gb", where),
            reserved_os_gb=_as_float(
                _require(body, "reserved_os_gb", where), "reserved_os_gb", where
            ),
            mem_bandwidth_gbps=_as_float(
                _require(body, "mem_bandwidth_gbps", where), "mem_bandwidth_gbps", where
            ),
            unified=_as_bool(_require(body, "unified", where), "unified", where),
            metal=_as_bool(_require(body, "metal", where), "metal", where),
            ollama_native=_as_bool(_require(body, "ollama_native", where), "ollama_native", where),
        )
    return nodes


def load_models(path: Path = DEFAULT_CATALOG_PATH) -> dict[str, ModelSpec]:
    raw = _load_yaml_mapping(path)
    models: dict[str, ModelSpec] = {}
    for model_ref, body in raw.items():
        where = f"{path.name}[{model_ref}]"
        if not isinstance(body, dict):
            raise RegistryError(f"{where}: entry must be a mapping")
        kv_raw = body.get("kv_per_1k_ctx_gb")
        assigned = body.get("assigned_node")
        models[model_ref] = ModelSpec(
            model_ref=model_ref,
            params_total_b=_as_float(
                _require(body, "params_total_b", where), "params_total_b", where
            ),
            params_active_b=_as_float(
                _require(body, "params_active_b", where), "params_active_b", where
            ),
            quant=str(_require(body, "quant", where)),
            ctx_max=_as_int(_require(body, "ctx_max", where), "ctx_max", where),
            kv_per_1k_ctx_gb=(
                None if kv_raw is None else _as_float(kv_raw, "kv_per_1k_ctx_gb", where)
            ),
            notes=str(body.get("notes", "")),
            assigned_node=None if assigned is None else str(assigned),
            production=_as_bool(body.get("production", False), "production", where),
        )
    return models


def load_registry(
    nodes_path: Path = DEFAULT_NODES_PATH,
    catalog_path: Path = DEFAULT_CATALOG_PATH,
) -> Registry:
    return Registry(nodes=load_nodes(nodes_path), models=load_models(catalog_path))
