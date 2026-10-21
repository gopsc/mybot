"""serve: stdio JSON-RPC session server — real subprocess for protocol/session, in-process for the agent."""
import asyncio
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

import pytest

from pymybot import serve

ROOT = Path(__file__).resolve().parents[1]
VIRTUAL_SQL = """
CREATE TABLE Timer(name String);
INSERT INTO Timer(name) VALUES('t0');
CREATE TABLE Relay(name String);
INSERT INTO Relay(name) VALUES('relay0');
CREATE TABLE dummy(name String);
INSERT INTO dummy(name) VALUES('dev');
"""
ACTION = "@Action\nrelay0.test dev.echo;\n7 9;\n@\n"
PHYSICAL_SQL = "CREATE TABLE I2C(name String,path String); INSERT INTO I2C(name,path) VALUES('bus','/dev/i2c-99');"


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    for key in list(os.environ):
        if key.startswith(("BOT4CJ_", "PYMYBOT_", "MYBOT_")):
            monkeypatch.delenv(key)


@pytest.fixture
def workspace(tmp_path):
    (tmp_path / "robot.sql").write_text(VIRTUAL_SQL, encoding="utf-8")
    (tmp_path / "physical.sql").write_text(PHYSICAL_SQL, encoding="utf-8")
    (tmp_path / "action.mt").write_text(ACTION, encoding="utf-8")
    (tmp_path / "dev2.mt").write_text("@Action\ndev2.echo;\n5;\n@\n", encoding="utf-8")
    (tmp_path / "long.mt").write_text("@Action\nt0.delay;\n20000;\n@\n", encoding="utf-8")
    shutil.copy(ROOT / "tests" / "fixtures" / "virt" / "bh1750_virt.sql", tmp_path / "bh1750.sql")
    return tmp_path


class Client:
    def __init__(self, cwd, *args):
        self.proc = subprocess.Popen([sys.executable, "-m", "pymybot", "serve", *args], cwd=cwd,
                                     env=dict(os.environ, PYTHONPATH=str(ROOT)), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8")
        self.lines = queue.Queue()
        self.raw = []
        self.stderr = []
        self.notes = []
        self.replies = {}
        self.seq = 0
        threading.Thread(target=self._pump, args=(self.proc.stdout, self.lines), daemon=True).start()
        threading.Thread(target=lambda: self.stderr.extend(self.proc.stderr), daemon=True).start()

    def _pump(self, stream, sink):
        for line in stream:
            self.raw.append(line)
            sink.put(line)
        sink.put(None)

    def write(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def send(self, method, params=None):
        self.seq += 1
        message = {"jsonrpc": "2.0", "id": self.seq, "method": method}
        if params is not None:
            message["params"] = params
        self.write(json.dumps(message))
        return self.seq

    def next(self, timeout=20):
        line = self.lines.get(timeout=timeout)
        assert line is not None, "server exited: " + "".join(self.stderr[-20:])
        return json.loads(line)

    def wait(self, ident, timeout=20):
        deadline = time.monotonic() + timeout
        while ident not in self.replies:
            message = self.next(max(0.01, deadline - time.monotonic()))
            if "id" in message and "method" not in message:
                self.replies[message["id"]] = message
            else:
                self.notes.append(message)
        return self.replies.pop(ident)

    def call(self, method, params=None, timeout=20):
        reply = self.wait(self.send(method, params), timeout)
        assert "result" in reply, reply
        return reply["result"]

    def error(self, method, params=None, timeout=20):
        reply = self.wait(self.send(method, params), timeout)
        assert "error" in reply, reply
        return reply["error"]

    def close(self, timeout=20):
        self.proc.stdin.close()
        code = self.proc.wait(timeout)
        return code


@pytest.fixture
def client_factory():
    clients = []

    def make(cwd, *args):
        clients.append(Client(cwd, *args))
        return clients[-1]
    yield make
    for client in clients:
        if client.proc.poll() is None:
            client.proc.kill()
            client.proc.wait()


def test_protocol_errors(workspace, client_factory):
    client = client_factory(workspace)
    info = client.call("initialize")
    assert info["protocol"] == serve.PROTOCOL and info["status"]["state"] == "Inactive"
    client.write("not json")
    assert client.next()["error"]["code"] == serve.PARSE_ERROR
    client.write('{"jsonrpc":"2.0","id":NaN,"method":"initialize"}')
    assert client.next()["error"]["code"] == serve.PARSE_ERROR
    client.write('{"jsonrpc":"2.0","id":1.5,"method":"initialize"}')
    assert client.next()["error"]["code"] == serve.INVALID_REQUEST
    client.write('{"id":5,"method":"initialize"}')
    assert client.next() == {"jsonrpc": "2.0", "id": 5, "error": {"code": serve.INVALID_REQUEST,
                                                               "message": "Invalid JSON-RPC 2.0 message"}}
    client.write('{"jsonrpc":"2.0","method":"nobody-answers-notifications"}')
    assert client.error("nope")["code"] == serve.METHOD_NOT_FOUND
    assert client.error("run", {})["code"] == serve.INVALID_PARAMS
    assert client.error("run", {"input": "action.mt", "timeout": 0})["code"] == serve.INVALID_PARAMS
    assert client.error("sample", {"name": "../x"})["code"] == serve.INVALID_PARAMS
    assert client.error("run", {"input": "action.mt"})["code"] == serve.WRONG_STATE
    assert client.error("apply-sql", {"sql": "DELETE FROM dummy;"})["code"] == serve.WRONG_STATE
    assert client.close() == 0


def test_session_persists_hot_sql_until_deactivate(workspace, client_factory):
    client = client_factory(workspace)
    active = client.call("session.activate", {"robot": str(workspace / "robot.sql")})
    assert active["state"] == "Active" and {h["name"] for h in active["hardware"]} == {"t0", "relay0", "dev"}
    assert client.notes[-1]["method"] == "session" and client.notes[-1]["params"]["state"] == "Active"
    assert client.error("session.activate", {"robot": str(workspace / "robot.sql")})["code"] == serve.WRONG_STATE
    assert len(client.call("run", {"input": str(workspace / "action.mt")})["outputs"]) == 2
    assert client.error("run", {"input": str(workspace / "dev2.mt")})["code"] == serve.EXECUTION_ERROR
    applied = client.call("apply-sql", {"sql": "INSERT INTO dummy(name) VALUES('dev2');"})
    assert "dev2" in {h["name"] for h in applied["hardware"]}
    assert client.call("run", {"input": str(workspace / "dev2.mt")})["outputs"]
    assert client.call("session.deactivate")["state"] == "Inactive"
    assert client.error("run", {"input": str(workspace / "action.mt")})["code"] == serve.WRONG_STATE
    again = client.call("session.activate", {"robot": str(workspace / "robot.sql")})
    assert "dev2" not in {h["name"] for h in again["hardware"]}  # Hot SQL never writes the file.
    assert client.close() == 0


def test_sample_streams_and_cancel_keeps_daemons_alive(workspace, client_factory):
    client = client_factory(workspace)
    client.call("session.activate", {"robot": str(workspace / "bh1750.sql")})
    client.notes.clear()
    result = client.call("sample", {"name": "cl0", "count": 3, "intervalMs": 20})
    samples = [n["params"] for n in client.notes if n.get("method") == "sample"]
    assert result == {"name": "cl0", "count": 3}
    assert [s["index"] for s in samples] == [0, 1, 2] and all(s["value"]["result"] == "OK" for s in samples)
    counts = [s["value"]["count"] for s in samples]
    assert counts == sorted(set(counts))

    long_run = client.send("run", {"input": str(workspace / "long.mt")})
    time.sleep(0.5)
    assert client.error("sample", {"name": "cl0"})["code"] == serve.BUSY
    began = time.monotonic()
    client.write(json.dumps({"jsonrpc": "2.0", "method": "cancel", "params": {"id": long_run}}))
    reply = client.wait(long_run)
    assert reply["error"]["code"] == serve.CANCELLED and time.monotonic() - began < 5
    # Per-request cancel must not set the robot-wide stop that permanently ends daemons.
    assert client.call("sample", {"name": "cl0", "count": 2})["count"] == 2

    endless = client.send("sample", {"name": "cl0", "count": serve.MAX_SAMPLES, "intervalMs": 10})
    client.next()
    client.call("session.deactivate")
    assert client.wait(endless)["error"]["code"] == serve.CANCELLED
    assert client.close() == 0


def test_stdout_carries_only_protocol_and_eof_deactivates(workspace, client_factory):
    client = client_factory(workspace)
    client.call("session.activate", {"robot": str(workspace / "bh1750.sql")})
    client.call("run", {"input": str(ROOT / "tests" / "fixtures" / "virt" / "bh1750_virt.mt")}, timeout=60)
    assert client.close() == 0
    *protocol, final = [json.loads(line) for line in client.raw]
    assert all(message["jsonrpc"] == "2.0" for message in protocol)
    assert protocol[-1] == {"jsonrpc": "2.0", "method": "session",
                            "params": {"state": "Inactive", "busy": None, "agent": False}}
    assert final == {"ok": True, "command": "serve", "stopped": False}
    assert "VIRTUAL" in "".join(client.stderr)  # Lua driver output goes to stderr.


def test_physical_hardware_needs_explicit_permission(workspace, client_factory):
    client = client_factory(workspace)
    error = client.error("session.activate", {"robot": str(workspace / "physical.sql")})
    assert error["code"] == serve.EXECUTION_ERROR and "--allow-hardware" in error["message"]
    assert client.call("session.status")["state"] == "Inactive"
    assert client.close() == 0


def test_no_agent_disables_agent_methods(workspace, client_factory):
    client = client_factory(workspace, "--no-agent")
    assert client.call("initialize")["agent"] is False
    error = client.error("agent.ask", {"task": "hi", "robot": "robot.sql", "scriptsDir": "."})
    assert error["code"] == serve.METHOD_NOT_FOUND
    assert client.close() == 0


class Out:
    def __init__(self):
        self.lines = queue.Queue()

    def write(self, text):
        self.lines.put(json.loads(text))

    def flush(self):
        pass


def test_agent_tool_approval_round_trip(workspace, monkeypatch):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai import models
    from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart
    from pydantic_ai.models.function import DeltaToolCall, FunctionModel
    import pymybot.agent as agent_module

    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)

    def make_model():
        responses = iter([[ToolCallPart("run_action_script", {"script": "action.mt"}, "c1")], [TextPart("完成")]])

        async def respond(messages, info):
            return ModelResponse(parts=next(responses))

        async def stream(messages, info):
            for part in next(responses):
                if isinstance(part, TextPart):
                    yield part.content
                else:
                    yield {0: DeltaToolCall(name=part.tool_name, json_args=json.dumps(part.args),
                                            tool_call_id=part.tool_call_id)}
        return FunctionModel(respond, stream_function=stream)

    class FakeClient:
        async def close(self):
            pass

    monkeypatch.setattr(agent_module, "create_model", lambda config: (make_model(), FakeClient()))
    params = {"task": "执行动作", "robot": str(workspace / "robot.sql"), "scriptsDir": str(workspace),
              "model": "openai:fake"}

    async def scenario():
        out = Out()
        server = serve.Server(out, threading.Event())
        lines = asyncio.Queue()
        task = asyncio.create_task(server.serve(lines))

        def put(message):
            lines.put_nowait(json.dumps({"jsonrpc": "2.0", **message}))

        async def until(ident, approve=None):
            seen = []
            while True:
                message = await asyncio.to_thread(out.lines.get, True, 20)
                if message.get("method") == "confirm":
                    assert message["params"]["tool"] == "run_action_script"
                    put({"id": message["id"], "result": {"approved": approve}})
                elif message.get("id") == ident:
                    return message, seen
                else:
                    seen.append(message)

        put({"id": 1, "method": "agent.ask", "params": params})
        reply, seen = await until(1, approve=True)
        assert reply["result"]["output"] == "完成"
        assert reply["result"]["tool_events"] == [{"tool": "run_action_script", "ok": True,
                                                   "executed": True, "state": "completed"}]
        assert any(m.get("method") == "agent.event" and m["params"]["event"]["type"] == "tool_call" for m in seen)

        put({"id": 2, "method": "session.activate", "params": {"robot": params["robot"]}})
        reply, _ = await until(2)
        assert reply["error"]["code"] == serve.WRONG_STATE
        put({"id": 3, "method": "agent.reset"})
        assert (await until(3))[0]["result"]["agent"] is False

        put({"id": 4, "method": "agent.ask", "params": params})
        reply, _ = await until(4, approve=False)
        assert reply["result"]["tool_events"][0]["executed"] is False
        lines.put_nowait(None)
        await task
        assert server.agent is None and server.robot is None

    asyncio.run(scenario())
