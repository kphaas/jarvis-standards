"""AlphaPort — canonical interface to Alpha Brain.

Used by Alpha consumers (Medical, Family, Financial, Council) to interact
with Brain's memory tiers, local LLM (Buddy), and family-tile JWT minting.

Security invariants (enforced by adapter implementations):
  * mTLS required: no plain HTTP, no ``verify=False``.
  * Service keys load from ``~/jarvis/.secrets/`` (chmod 600).
  * Connection failures raise ``AlphaConnectionError`` — never silent fallback.
  * JWKS endpoint is configurable.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal, Protocol, TypedDict, runtime_checkable

MemoryTier = Literal["working", "episodic", "semantic"]


class Memory(TypedDict):
    """A single memory record returned by ``recall()``."""

    memory_id: str
    namespace: str
    tier: MemoryTier
    content: str
    similarity: float
    created_at: datetime
    metadata: dict[str, str]


class BuddyResponse(TypedDict):
    """Response from Buddy (Brain-local LLM) invocation."""

    text: str
    model: str
    tokens_in: int
    tokens_out: int
    cost_usd: Decimal
    latency_ms: int


class TileTokenScope(TypedDict):
    """Scope embedded in a family-tile JWT."""

    family_member_id: str
    capabilities: list[str]
    audience: str


@runtime_checkable
class AlphaPort(Protocol):
    """Canonical port for Alpha Brain interactions."""

    async def remember(
        self,
        content: str,
        namespace: str,
        tier: MemoryTier = "working",
        metadata: dict[str, str] | None = None,
    ) -> str:
        """Write a memory record. Returns memory_id."""
        ...

    async def recall(
        self,
        query: str,
        namespace: str,
        top_k: int = 5,
        tier_filter: MemoryTier | None = None,
    ) -> list[Memory]:
        """Retrieve memories by semantic similarity."""
        ...

    async def ask_buddy(
        self,
        prompt: str,
        context: list[str] | None = None,
        max_tokens: int = 1024,
    ) -> BuddyResponse:
        """Invoke Brain-local LLM (Buddy) for a single completion."""
        ...

    async def mint_tile_token(
        self,
        scope: TileTokenScope,
        ttl_sec: int = 900,
    ) -> str:
        """Mint a short-lived JWT for an iframe-embedded family tile."""
        ...
