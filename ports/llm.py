"""LLMPort — canonical adapter interface for LLM providers.

Security invariants (enforced by adapter implementations):
  * No prompt/response content logged outside the consumer's audit_log table.
  * No response cached to disk without explicit cacheable=True flag.
  * No PHI in raised exceptions — sanitize before bubbling.
  * BAA gate: adapters requiring BAA refuse instantiation if baa_verified=False.

Note: this module does NOT use ``from __future__ import annotations`` so that
``LLMPort.__annotations__`` stores real type objects (not strings). The shape
test in tests/test_ports_protocol.py inspects __annotations__ to assert the
required ``name``/``requires_baa`` attributes exist with the right types.
"""

from decimal import Decimal
from typing import Any, Protocol, TypedDict, runtime_checkable


class ChatMessage(TypedDict):
    """One message in a chat sequence."""

    role: str
    content: str


class Completion(TypedDict):
    """Single-shot completion result."""

    text: str
    model: str
    tokens_in: int
    tokens_out: int
    cost_usd: Decimal
    finish_reason: str


class ChatResponse(TypedDict):
    """Multi-turn chat response."""

    message: ChatMessage
    model: str
    tokens_in: int
    tokens_out: int
    cost_usd: Decimal
    finish_reason: str
    tool_calls: list[dict[str, Any]] | None


@runtime_checkable
class LLMPort(Protocol):
    """Canonical port for LLM invocations."""

    name: str
    requires_baa: bool

    async def complete(
        self,
        prompt: str,
        max_tokens: int = 1024,
        temperature: float = 0.7,
        cacheable: bool = False,
    ) -> Completion:
        """Single-shot completion."""
        ...

    async def chat(
        self,
        messages: list[ChatMessage],
        max_tokens: int = 1024,
        temperature: float = 0.7,
        tools: list[dict[str, Any]] | None = None,
        cacheable: bool = False,
    ) -> ChatResponse:
        """Multi-turn chat."""
        ...

    def estimate_cost(
        self,
        prompt_tokens: int,
        completion_tokens: int,
    ) -> Decimal:
        """Estimate cost in USD. Used by cost-guard."""
        ...


@runtime_checkable
class AdapterRegistry(Protocol):
    """Resolves named LLM adapters from config."""

    def get(self, name: str) -> LLMPort:
        """Return the adapter for name."""
        ...

    def register(self, adapter: LLMPort) -> None:
        """Register an adapter. Idempotent by adapter.name."""
        ...
