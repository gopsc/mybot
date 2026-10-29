"""Real stdio MCP clients exercise the controller without external hardware."""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import timedelta
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import pytest

pytest.importorskip("mcp")

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]


def _read_timeout(seconds):
    """MCP SDK 2.x takes seconds; 1.x takes a timedelta."""
    try:
        major = int(importlib.metadata.version("mcp").split(".", 1)[0])
    except (importlib.metadata.PackageNotFoundError, ValueError):
        major = 1
    return seconds if major >= 2 else timedelta(seconds=seconds)


TOOLS = {"get_status", "list_hardware", "list_action_scripts", "read_action_script",
         "query_sql", "run_action_script", "read_variables", "capture_image", "deactivate"}


def command(robot=None, scripts=None, extra=()):
    return ["-m", "pymybot", "mcp", "--robot", str(robot or ROOT / "robots/relay-test.sql"),
            "--scripts-dir", str(scripts or ROOT / "scripts"), *extra]


@asynccontextmanager
async def client(tmp_path, *, robot=None, scripts=None, extra=(), env=None):
    params = StdioServerParameters(command=sys.executable, args=command(robot, scripts, extra),
                                   cwd=tmp_path, env={"PYTHONPATH": str(ROOT), **(env or {})})
    with tempfile.TemporaryFile(mode="w+t") as errors:
        async with stdio_client(params, errlog=errors) as streams:
            async with ClientSession(*streams, read_timeout_seconds=_read_timeout(20)) as session:
                await session.initialize()
                yield session


def data(result):
    assert result.structuredContent is not None
    assert json.loads(result.content[0].text) == result.structuredContent
    return result.structuredContent


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    for key in list(os.environ):
        if key.startswith(("BOT4CJ_", "MYBOT_")):
            monkeypatch.delenv(key)
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")


def test_standard_discovery_and_static_resources(tmp_path):
    async def scenario():
        async with client(tmp_path) as session:
            tools = (await session.list_tools()).tools
            assert {tool.name for tool in tools} == TOOLS
            for tool in tools:
                assert tool.inputSchema["additionalProperties"] is False
                assert tool.outputSchema["required"] == ["ok", "executed", "state"]
            definitions = {tool.name: tool for tool in tools}
            assert definitions["list_hardware"].annotations.readOnlyHint is True
            assert definitions["read_variables"].annotations.readOnlyHint is False
            assert definitions["deactivate"].annotations.destructiveHint is False
            hardware = data(await session.call_tool("list_hardware", {}))
            assert hardware["ok"] and not hardware["executed"]
            assert {item["name"] for item in hardware["data"]["hardware"]} == {"timer-0", "relay0"}
            result = data(await session.call_tool("query_sql", {"sql": "SHOW TABLES;"}))
            assert "Relay" in result["data"]["output"]
            script = data(await session.call_tool("read_action_script", {"script": "relay-test.mt"}))
            assert "@Action" in script["data"]["content"]
            listed = (await session.list_resources()).resources
            uri = next(item.uri for item in listed if str(item.uri).endswith("/relay-test.mt"))
            content = await session.read_resource(uri)
            assert "@Action" in content.contents[0].text
            skill = next(item.uri for item in listed if str(item.uri).endswith("/references/action-mt.md"))
            assert "@Action" in (await session.read_resource(skill)).contents[0].text
            status = data(await session.call_tool("get_status", {}))["data"]
            assert status["state"] == "loaded" and not status["active"] and not status["faulted"]
    asyncio.run(scenario())


def test_read_only_by_default_never_activates(tmp_path):
    async def scenario():
        async with client(tmp_path) as session:
            for tool, args in [("run_action_script", {"script": "relay-test.mt"}),
                               ("read_variables", {"names": ["relay0"]}),
                               ("capture_image", {"name": "camera"})]:
                result = await session.call_tool(tool, args)
                assert result.isError
                receipt = data(result)
                assert receipt["state"] == "not_executed" and not receipt["executed"]
                assert receipt["error"]["type"] == "PermissionError"
            # Closed schemas and static validation still run before the gate.
            extra = await session.call_tool("run_action_script",
                                            {"script": "relay-test.mt", "allow_hardware": True})
            assert extra.isError
            assert (await session.call_tool("query_sql", {"sql": "DROP TABLE Relay;"})).isError
            assert (await session.call_tool("shell", {"command": "true"})).isError
            assert data(await session.call_tool("get_status", {}))["data"]["state"] == "loaded"
    asyncio.run(scenario())


def test_run_read_deactivate_and_reactivate(tmp_path):
    async def scenario():
        async with client(tmp_path, extra=("--allow-execution", "--read-var", "relay0")) as session:
            first = data(await session.call_tool("run_action_script", {"script": "relay-test.mt"}))
            assert first["ok"] and first["executed"]
            assert first["data"]["outputs"][-1]["slept"] == 1
            read = data(await session.call_tool("read_variables", {"names": ["relay0"]}))
            assert read["ok"] and read["executed"]
            status = data(await session.call_tool("get_status", {}))["data"]
            assert status["state"] == "active"
            assert status["last_receipt"]["tool"] == "read_variables"
            released = data(await session.call_tool("deactivate", {}))
            assert released["ok"] and released["data"] == {"active": False, "faulted": False}
            again = data(await session.call_tool("read_variables", {"names": ["relay0"]}))
            assert again["ok"] and again["executed"]
    asyncio.run(scenario())


def test_paths_allowlists_and_unknown_tools_are_rejected(tmp_path):
    async def scenario():
        async with client(tmp_path, extra=("--allow-execution",)) as session:
            for path in ("../scripts/relay-test.mt", str(ROOT / "scripts/relay-test.mt"), "missing.mt"):
                result = data(await session.call_tool("run_action_script", {"script": path}))
                assert not result["ok"] and not result["executed"]
            assert (await session.call_tool("capture_image", {"name": "relay0"})).isError
            assert (await session.call_tool("read_variables", {"names": ["relay0"]})).isError
            assert data(await session.call_tool("get_status", {}))["data"]["state"] == "loaded"
            assert (await session.call_tool("not_a_tool", {})).isError
    asyncio.run(scenario())


def test_allow_hardware_requires_execution(tmp_path):
    result = subprocess.run([sys.executable, *command(extra=("--allow-hardware",))],
                            cwd=tmp_path, env=dict(os.environ, PYTHONPATH=str(ROOT)),
                            capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == 2
    assert "--allow-hardware requires --allow-execution" in result.stderr
    assert not result.stdout.strip(), "MCP startup errors must not write to the protocol stream"
