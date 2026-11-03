"""Provider-independent, conservative request-token estimation.

This is a guardrail rather than a provider tokenizer: serialized UTF-8 bytes are
rounded up at three bytes per token, with per-message overhead. The explicit
reserve in AgentConfig covers provider formatting and estimation differences.
"""
from __future__ import annotations

from dataclasses import asdict, is_dataclass
import json

MESSAGE_TOKEN_OVERHEAD = 4


def estimate_tokens(data):
    """Conservatively estimate tokens in text or its UTF-8 JSON representation."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return (len(data) + 2) // 3


def _json_default(value):
    if is_dataclass(value):
        return asdict(value)
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    return str(value)


def _tool_metadata(tools):
    return [{"name": getattr(tool, "name", ""), "description": getattr(tool, "description", ""),
             "args": getattr(tool, "args", {})} for tool in tools or ()]


def estimate_request_tokens(messages, tools=()):
    """Estimate input messages and tool schemas for one request."""
    payload = []
    for message in messages:
        payload.append({
            "type": getattr(message, "type", type(message).__name__),
            "content": getattr(message, "content", ""),
            "tool_calls": getattr(message, "tool_calls", None),
            "tool_call_id": getattr(message, "tool_call_id", None),
        })
    serialized = json.dumps(payload, ensure_ascii=False, default=_json_default,
                            separators=(",", ":")).encode("utf-8")
    metadata = json.dumps(_tool_metadata(tools), ensure_ascii=False,
                          default=_json_default, separators=(",", ":")).encode("utf-8")
    return (estimate_tokens(serialized) + estimate_tokens(metadata)
            + MESSAGE_TOKEN_OVERHEAD * len(payload))
