"""Provider-independent, conservative request-token estimation.

This is a guardrail rather than a provider tokenizer: serialized UTF-8 bytes are
rounded up at three bytes per token, with per-message overhead. The explicit
reserve in AgentConfig covers provider formatting and estimation differences.
"""
from __future__ import annotations

from dataclasses import asdict, is_dataclass
import json

from pydantic_ai.messages import ModelMessagesTypeAdapter

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


def estimate_request_tokens(request_context):
    """Estimate input messages, instructions and tool schemas for one request."""
    parameters = request_context.model_request_parameters
    metadata = {
        "instructions": [getattr(part, "content", str(part))
                         for part in parameters.instruction_parts or []],
        "function_tools": parameters.function_tools,
        "output_tools": parameters.output_tools,
        "native_tools": parameters.native_tools,
        "prompted_output_template": parameters.prompted_output_template,
    }
    messages = ModelMessagesTypeAdapter.dump_json(request_context.messages)
    metadata_json = json.dumps(metadata, ensure_ascii=False, default=_json_default,
                               separators=(",", ":")).encode("utf-8")
    return (estimate_tokens(messages) + estimate_tokens(metadata_json)
            + MESSAGE_TOKEN_OVERHEAD * len(request_context.messages))
