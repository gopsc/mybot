"""serve: stdio JSON-RPC session server — real subprocess for protocol/session, in-process for the agent."""
import asyncio
import io
import json
import os
from pathlib import Path
import queue
from types import SimpleNamespace
import shutil
import subprocess
import sys
import threading
import time

import pytest

from pymybot import serve
from pymybot.errors import BudgetExceeded

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
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")


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


class _ReadTarget:
    kind = "sensor"
    budget = None

    def __init__(self, read):
        self._read = read

    def read(self):
        return self._read()


class _ReadRegistry:
    def __init__(self, target):
        self.target = target

    def require(self, name):
        assert name == "cl0"
        return self.target

    def values(self):
        return [self.target]


def sample_robot(read):
    return SimpleNamespace(stop_event=threading.Event(),
                           registry=_ReadRegistry(_ReadTarget(read)))


def test_sample_rechecks_cancel_after_read():
    cancel = threading.Event()
    server = serve.Server(io.StringIO(), threading.Event())
    robot = sample_robot(lambda: (cancel.set(), {"result": "OK", "value": 1})[1])
    with pytest.raises(BudgetExceeded):
        server.sample(robot, "s1", "cl0", 1, 0, None, cancel)


def test_sample_rechecks_deadline_after_read():
    server = serve.Server(io.StringIO(), threading.Event())
    robot = sample_robot(lambda: (time.sleep(0.02), {"result": "OK", "value": 1})[1])
    with pytest.raises(BudgetExceeded):
        server.sample(robot, "s1", "cl0", 1, 0, 0.01, threading.Event())


def test_sample_rechecks_budget_before_reporting_last_of_multiple():
    calls = []

    def read():
        calls.append(1)
        if len(calls) == 3:
            time.sleep(0.02)
        return {"result": "OK", "value": 1}

    server = serve.Server(io.StringIO(), threading.Event())
    with pytest.raises(BudgetExceeded):
        server.sample(sample_robot(read), "s1", "cl0", 3, 0, 0.01, threading.Event())


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


def test_shutdown_with_eof_closes_active_session(workspace, client_factory):
    client = client_factory(workspace, "--no-agent")
    client.call("session.activate", {"robot": str(workspace / "robot.sql")})
    assert client.call("shutdown") == {}
    assert client.close() == 0
    assert client.next() == {"jsonrpc": "2.0", "method": "session",
                             "params": {"state": "Inactive", "busy": None, "agent": False}}
    assert client.next() == {"ok": True, "command": "serve", "stopped": False}


class Out:
    def __init__(self):
        self.lines = queue.Queue()

    def write(self, text):
        self.lines.put(json.loads(text))

    def flush(self):
        pass


def test_cancelled_confirm_notifies_client_and_ignores_late_approval():
    async def scenario():
        out = Out()
        server = serve.Server(out, threading.Event())
        try:
            task = asyncio.create_task(server.ask_client("confirm", {"tool": "run_action_script"}))
            request = await asyncio.to_thread(out.lines.get, True, 5)
            assert request["method"] == "confirm"
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            assert out.lines.get_nowait() == {"jsonrpc": "2.0", "method": "cancel",
                                              "params": {"id": request["id"]}}
            server.receive(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                                       "result": {"approved": True}}), asyncio.get_running_loop())
            assert out.lines.empty()
            assert server.client_calls == {}
        finally:
            await server.shutdown()
    asyncio.run(scenario())


def test_confirm_timeout_notifies_client():
    async def scenario():
        out = Out()
        server = serve.Server(out, threading.Event())
        try:
            with pytest.raises(asyncio.TimeoutError):
                await asyncio.wait_for(server.ask_client("confirm", {"tool": "run_action_script"}), 0.02)
            request = out.lines.get_nowait()
            assert request["method"] == "confirm"
            assert out.lines.get_nowait() == {"jsonrpc": "2.0", "method": "cancel",
                                              "params": {"id": request["id"]}}
        finally:
            await server.shutdown()
    asyncio.run(scenario())


def test_shutdown_revokes_unanswered_confirm():
    async def scenario():
        out = Out()
        server = serve.Server(out, threading.Event())
        task = asyncio.create_task(server.ask_client("confirm", {"tool": "run_action_script"}))
        request = await asyncio.to_thread(out.lines.get, True, 5)
        assert request["method"] == "confirm"
        await server.shutdown()
        assert await task is None
        messages = []
        while not out.lines.empty():
            messages.append(out.lines.get_nowait())
        assert messages == [{"jsonrpc": "2.0", "method": "cancel", "params": {"id": request["id"]}}]
    asyncio.run(scenario())


class LifecycleGate:
    """An explicit async barrier, also usable from the robot owner thread."""
    def __init__(self):
        self.loop = asyncio.get_running_loop()
        self.entered = asyncio.Event()
        self.release = asyncio.Event()

    async def wait(self):
        self.entered.set()
        await self.release.wait()

    def wait_on_worker(self):
        asyncio.run_coroutine_threadsafe(self.wait(), self.loop).result(timeout=10)

    async def reached(self):
        await asyncio.wait_for(self.entered.wait(), 5)


class LifecycleHarness:
    """Real RPC dispatch/worker, fake resources: no Lua, hardware or model IO."""
    def __init__(self, workspace, monkeypatch):
        self.server = serve.Server(self, threading.Event())
        self.seq = 0
        self.replies = {}
        self.tasks = {}
        self.gates = {}
        self.errors = set()
        self.robots = []
        self.agents = []
        self.params = {"robot": str(workspace / "robot.sql"), "scriptsDir": str(workspace), "task": "test"}
        harness = self

        class FakeRobot:
            def __init__(self, *args, **kwargs):
                self.owner = threading.get_ident()
                assert self.owner != threading.main_thread().ident
                self.stop_event = threading.Event()
                self.tables = {}
                self.live = False
                self.closed = 0
                harness.robots.append(self)

            def phase(self, name):
                assert threading.get_ident() == self.owner
                if name in harness.gates:
                    harness.gates[name].wait_on_worker()
                if name in harness.errors:
                    raise RuntimeError("synthetic " + name)

            def active(self):
                self.live = True
                self.phase("activate")

            def _rows(self, tables):
                self.phase("metadata")
                return {}

            def run(self, *args, cancel, **kwargs):
                self.phase("run")
                if cancel.is_set():
                    raise serve.BudgetExceeded("Stop requested")
                return []

            def deactivate(self):
                try:
                    self.phase("deactivate")
                finally:
                    self.live = False
                    self.closed += 1

        class FakeSession:
            def __init__(self):
                self.executor = self
                self.events = []
                self.stopped = False
                self.closed = False

            def cancel(self):
                self.stopped = True

            async def ask(self, task):
                await harness.phase("ask")
                if self.stopped:
                    raise serve.AgentInterrupted("Stop requested")
                return {"output": "fake"}

            async def close(self):
                try:
                    await harness.phase("agent_close")
                finally:
                    self.closed = True

        class FakeClient:
            def __init__(self):
                self.closed = False

            async def close(self):
                try:
                    await harness.phase("client_close")
                finally:
                    self.closed = True

        async def open_agent(key):
            await self.phase("open")
            agent = {"session": FakeSession(), "client": FakeClient()}
            self.agents.append(agent)
            return agent

        monkeypatch.setattr(serve, "Robot", FakeRobot)
        monkeypatch.setattr(self.server, "open_agent", open_agent)

    def block(self, name):
        gate = self.gates[name] = LifecycleGate()
        return gate

    async def phase(self, name):
        if name in self.gates:
            await self.gates[name].wait()
        if name in self.errors:
            raise RuntimeError("synthetic " + name)

    def write(self, text):
        message = json.loads(text)
        if "id" in message:
            self.replies[message["id"]].set_result(message)

    def flush(self):
        pass

    def start(self, method, params=None):
        self.seq += 1
        ident = self.seq
        self.replies[ident] = asyncio.get_running_loop().create_future()
        before = set(self.server.tasks)
        self.server.receive(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                                       "params": self.params if params is None else params}),
                            asyncio.get_running_loop())
        self.tasks[ident] = (self.server.tasks - before).pop()
        return ident

    async def reply(self, ident):
        return await asyncio.wait_for(asyncio.shield(self.replies[ident]), 5)

    async def call(self, method, params=None):
        reply = await self.reply(self.start(method, params))
        assert "result" in reply, reply
        return reply["result"]

    async def error(self, method, code, params=None):
        reply = await self.reply(self.start(method, params))
        assert reply.get("error", {}).get("code") == code, reply

    async def check_free(self):
        await self.call("session.activate")
        await self.error("agent.ask", serve.WRONG_STATE)
        await self.call("session.deactivate")
        await self.call("agent.ask")
        await self.error("session.activate", serve.WRONG_STATE)
        await self.call("agent.reset")

    async def finish(self):
        self.errors.clear()
        for gate in self.gates.values():
            gate.release.set()
        await asyncio.wait_for(asyncio.gather(*self.tasks.values(), return_exceptions=True), 10)
        await asyncio.wait_for(self.server.shutdown(), 10)


def lifecycle_scenario(workspace, monkeypatch, scenario):
    async def run():
        harness = LifecycleHarness(workspace, monkeypatch)
        try:
            await scenario(harness)
        finally:
            await harness.finish()
    asyncio.run(run())


def test_owner_session_activation_blocks_agent(workspace, monkeypatch):
    async def scenario(h):
        gate = h.block("activate")
        active = h.start("session.activate")
        await gate.reached()
        assert (await h.call("session.status"))["busy"] == "session.activate"
        await h.error("agent.ask", serve.WRONG_STATE)
        await h.error("session.activate", serve.BUSY)
        assert not h.agents
        gate.release.set()
        assert "result" in await h.reply(active)
        await h.error("agent.ask", serve.WRONG_STATE)
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("phase", ["open", "ask", "agent_close", "client_close", "reconfigure"])
def test_owner_agent_transitions_block_session(workspace, monkeypatch, phase):
    async def scenario(h):
        if phase in {"agent_close", "client_close", "reconfigure"}:
            await h.call("agent.ask")
        gate = h.block("agent_close" if phase == "reconfigure" else phase)
        method = "agent.reset" if phase in {"agent_close", "client_close"} else "agent.ask"
        pending = h.start(method, {**h.params, "model": "changed"} if phase == "reconfigure" else None)
        await gate.reached()
        await h.call("session.status")  # The event loop remains responsive.
        await h.error("session.activate", serve.WRONG_STATE)
        await h.error("agent.ask", serve.BUSY)
        await h.error("agent.reset", serve.BUSY)
        assert not h.robots
        gate.release.set()
        assert "result" in await h.reply(pending)
        await h.call("agent.reset")
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


def test_owner_session_cleanup_blocks_new_owners(workspace, monkeypatch):
    async def scenario(h):
        await h.call("session.activate")
        gate = h.block("deactivate")
        first = h.start("session.deactivate")
        await gate.reached()
        second = h.start("session.deactivate")
        await h.error("agent.ask", serve.WRONG_STATE)
        await h.error("session.activate", serve.BUSY)
        await h.error("run", serve.BUSY, {"input": str(workspace / "action.mt")})
        assert not h.replies[second].done()
        assert not h.agents
        gate.release.set()
        assert (await h.reply(first))["result"]["state"] == "Inactive"
        assert (await h.reply(second))["result"]["state"] == "Inactive"
        assert h.robots[0].closed == 1
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("cancel_kind", ["rpc", "deactivate", "task"])
def test_owner_activation_cancel_keeps_claim_until_rollback(workspace, monkeypatch, cancel_kind):
    async def scenario(h):
        activation = h.block("activate")
        cleanup = h.block("deactivate")
        pending = h.start("session.activate")
        await activation.reached()
        deactivation = None
        if cancel_kind == "deactivate":
            cancelled = asyncio.Event()
            h.server.requests[pending]["hooks"].append(cancelled.set)
            deactivation = h.start("session.deactivate")
            await asyncio.wait_for(cancelled.wait(), 5)
            assert not h.replies[deactivation].done()
        elif cancel_kind == "task":
            h.tasks[pending].cancel()
        else:
            h.server.cancel({"id": pending})
        await h.error("agent.ask", serve.WRONG_STATE)
        activation.release.set()
        await cleanup.reached()
        await h.error("agent.ask", serve.WRONG_STATE)
        await h.error("session.activate", serve.BUSY)
        cleanup.release.set()
        if cancel_kind == "task":
            with pytest.raises(asyncio.CancelledError):
                await h.tasks[pending]
        else:
            assert (await h.reply(pending))["error"]["code"] == serve.CANCELLED
        if deactivation:
            assert (await h.reply(deactivation))["result"]["state"] == "Inactive"
        assert h.robots[0].closed == 1 and not h.robots[0].live
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("phase", ["activate", "metadata", "deactivate", "open"])
def test_owner_exception_releases_after_cleanup(workspace, monkeypatch, phase):
    async def scenario(h):
        if phase == "deactivate":
            await h.call("session.activate")
        h.errors.add(phase)
        method = "agent.ask" if phase == "open" else "session.deactivate" if phase == "deactivate" else "session.activate"
        await h.error(method, serve.EXECUTION_ERROR)
        assert all(not robot.live and robot.closed == 1 for robot in h.robots)
        h.errors.clear()
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("cancel_kind", ["rpc", "task"])
@pytest.mark.parametrize("phase", ["open", "ask"])
def test_owner_agent_cancel_closes_before_reopen(workspace, monkeypatch, phase, cancel_kind):
    pytest.importorskip("pydantic_ai")

    async def scenario(h):
        gate = h.block(phase)
        cleanup = h.block("agent_close")
        pending = h.start("agent.ask")
        await gate.reached()
        if cancel_kind == "task":
            h.tasks[pending].cancel()
        else:
            h.server.cancel({"id": pending})
        await h.error("session.activate", serve.WRONG_STATE)
        gate.release.set()
        await cleanup.reached()
        await h.error("session.activate", serve.WRONG_STATE)
        await h.error("agent.ask", serve.BUSY)
        cleanup.release.set()
        if cancel_kind == "task":
            with pytest.raises(asyncio.CancelledError):
                await h.tasks[pending]
        else:
            assert (await h.reply(pending))["error"]["code"] == serve.CANCELLED
        assert all(resource.closed for resource in h.agents[0].values())
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("phase", ["ask", "agent_close", "client_close"])
def test_owner_agent_failure_cleanup_is_exclusive(workspace, monkeypatch, phase):
    pytest.importorskip("pydantic_ai")

    async def scenario(h):
        h.errors.add(phase)
        cleanup = h.block("client_close")
        if phase == "ask":
            pending = h.start("agent.ask")
        else:
            await h.call("agent.ask")
            pending = h.start("agent.reset")
        await cleanup.reached()
        await h.error("session.activate", serve.WRONG_STATE)
        await h.error("agent.ask", serve.BUSY)
        cleanup.release.set()
        reply = await h.reply(pending)
        assert "error" in reply if phase == "ask" else "result" in reply
        assert all(resource.closed for resource in h.agents[0].values())
        h.errors.clear()
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


def test_owner_deactivate_waits_for_cancelled_run(workspace, monkeypatch):
    async def scenario(h):
        await h.call("session.activate")
        running = h.block("run")
        cleanup = h.block("deactivate")
        pending = h.start("run", {"input": str(workspace / "action.mt")})
        await running.reached()
        await h.error("agent.ask", serve.WRONG_STATE)
        await h.error("run", serve.BUSY, {"input": str(workspace / "action.mt")})
        cancelled = asyncio.Event()
        h.server.requests[pending]["hooks"].append(cancelled.set)
        deactivation = h.start("session.deactivate")
        await asyncio.wait_for(cancelled.wait(), 5)
        await h.error("agent.ask", serve.WRONG_STATE)
        assert not cleanup.entered.is_set()
        running.release.set()
        await cleanup.reached()
        await h.error("agent.ask", serve.WRONG_STATE)
        assert (await h.reply(pending))["error"]["code"] == serve.CANCELLED
        cleanup.release.set()
        assert "result" in await h.reply(deactivation)
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("phase", ["deactivate", "agent_close", "client_close"])
def test_owner_cleanup_survives_repeated_task_cancel(workspace, monkeypatch, phase):
    async def scenario(h):
        session = phase == "deactivate"
        await h.call("session.activate" if session else "agent.ask")
        gate = h.block(phase)
        pending = h.start("session.deactivate" if session else "agent.reset")
        await gate.reached()
        for _ in range(2):
            h.tasks[pending].cancel()
            await h.error("agent.ask" if session else "session.activate", serve.WRONG_STATE)
            assert not h.tasks[pending].done()
        gate.release.set()
        with pytest.raises(asyncio.CancelledError):
            await h.tasks[pending]
        if session:
            assert h.robots[0].closed == 1
        else:
            assert all(resource.closed for resource in h.agents[0].values())
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("owner", ["session", "agent"])
def test_owner_cleanup_survives_cancellation_before_task_starts(workspace, monkeypatch, owner):
    async def scenario(h):
        await h.call("session.activate" if owner == "session" else "agent.ask")
        create_task = asyncio.create_task
        interrupted = []
        def cancel_first_cleanup(coro, *args, **kwargs):
            task = create_task(coro, *args, **kwargs)
            if not interrupted and coro.cr_code.co_name == ("_deactivate" if owner == "session" else "close"):
                interrupted.append(task)
                task.cancel()
            return task
        monkeypatch.setattr(asyncio, "create_task", cancel_first_cleanup)
        pending = h.start("session.deactivate" if owner == "session" else "agent.reset")
        with pytest.raises(asyncio.CancelledError):
            await h.tasks[pending]
        assert interrupted
        if owner == "session":
            assert h.robots[0].closed == 1
        else:
            assert all(resource.closed for resource in h.agents[0].values())
        assert h.server.owner is None and h.server.robot is None and h.server.agent is None
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


def test_owner_cleanup_survives_inner_and_outer_task_cancellation(workspace, monkeypatch):
    async def scenario(h):
        await h.call("session.activate")
        running = h.block("run")
        cleanup = h.block("deactivate")
        operation = h.start("run", {"input": str(workspace / "action.mt")})
        await running.reached()
        waiting = asyncio.Event()
        wait_idle = h.server.robot_idle.wait
        async def wait_for_idle():
            waiting.set()
            await wait_idle()
        monkeypatch.setattr(h.server.robot_idle, "wait", wait_for_idle)
        deactivation = h.start("session.deactivate")
        await asyncio.wait_for(waiting.wait(), 5)
        inner = h.server.deactivating
        h.tasks[operation].cancel()
        h.tasks[deactivation].cancel()
        inner.cancel()
        await asyncio.sleep(0)
        assert h.server.owner == "session" and h.server.robot is not None
        assert not inner.done()
        await h.error("agent.ask", serve.WRONG_STATE)
        running.release.set()
        await cleanup.reached()
        assert h.server.owner == "session"
        cleanup.release.set()
        await asyncio.gather(h.tasks[operation], h.tasks[deactivation], inner, return_exceptions=True)
        assert h.robots[0].closed == 1 and not h.robots[0].live
        assert h.server.owner is None and h.server.robot is None
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("failure", ["error", "task_cancel"])
def test_owner_run_failure_keeps_session_but_releases_operation(workspace, monkeypatch, failure):
    async def scenario(h):
        await h.call("session.activate")
        gate = h.block("run")
        pending = h.start("run", {"input": str(workspace / "action.mt")})
        await gate.reached()
        if failure == "error":
            h.errors.add("run")
        else:
            h.tasks[pending].cancel()
        await h.error("agent.ask", serve.WRONG_STATE)
        gate.release.set()
        expected = serve.EXECUTION_ERROR if failure == "error" else serve.CANCELLED
        assert (await h.reply(pending))["error"]["code"] == expected
        h.errors.clear()
        assert (await h.call("session.status"))["busy"] is None
        assert not h.robots[0].stop_event.is_set()
        await h.call("run", {"input": str(workspace / "action.mt")})
        await h.error("agent.ask", serve.WRONG_STATE)
        await h.call("session.deactivate")
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("constructor", ["executor", "session"])
def test_owner_real_open_agent_cleans_partial_construction(workspace, monkeypatch, constructor):
    pytest.importorskip("pydantic_ai")
    from pymybot import agent as agent_module, agent_executor

    async def scenario(h):
        gate = h.block("client_close")
        closed = []

        class FakeClient:
            async def close(self):
                await h.phase("client_close")
                closed.append("client")

        class FakeExecutor:
            def __init__(self, *args, **kwargs):
                if constructor == "executor":
                    raise RuntimeError("synthetic executor construction")

            async def close(self):
                closed.append("executor")

        def fail_session(*args, **kwargs):
            raise RuntimeError("synthetic session construction")

        monkeypatch.setattr(agent_module, "create_model", lambda config: (object(), FakeClient()))
        monkeypatch.setattr(agent_module, "AgentSession", fail_session)
        monkeypatch.setattr(agent_executor, "RobotExecutor", FakeExecutor)
        fake_open = h.server.open_agent
        monkeypatch.setattr(h.server, "open_agent", serve.Server.open_agent.__get__(h.server))
        pending = h.start("agent.ask")
        await gate.reached()
        await h.error("session.activate", serve.WRONG_STATE)
        await h.error("agent.ask", serve.BUSY)
        gate.release.set()
        assert (await h.reply(pending))["error"]["code"] == serve.EXECUTION_ERROR
        assert closed == (["executor", "client"] if constructor == "session" else ["client"])
        monkeypatch.setattr(h.server, "open_agent", fake_open)
        await h.check_free()
    lifecycle_scenario(workspace, monkeypatch, scenario)


@pytest.mark.parametrize("owner", ["session", "agent"])
def test_owner_eof_waits_for_initialization_and_cleanup(workspace, monkeypatch, owner):
    pytest.importorskip("pydantic_ai")

    async def scenario(h):
        gate = h.block("activate" if owner == "session" else "open")
        cleanup = h.block("deactivate" if owner == "session" else "agent_close")
        pending = h.start("session.activate" if owner == "session" else "agent.ask")
        await gate.reached()
        cancelled = asyncio.Event()
        h.server.requests[pending]["hooks"].append(cancelled.set)
        lines = asyncio.Queue()
        serving = asyncio.create_task(h.server.serve(lines))
        try:
            lines.put_nowait(None)
            await asyncio.wait_for(cancelled.wait(), 5)
            await h.error("session.activate", serve.BUSY)
            await h.error("agent.ask", serve.BUSY)
            gate.release.set()
            await cleanup.reached()
            assert not serving.done()
            cleanup.release.set()
            await asyncio.wait_for(serving, 5)
            assert (await h.reply(pending))["error"]["code"] == serve.CANCELLED
            assert h.server.owner is None
            assert h.server.robot is None and h.server.agent is None
        finally:
            gate.release.set()
            cleanup.release.set()
            await asyncio.wait_for(serving, 5)
    lifecycle_scenario(workspace, monkeypatch, scenario)


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
