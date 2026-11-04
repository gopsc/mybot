"""Automatic state extraction for SOUL, USER and STATS prompt layers.

After each conversation turn, lightweight heuristics extract persistent state:
- STATS: cumulative counters, tool usage, error tracking
- USER: language preference, topics of interest, communication style
- SOUL: agent capabilities, behavioral patterns

These updates are automatic and do not require LLM calls or operator approval.
"""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
import json
import re
from typing import Any

MAX_STATS_BYTES = 4096
MAX_USER_BYTES = 8192
MAX_SOUL_BYTES = 8192

CHINESE_PATTERN = re.compile(r"[\u4e00-\u9fff]")
ENGLISH_PATTERN = re.compile(r"[a-zA-Z]{3,}")

TOPIC_KEYWORDS = {
    "hardware": ["硬件", "舵机", "传感器", "I2C", "SPI", "串口", "hardware", "servo", "sensor"],
    "scripting": ["脚本", "动作", ".mt", "结构", ".sql", "script", "action", "structure"],
    "skill": ["技能", "skill", "安装", "install"],
    "web": ["网页", "搜索", "抓取", "web", "search", "fetch", "url"],
    "file": ["文件", "目录", "读取", "写入", "file", "directory", "read", "write"],
    "camera": ["摄像头", "拍照", "图像", "camera", "capture", "image"],
    "shell": ["命令", "终端", "shell", "command", "terminal"],
}


def parse_existing_stats(content: str) -> dict[str, Any]:
    """Parse existing STATS layer content, returning empty dict on failure."""
    if not content or not content.strip():
        return {}
    text = content.strip()
    if text.startswith("# STATS"):
        text = text[len("# STATS"):].strip()
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, ValueError):
        return {}


def merge_stats(existing: dict[str, Any], turn_data: dict[str, Any]) -> dict[str, Any]:
    """Merge new turn data into existing stats, accumulating counters."""
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    stats = dict(existing)

    stats["last_seen"] = now
    stats.setdefault("first_seen", now)
    stats["total_turns"] = stats.get("total_turns", 0) + 1
    stats["total_tool_calls"] = stats.get("total_tool_calls", 0) + turn_data.get("tool_calls", 0)
    stats["total_input_tokens"] = stats.get("total_input_tokens", 0) + turn_data.get("input_tokens", 0)
    stats["total_output_tokens"] = stats.get("total_output_tokens", 0) + turn_data.get("output_tokens", 0)

    if turn_data.get("robot"):
        stats["robot"] = turn_data["robot"]
    if turn_data.get("elapsed_seconds") is not None:
        stats["last_elapsed_seconds"] = turn_data["elapsed_seconds"]
    if turn_data.get("faulted") is not None:
        stats["last_faulted"] = turn_data["faulted"]
    if turn_data.get("last_action"):
        stats["last_action"] = turn_data["last_action"]

    tool_counts = turn_data.get("tool_usage", {})
    if tool_counts:
        existing_tools = stats.get("tool_usage", {})
        if not isinstance(existing_tools, dict):
            existing_tools = {}
        for tool, count in tool_counts.items():
            existing_tools[tool] = existing_tools.get(tool, 0) + count
        stats["tool_usage"] = dict(Counter(existing_tools).most_common(20))

    if turn_data.get("error"):
        errors = stats.get("recent_errors", [])
        errors.append({"time": now, "error": turn_data["error"]})
        stats["recent_errors"] = errors[-5:]

    stats["total_errors"] = stats.get("total_errors", 0) + (1 if turn_data.get("faulted") else 0)

    return stats


def format_stats(stats: dict[str, Any]) -> str:
    """Format stats as Markdown with JSON body."""
    return "# STATS\n\n" + json.dumps(stats, ensure_ascii=False, indent=2) + "\n"


def detect_language(text: str) -> str | None:
    """Detect primary language in text: 'zh', 'en', or None."""
    if not text:
        return None
    chinese_chars = len(CHINESE_PATTERN.findall(text))
    english_words = len(ENGLISH_PATTERN.findall(text))
    if chinese_chars > 0 and chinese_chars > english_words * 0.3:
        return "zh"
    if english_words > 0:
        return "en"
    return None


def extract_topics(text: str) -> list[str]:
    """Extract topic tags from text based on keyword matching."""
    text_lower = text.lower()
    found = []
    for topic, keywords in TOPIC_KEYWORDS.items():
        if any(kw.lower() in text_lower for kw in keywords):
            found.append(topic)
    return found


def parse_existing_user(content: str) -> dict[str, Any]:
    """Parse existing USER layer content, returning empty dict on failure."""
    if not content or not content.strip():
        return {}
    text = content.strip()
    if text.startswith("# USER"):
        text = text[len("# USER"):].strip()
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, ValueError):
        return {}


def update_user_profile(existing: dict[str, Any], messages: list) -> dict[str, Any] | None:
    """Extract user info from messages and merge into existing profile.

    Returns None if no new information was found.
    """
    from langchain_core.messages import HumanMessage
    user_texts = []
    for msg in messages:
        if isinstance(msg, HumanMessage) and msg.content:
            user_texts.append(str(msg.content))

    if not user_texts:
        return None

    combined = " ".join(user_texts)
    profile = dict(existing)
    changed = False

    lang = detect_language(combined)
    if lang:
        langs = profile.get("languages", {})
        if not isinstance(langs, dict):
            langs = {}
        langs[lang] = langs.get(lang, 0) + len(user_texts)
        profile["languages"] = langs
        primary = max(langs, key=langs.get)
        if profile.get("primary_language") != primary:
            profile["primary_language"] = primary
            changed = True

    topics = extract_topics(combined)
    if topics:
        existing_topics = profile.get("topics", {})
        if not isinstance(existing_topics, dict):
            existing_topics = {}
        for topic in topics:
            existing_topics[topic] = existing_topics.get(topic, 0) + 1
        profile["topics"] = dict(Counter(existing_topics).most_common(10))
        changed = True

    avg_length = sum(len(t) for t in user_texts) / len(user_texts)
    if avg_length < 20:
        style = "terse"
    elif avg_length > 100:
        style = "verbose"
    else:
        style = "moderate"
    if profile.get("communication_style") != style:
        profile["communication_style"] = style
        changed = True

    profile["total_messages"] = profile.get("total_messages", 0) + len(user_texts)
    profile["last_active"] = datetime.now(timezone.utc).isoformat(timespec="seconds")

    return profile if changed or not existing else None


def format_user(profile: dict[str, Any]) -> str:
    """Format user profile as Markdown with JSON body."""
    return "# USER\n\n" + json.dumps(profile, ensure_ascii=False, indent=2) + "\n"


def parse_existing_soul(content: str) -> dict[str, Any]:
    """Parse existing SOUL layer content, returning empty dict on failure."""
    if not content or not content.strip():
        return {}
    text = content.strip()
    if text.startswith("# SOUL"):
        text = text[len("# SOUL"):].strip()
    try:
        data = json.loads(text)
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, ValueError):
        return {}


def update_soul_profile(existing: dict[str, Any], messages: list, tool_usage: dict[str, int]) -> dict[str, Any] | None:
    """Extract agent self-awareness from turn and merge into existing profile.

    Returns None if no new information was found.
    """
    from langchain_core.messages import AIMessage, ToolMessage
    profile = dict(existing)
    changed = False

    if tool_usage:
        capabilities = profile.get("capabilities", [])
        if not isinstance(capabilities, list):
            capabilities = []
        tool_names = sorted(tool_usage.keys())
        new_caps = [t for t in tool_names if t not in capabilities]
        if new_caps:
            profile["capabilities"] = sorted(set(capabilities) | set(new_caps))
            changed = True

        primary_tools = Counter(tool_usage).most_common(3)
        primary = [t[0] for t in primary_tools]
        if profile.get("primary_tools") != primary:
            profile["primary_tools"] = primary
            changed = True

    ai_texts = []
    for msg in messages:
        if isinstance(msg, AIMessage) and msg.content:
            ai_texts.append(str(msg.content))

    if ai_texts:
        profile["total_responses"] = profile.get("total_responses", 0) + len(ai_texts)

        tool_calls_count = sum(
            1 for msg in messages
            if isinstance(msg, AIMessage) and getattr(msg, "tool_calls", None)
        )
        profile["total_tool_assists"] = profile.get("total_tool_assists", 0) + tool_calls_count

        changed = True

    tool_results = [msg for msg in messages if isinstance(msg, ToolMessage)]
    if tool_results:
        successes = sum(1 for msg in tool_results
                       if getattr(msg, "status", "") != "error"
                       and '"ok": false' not in str(getattr(msg, "content", "")))
        profile["total_tool_results"] = profile.get("total_tool_results", 0) + len(tool_results)
        profile["total_tool_successes"] = profile.get("total_tool_successes", 0) + successes
        changed = True

    return profile if changed or not existing else None


def format_soul(profile: dict[str, Any]) -> str:
    """Format soul profile as Markdown with JSON body."""
    return "# SOUL\n\n" + json.dumps(profile, ensure_ascii=False, indent=2) + "\n"


def extract_turn_data(messages: list, events: list) -> dict[str, Any]:
    """Extract aggregate data from a turn's messages and events."""
    from langchain_core.messages import AIMessage
    tool_usage: dict[str, int] = {}
    tool_calls = 0
    input_tokens = 0
    output_tokens = 0
    last_action = None
    faulted = False

    for msg in messages:
        if isinstance(msg, AIMessage):
            calls = getattr(msg, "tool_calls", None) or []
            for call in calls:
                name = call.get("name", "unknown")
                tool_usage[name] = tool_usage.get(name, 0) + 1
                tool_calls += 1
            usage = getattr(msg, "usage_metadata", None)
            if isinstance(usage, dict):
                input_tokens += int(usage.get("input_tokens") or 0)
                output_tokens += int(usage.get("output_tokens") or 0)

    for event in events:
        if isinstance(event, dict):
            state = event.get("state", "")
            if state:
                last_action = state
            if event.get("error"):
                faulted = True

    return {
        "tool_calls": tool_calls,
        "tool_usage": tool_usage,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "last_action": last_action,
        "faulted": faulted,
    }
