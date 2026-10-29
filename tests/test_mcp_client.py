"""MCP client configuration and the agent's approval-gated external tools."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import threading

import pytest

pytest.importorskip("mcp")
pytest.importorskip("pydantic_ai")

from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.models.function import FunctionModel

from pymybot.agent import AgentConfig, AgentSession
from pymybot.cli import main
from pymybot.mcp_client import McpConfigError, load_servers

ROOT = Path(__file__).resolve().parents[1]

SERVER_SCRIPT = '''
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:  # MCP SDK 2.x renamed FastMCP to MCPServer.
    from mcp.server.mcpserver import MCPServer as FastMCP

mcp = FastMCP("demo")


@mcp.tool()
def echo(text: str) -> str:
    """Echo one string."""
    return "echo:" + text


@mcp.tool()
def blob(size: int) -> str:
    """Return a large string."""
    return "x" * size


@mcp.tool()
def boom() -> str:
    """Always fail on the server."""
    raise RuntimeError("synthetic server failure")


if __name__ == "__main__":
    mcp.run(transport="stdio")
'''


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    for key in list(os.environ):
        if key.startswith(("BOT4CJ_", "MYBOT_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_")):
            monkeypatch.delenv(key)
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")
    from pydantic_ai import models
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)


class FakeExecutor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.closed = False

    async def start(self, *, deadline=None):
        return {"robot": "test", "hardware": []}

    async def call(self, name, arguments, *, timeout):
        return {"ok": True, "executed": False, "state": "completed", "data": {}}

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        self.closed = True


def write_config(tmp_path, servers):
    path = tmp_path / "mcp.json"
    path.write_text(json.dumps({"mcpServers": servers}), encoding="utf-8")
    return path


def demo_config(tmp_path):
    script = tmp_path / "demo_server.py"
    script.write_text(SERVER_SCRIPT, encoding="utf-8")
    return write_config(tmp_path, {"demo": {"command": sys.executable, "args": [str(script)]}})


def test_load_servers_expands_environment_and_normalizes(tmp_path, monkeypatch):
    monkeypatch.setenv("DEMO_TOKEN", "s3cret")
    path = write_config(tmp_path, {"demo": {
        "command": "python", "args": ["-m", "demo", "${DEMO_TOKEN}", "${MISSING:-fallback}"],
        "env": {"TOKEN": "${DEMO_TOKEN}"}, "cwd": "."}})
    loaded = load_servers(path)
    assert len(loaded) == 1
    servers = loaded[0]
    assert servers.name == "demo" and servers.command == "python"
    assert servers.args == ("-m", "demo", "s3cret", "fallback")
    assert servers.env == {"TOKEN": "s3cret"}
    assert Path(servers.cwd) == tmp_path.resolve()


def test_load_servers_rejects_unsafe_or_incomplete_entries(tmp_path, monkeypatch):
    monkeypatch.delenv("DEMO_TOKEN", raising=False)
    cases = [
        {"demo": {"url": "https://example.invalid"}},
        {"demo": {"args": []}},
        {"demo": {"command": ""}},
        {"demo": {"command": "python", "args": "not-a-list"}},
        {"demo": {"command": "python", "env": {"1BAD": "x"}}},
        {"demo": {"command": "python", "args": ["${DEMO_TOKEN}"]}},
        {"demo": {"command": "python", "cwd": "does-not-exist"}},
        {"bad name!": {"command": "python"}},
        {"demo": {"command": "python"}, "DEMO": {"command": "python"}},
    ]
    for payload in cases:
        path = write_config(tmp_path, payload)
        with pytest.raises(McpConfigError):
            load_servers(path)


def test_load_servers_rejects_malformed_documents(tmp_path):
    for text in ("not json", "[]", "{}", '{"mcpServers": []}', '{"mcpServers": {}}'):
        path = tmp_path / "mcp.json"
        path.write_text(text, encoding="utf-8")
        with pytest.raises(McpConfigError):
            load_servers(path)
    with pytest.raises(McpConfigError):
        load_servers(tmp_path / "missing.json")


def run_turn(tmp_path, *, confirm=None, allow=False, tool_suffix="echo",
             arguments=None):
    servers = load_servers(demo_config(tmp_path))

    async def respond(messages, info):
        if any(isinstance(part, ToolReturnPart) for message in messages for part in message.parts):
            return ModelResponse(parts=[TextPart("done")])
        names = [tool.name for tool in info.function_tools]
        name = next(item for item in names if item.endswith(tool_suffix))
        payload = arguments if arguments is not None else {"text": "hi"}
        return ModelResponse(parts=[ToolCallPart(name, payload, "call-1")])

    async def scenario():
        session = AgentSession(FakeExecutor(), FunctionModel(respond),
                               AgentConfig(allow_mcp_tools=allow), confirm=confirm,
                               mcp_servers=servers)
        try:
            result = await session.ask("use the external tool")
            return result, session.events
        finally:
            await session.close()

    return asyncio.run(scenario())


def test_approved_mcp_tool_executes_and_is_recorded(tmp_path):
    approvals = []

    async def confirm(name, arguments):
        approvals.append((name, arguments))
        return True

    result, events = run_turn(tmp_path, confirm=confirm)
    assert result["output"] == "done"
    assert approvals and approvals[0][0] == "mcp:demo_echo"
    assert events == [{"tool": "demo_echo", "ok": True, "executed": True, "state": "completed"}]


def test_denied_mcp_tool_never_runs(tmp_path):
    calls = []

    async def confirm(name, arguments):
        calls.append(name)
        return False

    result, events = run_turn(tmp_path, confirm=confirm)
    assert result["output"] == "done"
    assert calls == ["mcp:demo_echo"]
    assert events[0]["tool"] == "demo_echo"
    assert events[0]["ok"] is False and events[0]["state"] == "not_executed"
    assert "approval denied" in events[0]["error"]


def test_preapproved_mcp_tools_run_without_a_prompt(tmp_path):
    result, events = run_turn(tmp_path, confirm=None, allow=True)
    assert result["output"] == "done"
    assert events == [{"tool": "demo_echo", "ok": True, "executed": True, "state": "completed"}]


def test_large_mcp_results_are_bounded(tmp_path):
    servers = load_servers(demo_config(tmp_path))
    receipts = []

    async def respond(messages, info):
        if any(isinstance(part, ToolReturnPart) for message in messages for part in message.parts):
            return ModelResponse(parts=[TextPart("done")])
        name = next(tool.name for tool in info.function_tools if tool.name.endswith("blob"))
        return ModelResponse(parts=[ToolCallPart(name, {"size": 200_000}, "call-1")])

    async def scenario():
        session = AgentSession(FakeExecutor(), FunctionModel(respond),
                               AgentConfig(allow_mcp_tools=True), mcp_servers=servers)
        try:
            await session.ask("blob")
            receipts.extend(part.content for message in session.turns[0]
                            for part in message.parts if isinstance(part, ToolReturnPart))
        finally:
            await session.close()

    asyncio.run(scenario())
    assert receipts and len(receipts[0]) < 40_000
    assert "chars]" in receipts[0]


def test_mcp_server_failures_are_reported_as_unknown(tmp_path):
    result, events = run_turn(tmp_path, allow=True, tool_suffix="boom", arguments={})
    assert result["output"] == "done"
    assert events == [{"tool": "demo_boom", "ok": False, "executed": True, "state": "unknown"}]


def test_cli_rejects_mcp_flags_without_a_configuration(capsys):
    code = main(["--no-gui", "agent", "--robot", str(ROOT / "robots/relay-test.sql"),
                 "--task", "list hardware", "--allow-mcp-tools"])
    assert code == 2
    assert "--allow-mcp-tools requires --mcp-config" in capsys.readouterr().err


def test_cli_rejects_invalid_history_and_mcp_configuration(tmp_path, capsys):
    code = main(["--no-gui", "agent", "--robot", str(ROOT / "robots/relay-test.sql"),
                 "--task", "list hardware", "--history-turns", "0"])
    assert code == 2
    assert "history-turns" in capsys.readouterr().err

    bad = tmp_path / "mcp.json"
    bad.write_text('{"mcpServers": {"demo": {"url": "https://example.invalid"}}}', encoding="utf-8")
    code = main(["--no-gui", "agent", "--robot", str(ROOT / "robots/relay-test.sql"),
                 "--task", "list hardware", "--mcp-config", str(bad)])
    captured = capsys.readouterr()
    assert code == 1
    payload = json.loads(captured.out)
    assert payload["error"]["type"] == "AgentConfigurationError"
    assert "no model request was sent" in payload["error"]["message"]
