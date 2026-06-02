"""Standards ports — canonical interfaces shared across jarvis-* modules."""

from .alpha import (
    AlphaPort,
    BuddyResponse,
    Memory,
    MemoryTier,
    TileTokenScope,
)
from .exceptions import (
    AlphaAuthError,
    AlphaConnectionError,
    AlphaError,
    AlphaTimeoutError,
    BAAGateError,
    LLMAdapterNotFoundError,
    LLMCostCapError,
    LLMError,
    LLMTimeoutError,
    PortError,
)
from .llm import (
    AdapterRegistry,
    ChatMessage,
    ChatResponse,
    Completion,
    LLMPort,
)
from .model_fit import (
    FitStatus,
    FitVerdict,
    ModelFitPort,
)

__all__ = [
    "AdapterRegistry",
    "AlphaAuthError",
    "AlphaConnectionError",
    "AlphaError",
    "AlphaPort",
    "AlphaTimeoutError",
    "BAAGateError",
    "BuddyResponse",
    "ChatMessage",
    "ChatResponse",
    "Completion",
    "FitStatus",
    "FitVerdict",
    "LLMAdapterNotFoundError",
    "LLMCostCapError",
    "LLMError",
    "LLMPort",
    "LLMTimeoutError",
    "Memory",
    "MemoryTier",
    "ModelFitPort",
    "PortError",
    "TileTokenScope",
]
