"""Provider-independent, conservative request-token estimation.

This is a guardrail rather than a provider tokenizer: serialized UTF-8 bytes are
rounded up at three bytes per token, with per-message overhead. The explicit
reserve in AgentConfig covers provider formatting and estimation differences.
"""
from __future__ import annotations

from dataclasses import asdict, is_dataclass
import json

MESSAGE_TOKEN_OVERHEAD = 4

SUMMARY_PROMPT_LIMIT = 80
SUMMARY_RESPONSE_LIMIT = 120


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


def _truncate(text, limit):
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    return text[:limit - 1] + "…"


def _tool_result_ok(tool_message):
    content = getattr(tool_message, "content", "") or ""
    status = getattr(tool_message, "status", "") or ""
    if isinstance(status, str) and status.lower() == "error":
        return False
    if isinstance(content, str):
        stripped = content.strip()
        if '"ok": false' in stripped or '"ok":false' in stripped or '"error"' in stripped:
            return False
    return True


def summarize_turn(turn, turn_index=None):
    """Extract a compact summary string from a turn's messages.

    A turn is a list of LangChain messages: HumanMessage, AIMessage (with or
    without tool_calls), ToolMessage. The summary captures the user prompt,
    each tool call with its outcome, and the final assistant response.
    """
    from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

    user_prompt = ""
    tool_calls = []
    response = ""
    pending_calls = {}

    for message in turn:
        if isinstance(message, HumanMessage):
            user_prompt = _truncate(str(message.content), SUMMARY_PROMPT_LIMIT)
        elif isinstance(message, AIMessage):
            calls = getattr(message, "tool_calls", None) or []
            for call in calls:
                name = call.get("name", "unknown")
                pending_calls[call.get("id", "")] = name
            text = _truncate(str(message.content), SUMMARY_RESPONSE_LIMIT)
            if text and not calls:
                response = text
        elif isinstance(message, ToolMessage):
            call_id = getattr(message, "tool_call_id", "") or ""
            name = pending_calls.pop(call_id, getattr(message, "name", "unknown"))
            ok = _tool_result_ok(message)
            tool_calls.append(f"{name}({'✓' if ok else '✗'})")

    prefix = f"[Turn {turn_index}] " if turn_index is not None else ""
    parts = []
    if user_prompt:
        parts.append(f"用户: {user_prompt}")
    if tool_calls:
        parts.append(f"工具: {', '.join(tool_calls)}")
    if response:
        parts.append(f"回复: {response}")
    if not parts:
        return ""
    return prefix + ". ".join(parts)


def aggregate_cold(summaries, turn_count=None):
    """Merge individual warm summaries into a single cold-tier aggregate."""
    if not summaries and not turn_count:
        return None
    total = turn_count if turn_count is not None else len(summaries)
    tool_tokens = []
    for summary in summaries:
        if "工具: " in summary:
            segment = summary.split("工具: ", 1)[1]
            if ". " in segment:
                segment = segment.split(". ")[0]
            tool_tokens.append(segment)
    all_tools = ", ".join(tool_tokens) if tool_tokens else ""
    parts = [f"[历史 {total} 轮]"]
    if all_tools:
        parts.append(f"工具调用: {all_tools}")
    return " ".join(parts)
