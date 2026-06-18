from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "contracts" / "ask_surfaces.v1.json"
STANDARD_PATH = ROOT / "docs" / "ASK_SOURCE_OF_TRUTH.md"
ADR_PATH = ROOT / "docs" / "adr" / "ADR-0024-ask-source-of-truth-boundaries.md"


def load_contract() -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(CONTRACT_PATH.read_text(encoding="utf-8")))


def surface_by_id(contract: dict[str, Any], surface_id: str) -> dict[str, Any]:
    surfaces = contract["surfaces"]
    matches = [surface for surface in surfaces if surface["id"] == surface_id]
    assert len(matches) == 1
    return cast(dict[str, Any], matches[0])


def test_ask_contract_declares_two_canonical_surfaces() -> None:
    contract = load_contract()

    assert contract["schema_version"] == 1
    assert contract["contract_id"] == "jarvis.ask-surfaces"
    assert {surface["id"] for surface in contract["surfaces"]} == {
        "operator-ask",
        "family-safe-ask",
    }


def test_operator_ask_preserves_helm_alpha_path() -> None:
    operator = surface_by_id(load_contract(), "operator-ask")

    assert operator["owner_repo"] == "jarvis-helm"
    assert operator["backend_repo"] == "jarvis-alpha"
    assert operator["route"] == "/ask"
    assert "src/ask/AskWorkspace.tsx" in operator["frontend_entrypoints"]
    assert "src/ask/alphaAskClient.ts" in operator["frontend_entrypoints"]
    assert "/v1/chat/completions" in operator["backend_endpoints"]
    assert "/v1/threads" in operator["backend_endpoints"]
    assert "/v1/memory/semantic" in operator["backend_endpoints"]
    assert "internet modes none, web_search, and deep_research" in operator["preserve_capabilities"]
    assert (
        "Beacon evidence metadata, source quality, citations, and raw web isolation"
        in operator["preserve_capabilities"]
    )
    assert "family member role routing" in operator["must_not_absorb"]


def test_family_safe_ask_preserves_safety_and_documents() -> None:
    family = surface_by_id(load_contract(), "family-safe-ask")

    assert family["owner_repo"] == "jarvis-family"
    assert family["backend_repo"] == "jarvis-family"
    assert family["route"] == "/ask"
    assert "ui/src/components/ask/AskChat.tsx" in family["frontend_entrypoints"]
    assert "/v1/ask" in family["backend_endpoints"]
    assert "/v1/ask/stream" in family["backend_endpoints"]
    assert "input safety assessment before model calls" in family["preserve_capabilities"]
    assert "child answer filtering after model calls" in family["preserve_capabilities"]
    assert "parent-only family document source retrieval" in family["preserve_capabilities"]
    assert "Beacon deep research evidence" in family["must_not_absorb"]


def test_alpha_is_not_an_ask_frontend_owner() -> None:
    contract = load_contract()
    alpha = next(item for item in contract["non_owner_repos"] if item["repo"] == "jarvis-alpha")

    assert "backend API provider for operator Ask" in alpha["allowed_roles"]
    assert "status or handoff link to Helm" in alpha["allowed_roles"]
    assert "standalone Ask frontend" in alpha["forbidden_roles"]
    assert "third chat composer" in alpha["forbidden_roles"]


def test_docs_and_adr_point_to_contract() -> None:
    standard = STANDARD_PATH.read_text(encoding="utf-8")
    adr = ADR_PATH.read_text(encoding="utf-8")

    assert "contracts/ask_surfaces.v1.json" in standard
    assert "Do not add a full Ask UI to Alpha." in standard
    assert "Helm Operator Ask" in standard
    assert "Family Safe Ask" in standard
    assert "Status:** Accepted" in adr
    assert "jarvis-helm` as the source of truth for operator Ask" in adr
    assert "jarvis-family` as the source of truth for family-safe Ask" in adr
