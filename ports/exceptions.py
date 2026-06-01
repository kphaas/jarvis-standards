"""Exceptions for Alpha and LLM ports.

Adapters MUST raise these (or subclasses) rather than provider-specific
exceptions. This isolates consumers from provider churn and keeps audit
trails uniform across modules.
"""

from __future__ import annotations


class PortError(Exception):
    """Base for all port-layer errors."""


# Alpha ----------------------------------------------------------------


class AlphaError(PortError):
    """Base for AlphaPort errors."""


class AlphaConnectionError(AlphaError):
    """Transport/mTLS failure communicating with Brain. Never silent fallback."""


class AlphaAuthError(AlphaError):
    """JWT or JWKS validation failure."""


class AlphaTimeoutError(AlphaError):
    """Brain did not respond within the configured timeout."""


# LLM ------------------------------------------------------------------


class LLMError(PortError):
    """Base for LLMPort errors."""


class LLMAdapterNotFoundError(LLMError):
    """Adapter name not present in the registry."""


class BAAGateError(LLMError):
    """Adapter requires BAA but baa_verified=False on consumer config."""


class LLMTimeoutError(LLMError):
    """Adapter exceeded its configured timeout."""


class LLMCostCapError(LLMError):
    """Pre-call cost estimate exceeds the configured cap."""
