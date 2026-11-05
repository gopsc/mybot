"""Tests for automatic state extraction (SOUL, USER, STATS layers)."""
import json

import pytest

from pymybot.agent_state import (
    detect_language, extract_topics, extract_turn_data, format_soul, format_stats,
    format_user, merge_stats, parse_existing_soul, parse_existing_stats,
    parse_existing_user, update_soul_profile, update_user_profile,
)


def test_parse_existing_stats_handles_empty():
    assert parse_existing_stats("") == {}
    assert parse_existing_stats("   ") == {}
    assert parse_existing_stats("not json") == {}


def test_parse_existing_stats_extracts_json():
    content = '# STATS\n\n{"total_turns": 5}\n'
    assert parse_existing_stats(content) == {"total_turns": 5}


def test_merge_stats_accumulates_counters():
    existing = {"total_turns": 3, "total_tool_calls": 10, "first_seen": "2024-01-01T00:00:00+00:00"}
    turn = {"tool_calls": 2, "input_tokens": 100, "output_tokens": 50, "robot": "test.sql",
            "elapsed_seconds": 1.5, "faulted": False, "last_action": "done"}
    merged = merge_stats(existing, turn)
    assert merged["total_turns"] == 4
    assert merged["total_tool_calls"] == 12
    assert merged["total_input_tokens"] == 100
    assert merged["total_output_tokens"] == 50
    assert merged["robot"] == "test.sql"
    assert merged["last_elapsed_seconds"] == 1.5
    assert merged["first_seen"] == "2024-01-01T00:00:00+00:00"


def test_merge_stats_tracks_tool_usage():
    existing = {"tool_usage": {"list_files": 3}}
    turn = {"tool_usage": {"list_files": 2, "read_file": 1}, "tool_calls": 3}
    merged = merge_stats(existing, turn)
    assert merged["tool_usage"]["list_files"] == 5
    assert merged["tool_usage"]["read_file"] == 1


def test_merge_stats_keeps_recent_errors():
    existing = {"recent_errors": [{"time": "t1", "error": "e1"}]}
    turn = {"faulted": True, "error": "e2", "tool_calls": 0}
    merged = merge_stats(existing, turn)
    assert len(merged["recent_errors"]) == 2
    assert merged["total_errors"] == 1


def test_merge_stats_survives_operator_edited_non_numeric_fields():
    """Prompt layers are editable; malformed counters must not fail a turn."""
    existing = {"total_turns": "many", "total_errors": None,
                "tool_usage": {"shell": "oops", "read_file": 2},
                "recent_errors": "not-a-list"}
    merged = merge_stats(existing, {"tool_calls": 1, "tool_usage": {"shell": 3},
                                    "error": "boom", "faulted": True})
    assert merged["total_turns"] == 1
    assert merged["total_errors"] == 1
    assert merged["total_tool_calls"] == 1
    assert merged["tool_usage"] == {"shell": 3, "read_file": 2}
    assert len(merged["recent_errors"]) == 1


def test_format_stats_produces_valid_markdown():
    stats = {"total_turns": 5, "robot": "test.sql"}
    formatted = format_stats(stats)
    assert formatted.startswith("# STATS\n\n")
    parsed = json.loads(formatted.replace("# STATS\n\n", "").strip())
    assert parsed == stats


def test_detect_language():
    assert detect_language("你好世界") == "zh"
    assert detect_language("hello world") == "en"
    assert detect_language("混合 mixed 内容") == "zh"
    assert detect_language("") is None
    assert detect_language("ok") is None


def test_extract_topics():
    assert "hardware" in extract_topics("查看硬件状态")
    assert "scripting" in extract_topics("运行脚本 test.mt")
    assert "web" in extract_topics("search the web")
    assert extract_topics("random text") == []


def test_parse_existing_user_handles_empty():
    assert parse_existing_user("") == {}
    assert parse_existing_user("not json") == {}


def test_parse_existing_user_extracts_json():
    content = '# USER\n\n{"primary_language": "zh"}\n'
    assert parse_existing_user(content) == {"primary_language": "zh"}


def test_update_user_profile_extracts_language():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import HumanMessage
    messages = [HumanMessage(content="你好，请帮我查看硬件")]
    profile = update_user_profile({}, messages)
    assert profile is not None
    assert profile["primary_language"] == "zh"
    assert profile["languages"]["zh"] == 1


def test_update_user_profile_extracts_topics():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import HumanMessage
    messages = [HumanMessage(content="请帮我写一个脚本")]
    profile = update_user_profile({}, messages)
    assert profile is not None
    assert "scripting" in profile["topics"]


def test_update_user_profile_detects_style():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import HumanMessage
    messages = [HumanMessage(content="hi")]
    profile = update_user_profile({}, messages)
    assert profile is not None
    assert profile["communication_style"] == "terse"

    messages = [HumanMessage(content="x" * 150)]
    profile = update_user_profile({}, messages)
    assert profile["communication_style"] == "verbose"


def test_update_user_profile_returns_none_when_no_messages():
    assert update_user_profile({}, []) is None


def test_format_user_produces_valid_markdown():
    profile = {"primary_language": "zh", "topics": {"hardware": 3}}
    formatted = format_user(profile)
    assert formatted.startswith("# USER\n\n")
    parsed = json.loads(formatted.replace("# USER\n\n", "").strip())
    assert parsed == profile


def test_parse_existing_soul_handles_empty():
    assert parse_existing_soul("") == {}
    assert parse_existing_soul("not json") == {}


def test_parse_existing_soul_extracts_json():
    content = '# SOUL\n\n{"capabilities": ["list_files"]}\n'
    assert parse_existing_soul(content) == {"capabilities": ["list_files"]}


def test_update_soul_profile_tracks_capabilities():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import AIMessage
    messages = [AIMessage(content="ok", tool_calls=[{"name": "list_files", "args": {}, "id": "1"}])]
    profile = update_soul_profile({}, messages, {"list_files": 1})
    assert profile is not None
    assert "list_files" in profile["capabilities"]
    assert profile["primary_tools"] == ["list_files"]


def test_update_soul_profile_counts_responses():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import AIMessage
    messages = [AIMessage(content="first"), AIMessage(content="second")]
    profile = update_soul_profile({}, messages, {})
    assert profile is not None
    assert profile["total_responses"] == 2


def test_update_soul_profile_tracks_tool_results():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import ToolMessage
    messages = [ToolMessage(content='{"ok": true}', tool_call_id="1"),
                ToolMessage(content='{"ok": false}', tool_call_id="2", status="error")]
    profile = update_soul_profile({}, messages, {})
    assert profile is not None
    assert profile["total_tool_results"] == 2
    assert profile["total_tool_successes"] == 1


def test_format_soul_produces_valid_markdown():
    profile = {"capabilities": ["list_files"], "total_responses": 5}
    formatted = format_soul(profile)
    assert formatted.startswith("# SOUL\n\n")
    parsed = json.loads(formatted.replace("# SOUL\n\n", "").strip())
    assert parsed == profile


def test_extract_turn_data_aggregates():
    pytest.importorskip("langchain_core")
    from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
    messages = [
        HumanMessage(content="hi"),
        AIMessage(content="", tool_calls=[{"name": "list_files", "args": {}, "id": "1"}]),
        ToolMessage(content='{"ok": true}', tool_call_id="1"),
        AIMessage(content="done"),
    ]
    events = [{"tool": "list_files", "state": "completed"}]
    data = extract_turn_data(messages, events)
    assert data["tool_calls"] == 1
    assert data["tool_usage"] == {"list_files": 1}
    assert data["last_action"] == "completed"
    assert data["faulted"] is False


def test_extract_turn_data_detects_fault():
    events = [{"tool": "run_skill", "state": "failed", "error": "timeout"}]
    data = extract_turn_data([], events)
    assert data["faulted"] is True
