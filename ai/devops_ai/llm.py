"""Thin wrapper around the Claude API for schema-constrained outputs.

Every call returns a validated Pydantic object or raises LLMUnavailable, and
every caller has a deterministic fallback. A missing key, an outage or a
refusal therefore degrades the feature but never blocks a deployment.
"""

from __future__ import annotations

import logging
import os
from typing import TypeVar

from pydantic import BaseModel

log = logging.getLogger(__name__)

T = TypeVar("T", bound=BaseModel)

DEFAULT_MODEL = "claude-opus-5-5"


class LLMUnavailable(RuntimeError):
    """The model could not produce a usable answer; callers must fall back."""


def model_name() -> str:
    return os.getenv("DEVOPS_AI_MODEL", DEFAULT_MODEL)


def ai_enabled() -> bool:
    if os.getenv("DEVOPS_AI_OFFLINE", "").lower() in {"1", "true", "yes"}:
        return False
    return bool(os.getenv("ANTHROPIC_API_KEY") or os.getenv("ANTHROPIC_AUTH_TOKEN"))


def structured(
    *,
    system: str,
    prompt: str,
    schema: type[T],
    effort: str = "medium",
    max_tokens: int = 16000,
) -> T:
    """Ask Claude for an answer that must validate against `schema`."""
    if not ai_enabled():
        raise LLMUnavailable("AI disabled (no ANTHROPIC_API_KEY or DEVOPS_AI_OFFLINE=1)")

    import anthropic
    from pydantic import ValidationError

    client = anthropic.Anthropic(max_retries=3, timeout=180.0)
    try:
        response = client.beta.messages.parse(
            model=model_name(),
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": prompt}],
            output_format=schema,
            thinking={"type": "adaptive"},
            output_config={"effort": effort},
            # If a safety classifier declines, the API retries on a fallback model in the same call.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except ValidationError as exc:
        # Schema constraints the API can't enforce (ranges, cross-field rules) are checked locally.
        raise LLMUnavailable(f"response failed validation: {exc.error_count()} error(s)") from exc
    except anthropic.AuthenticationError as exc:
        raise LLMUnavailable(f"authentication failed: {exc}") from exc
    except anthropic.BadRequestError as exc:
        raise LLMUnavailable(f"bad request: {exc.message}") from exc
    except anthropic.RateLimitError as exc:
        raise LLMUnavailable("rate limited after retries") from exc
    except anthropic.APIStatusError as exc:
        raise LLMUnavailable(f"API error {exc.status_code}") from exc
    except anthropic.APIConnectionError as exc:
        raise LLMUnavailable(f"connection error: {exc}") from exc

    if response.stop_reason == "refusal":
        raise LLMUnavailable("model declined the request")
    if response.stop_reason == "max_tokens":
        raise LLMUnavailable("response truncated at max_tokens")
    parsed = response.parsed_output
    if parsed is None:
        raise LLMUnavailable("response did not match schema")
    log.info(
        "llm call ok model=%s in=%s out=%s",
        response.model,
        response.usage.input_tokens,
        response.usage.output_tokens,
    )
    return parsed
