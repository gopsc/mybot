"""Shared utilities for agent modules.

Small helper functions that were duplicated across agent.py, agent_team.py,
and agent_memory_store.py. Centralised here to avoid drift.
"""
from __future__ import annotations

from langchain_core.messages import AIMessage, AIMessageChunk, HumanMessage, SystemMessage


def clip(text, limit):
    """Truncate *text* to *limit* characters, appending an ellipsis if cut."""
    text = str(text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def message_text(message):
    """Extract the text content from a LangChain message.

    Handles string content, list-of-blocks content (Anthropic format),
    and falls back to ``str(content)`` for anything else.
    """
    content = getattr(message, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text", "")))
        return "".join(parts)
    return str(content or "")
