"""Long-lived stdio JSON-RPC 2.0 server for IDE frontends; one JSON object per line.

stdout carries only protocol messages (fd 1 is redirected to stderr while serving,
so Lua or C output cannot corrupt it). One robot session or one agent conversation
owns the hardware at a time; all session robot calls run on one owner thread.
"""
from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import math
import os
from pathlib import Path
import sys
import threading
import time

from . import __version__
from .errors import AgentInterrupted, BudgetExceeded
from .hardware import Budget, ensure_ok, safe_ident
from .robot import Robot
from .security import MAX_BODY, SecurityError, checked_text, dumps, read_file

PROTOCOL = 1
MAX_LINE = MAX_BODY + 1024 * 1024
MAX_SAMPLES = 1_000_000
MAX_TIMEOUT = 3600

PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS = -32700, -32600, -32601, -32602
EXECUTION_ERROR, BUSY, WRONG_STATE, CANCELLED = -32000, -32001, -32002, -32800


class _ClientCall:
    """A confirm request plus whether the client actually answered it.

    Cancellation and shutdown complete the future without a reply, so done()
    cannot decide whether the client should still receive a cancel notice.
    """
    __slots__ = ("future", "replied")

    def __init__(self, future):
        self.future = future
        self.replied = False


class RpcError(Exception):
    def __init__(self, code, message, **data):
        super().__init__(message)
        self.code = code
        self.data = data


class Params:
    def __init__(self, params):
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise RpcError(INVALID_PARAMS, "params must be an object")
        self.raw = params

    def _get(self, key, kinds, default, required):
        if key not in self.raw or self.raw[key] is None:
            if required:
                raise RpcError(INVALID_PARAMS, f"'{key}' is required")
            return default
        value = self.raw[key]
        if isinstance(value, bool) and bool not in kinds or not isinstance(value, kinds):
            raise RpcError(INVALID_PARAMS, f"'{key}' has the wrong type")
        return value

    def text(self, key, default=None, required=False, cap=MAX_BODY):
        value = self._get(key, (str,), default, required)
        try:
            return value if value is None else checked_text(value, cap)
        except SecurityError as exc:
            raise RpcError(INVALID_PARAMS, f"'{key}': {exc}") from None

    def flag(self, key):
        return self._get(key, (bool,), False, False)

    def integer(self, key, low, high, default=None, required=False):
        value = self._get(key, (int,), default, required)
        if value is not None and not low <= value <= high:
            raise RpcError(INVALID_PARAMS, f"'{key}' must be in {low}..{high}")
        return value

    def seconds(self, key, default=None):
        value = self._get(key, (int, float), default, False)
        if value is not None and (not math.isfinite(value) or not 0 < value <= MAX_TIMEOUT):
            raise RpcError(INVALID_PARAMS, f"'{key}' must be positive and at most {MAX_TIMEOUT} seconds")
        return value

    def strings(self, key, ident=False):
        value = self._get(key, (list,), [], False)
        if len(value) > 256 or not all(isinstance(item, str) for item in value):
            raise RpcError(INVALID_PARAMS, f"'{key}' must be a list of at most 256 strings")
        try:
            return [safe_ident(item) if ident else checked_text(item, 64 * 1024) for item in value]
        except (ValueError, SecurityError) as exc:
            raise RpcError(INVALID_PARAMS, f"'{key}': {exc}") from None

    def bindings(self, key):
        value = self._get(key, (dict,), {}, False)
        if len(value) > 256:
            raise RpcError(INVALID_PARAMS, f"'{key}' has too many entries")
        try:
            return {safe_ident(name): checked_text(text, 64 * 1024) for name, text in value.items()}
        except (ValueError, SecurityError, TypeError) as exc:
            raise RpcError(INVALID_PARAMS, f"'{key}': {exc}") from None


def _reject_constant(token):
    raise ValueError(f"non-finite number {token}")


def agent_available():
    return importlib.util.find_spec("pydantic_ai") is not None


class Server:
    def __init__(self, out, stop, *, enable_agent=True, enable_session_log=True):
        self.out = out
        self.stop = stop
        self.enable_agent = enable_agent
        self.enable_session_log = enable_session_log
        self._write_lock = threading.Lock()
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="serve-robot")
        self.robot = None
        self.session = None
        self.robot_op = None
        # Ownership includes initialization and cleanup, not just published objects.
        self.owner = None
        self.robot_idle = asyncio.Event()
        self.robot_idle.set()
        self.deactivating = None
        self.requests = {}
        self.tasks = set()
        self.client_calls = {}
        self.client_seq = 0
        self.agent = None
        self.agent_key = None
        self.agent_lock = asyncio.Lock()
        self.closing = False

    # -- transport -------------------------------------------------------
    def send(self, message):
        line = dumps({"jsonrpc": "2.0", **message})
        with self._write_lock:
            self.out.write(line + "\n")
            self.out.flush()

    def notify(self, method, params):
        self.send({"method": method, "params": params})

    async def ask_client(self, method, params):
        self.client_seq += 1
        ident = f"s{self.client_seq}"
        call = _ClientCall(asyncio.get_running_loop().create_future())
        self.client_calls[ident] = call
        try:
            self.send({"id": ident, "method": method, "params": params})
            return await call.future
        finally:
            self.client_calls.pop(ident, None)
            if not call.replied:
                self.notify("cancel", {"id": ident})

    async def serve(self, lines):
        loop = asyncio.get_running_loop()
        while not self.closing:
            line = await lines.get()
            if line is None:
                break
            self.receive(line, loop)
        await self.shutdown()

    def receive(self, line, loop):
        if isinstance(line, Exception):
            self.send({"id": None, "error": {"code": PARSE_ERROR, "message": str(line)}})
            return
        try:
            message = json.loads(line, parse_constant=_reject_constant)
        except (ValueError, UnicodeDecodeError) as exc:
            self.send({"id": None, "error": {"code": PARSE_ERROR, "message": f"Invalid JSON: {exc}"}})
            return
        ident = message.get("id") if isinstance(message, dict) else None
        valid_id = ident is None or (isinstance(ident, (str, int)) and not isinstance(ident, bool))
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not valid_id:
            self.send({"id": ident if valid_id else None,
                       "error": {"code": INVALID_REQUEST, "message": "Invalid JSON-RPC 2.0 message"}})
            return
        if "method" not in message:
            call = self.client_calls.get(ident)
            if call is not None and not call.future.done():
                call.replied = True
                call.future.set_result(message.get("result") if "error" not in message else None)
            return
        method = message["method"]
        if not isinstance(method, str):
            self.send({"id": ident, "error": {"code": INVALID_REQUEST, "message": "method must be a string"}})
            return
        if method == "cancel":
            self.cancel(message.get("params"))
            if ident is not None:
                self.send({"id": ident, "result": {}})
            return
        if ident is None:
            return  # Unknown notification: JSON-RPC forbids a reply.
        if ident in self.requests:
            self.send({"id": ident, "error": {"code": INVALID_REQUEST, "message": "Duplicate request id"}})
            return
        cancel = threading.Event()
        self.requests[ident] = {"cancel": cancel, "hooks": []}
        task = loop.create_task(self.handle(ident, method, message.get("params"), cancel))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    def cancel(self, params):
        ident = params.get("id") if isinstance(params, dict) else None
        entry = self.requests.get(ident) if isinstance(ident, (str, int)) and not isinstance(ident, bool) else None
        if entry is None:
            return
        entry["cancel"].set()
        for hook in entry["hooks"]:
            hook()

    async def handle(self, ident, method, params, cancel):
        handler = getattr(self, "m_" + method.replace(".", "_").replace("-", "_"), None)
        try:
            if handler is None:
                raise RpcError(METHOD_NOT_FOUND, f"Unknown method: {method}")
            result = await handler(ident, Params(params), cancel)
            self.send({"id": ident, "result": result})
        except RpcError as exc:
            self.send({"id": ident, "error": {"code": exc.code, "message": str(exc), "data": exc.data}})
        except Exception as exc:
            interrupted = cancel.is_set() and isinstance(exc, (BudgetExceeded, AgentInterrupted))
            data = {"type": type(exc).__name__}
            for key in ("tool_events", "cleanup_errors"):
                if hasattr(exc, key):
                    data[key] = getattr(exc, key)
            print(f"pymybot serve: {method}: {exc}", file=sys.stderr)
            self.send({"id": ident, "error": {"code": CANCELLED if interrupted else EXECUTION_ERROR,
                                              "message": str(exc), "data": data}})
        finally:
            self.requests.pop(ident, None)

    # -- ownership --------------------------------------------------------
    async def finish(self, future, cancel=None):
        """Cancellation must not abandon initialization or owner cleanup."""
        cancelled = False
        while True:
            try:
                result = await asyncio.shield(future)
                break
            except asyncio.CancelledError:
                if future.cancelled():
                    raise
                cancelled = True
                if cancel is not None:
                    cancel()
        if cancelled:
            raise asyncio.CancelledError
        return result

    def require_owner(self, owner):
        if self.closing:
            raise RpcError(BUSY, "Server is shutting down")
        if self.owner is not None and self.owner != owner:
            if self.owner == "agent":
                raise RpcError(WRONG_STATE, "An agent conversation owns the robot; call agent.reset first")
            raise RpcError(WRONG_STATE, "A robot session owns the robot; deactivate it before using the agent")

    # -- session robot ----------------------------------------------------
    async def on_worker(self, fn, *args):
        future = asyncio.get_running_loop().run_in_executor(self.worker, fn, *args)
        operation = self.robot_op
        await_cancel = (lambda: self.cancel({"id": operation[0]})) if operation else None
        return await self.finish(future, await_cancel)

    def claim(self, ident, method):
        self.require_owner("session")
        if self.deactivating is not None:
            raise RpcError(BUSY, "Session is deactivating")
        if self.robot_op is not None:
            raise RpcError(BUSY, f"Session is busy with '{self.robot_op[1]}'")
        self.robot_op = (ident, method)
        self.robot_idle.clear()

    def release(self, ident):
        if self.robot_op and self.robot_op[0] == ident:
            self.robot_op = None
            self.robot_idle.set()

    def require_session(self):
        if self.robot is None:
            raise RpcError(WRONG_STATE, "No active session; call session.activate first")
        return self.robot

    def status(self):
        return {"state": "Active" if self.robot is not None else "Inactive",
                **(self.session or {}), "busy": self.robot_op[1] if self.robot_op else None,
                "agent": self.agent is not None}

    async def m_initialize(self, ident, params, cancel):
        return {"protocol": PROTOCOL, "version": __version__,
                "agent": self.enable_agent and agent_available(),
                "mcp": importlib.util.find_spec("mcp") is not None,
                "status": self.status()}

    async def m_session_status(self, ident, params, cancel):
        return self.status()

    async def m_session_activate(self, ident, params, cancel):
        robot_path = params.text("robot", required=True)
        module_paths = params.strings("modulePaths") or None
        camera = params.text("cameraSrcDir")
        allow_hardware = params.flag("allowHardware")
        bindings = params.bindings("vars")
        self.require_owner("session")
        if self.deactivating is not None:
            raise RpcError(BUSY, "Session is deactivating")
        if self.robot is not None:
            raise RpcError(WRONG_STATE, "Session already active; deactivate it first")
        self.claim(ident, "session.activate")
        self.owner = "session"
        holder = {}
        self.requests[ident]["hooks"].append(lambda: holder.get("robot") and holder["robot"].stop_event.set())

        def activate():
            path = Path(robot_path).absolute()
            robot = Robot(read_file(path), module_paths=module_paths, camera_src_root=camera,
                          allow_hardware=allow_hardware, vars=bindings)
            robot.structure_path = str(path)
            holder["robot"] = robot
            if cancel.is_set():
                robot.stop_event.set()
            robot.active()
            hardware = [{"name": name, "type": table.name,
                         "metadata": {col: table.inherited(row, i) for i, col in enumerate(table.header) if col != "name"}}
                        for name, (table, row) in robot._rows(robot.tables).items()
                        if table.name not in {"Alias", "Vars"}]
            return robot, hardware

        try:
            robot, hardware = await self.on_worker(activate)
            if cancel.is_set():
                raise BudgetExceeded("Stop requested; activation rolled back")
            self.robot = robot
            self.session = {"robot": robot.structure_path, "allowHardware": allow_hardware, "since": time.time()}
        except BaseException:
            # The owner thread must also clean partially completed activation.
            if "robot" in holder:
                await self.on_worker(holder["robot"].deactivate)
            raise
        finally:
            self.release(ident)
            if self.robot is None and self.deactivating is None:
                self.owner = None
        self.notify("session", self.status())
        return {**self.status(), "hardware": hardware}

    async def m_session_deactivate(self, ident, params, cancel):
        await self.deactivate()
        return self.status()

    async def deactivate(self):
        cancelled = False
        while self.owner == "session":
            if self.deactivating is None or self.deactivating.cancelled():
                self.deactivating = asyncio.create_task(self._deactivate())
            try:
                await self.finish(self.deactivating)
                break
            except asyncio.CancelledError:
                cancelled = True
        if cancelled:
            raise asyncio.CancelledError

    async def _deactivate(self):
        cancelled = False
        try:
            if self.robot_op is not None:
                self.cancel({"id": self.robot_op[0]})
            # Loop-wide cancellation can target this cleanup task directly.
            while True:
                try:
                    await self.robot_idle.wait()
                    break
                except asyncio.CancelledError:
                    cancelled = True
            if self.robot is not None:
                await self.on_worker(self.robot.deactivate)
        finally:
            self.robot = None
            self.session = None
            self.owner = None
            self.deactivating = None
            self.notify("session", self.status())
        if cancelled:
            raise asyncio.CancelledError

    async def m_run(self, ident, params, cancel):
        source = params.text("input", required=True)
        bindings = params.bindings("vars")
        timeout = params.seconds("timeout", 180)
        robot = self.require_session()
        self.claim(ident, "run")
        try:
            path = Path(source).absolute()
            def run():
                return robot.run(read_file(path), base_dir=str(path.parent), vars=bindings,
                                 timeout=timeout, cancel=cancel)
            return {"outputs": await self.on_worker(run)}
        finally:
            self.release(ident)

    async def m_apply_sql(self, ident, params, cancel):
        sql = params.text("sql", required=True)
        robot = self.require_session()
        self.claim(ident, "apply-sql")
        try:
            output = await self.on_worker(lambda: robot.apply_sql(sql, cancel=cancel))
            hardware = [{"name": name, "type": table.name}
                        for name, (table, row) in robot._rows(robot.tables).items()
                        if table.name not in {"Alias", "Vars"}]
            return {"output": output, "hardware": hardware}
        finally:
            self.release(ident)

    async def m_sample(self, ident, params, cancel):
        name = params.text("name", required=True)
        try:
            safe_ident(name)
        except ValueError as exc:
            raise RpcError(INVALID_PARAMS, str(exc)) from None
        count = params.integer("count", 1, MAX_SAMPLES, default=1)
        interval = params.integer("intervalMs", 0, 60000, default=0) / 1000
        timeout = params.seconds("timeout")
        robot = self.require_session()
        self.claim(ident, "sample")
        try:
            return await self.on_worker(self.sample, robot, ident, name, count, interval, timeout, cancel)
        finally:
            self.release(ident)

    def sample(self, robot, ident, name, count, interval, timeout, cancel):
        budget = Budget(robot.stop_event, timeout, cancel)
        target = robot.registry.require(name)
        previous = [(var, var.budget) for var in robot.registry.values() if hasattr(var, "budget")]
        last_count, sent = 0, 0
        try:
            for var, _ in previous:
                var.budget = budget
            for index in range(count):
                budget.check()
                if index and interval:
                    cancel.wait(interval if budget.deadline is None
                                else min(interval, max(0, budget.deadline - time.monotonic())))
                    budget.check()
                if target.kind == "daemon":
                    while True:
                        try:
                            value = target.wait_for_sample(after=last_count, timeout=0.25)
                            break
                        except TimeoutError:
                            budget.check()
                    last_count = value["count"]
                else:
                    value = target.read()
                if isinstance(value, dict):
                    ensure_ok(value, f"sample {name}")
                if len(dumps(value).encode("utf-8")) > MAX_BODY:
                    raise SecurityError("One sample exceeds the 8 MiB message budget")
                budget.check()
                self.notify("sample", {"id": ident, "index": index, "value": value, "t": time.time()})
                sent += 1
                budget.check()
            return {"name": name, "count": sent}
        finally:
            for var, old in previous:
                var.budget = old

    # -- agent -------------------------------------------------------------
    async def m_agent_ask(self, ident, params, cancel):
        if not self.enable_agent:
            raise RpcError(METHOD_NOT_FOUND, "Agent methods are disabled (--no-agent)")
        task = params.text("task", required=True, cap=16 * 1024)
        if not task.strip():
            raise RpcError(INVALID_PARAMS, "'task' must not be empty")
        key = {
            "robot": params.text("robot", required=True), "modulePaths": params.strings("modulePaths"),
            "cameraSrcDir": params.text("cameraSrcDir"), "scriptsDir": params.text("scriptsDir", required=True),
            "skillsDir": params.text("skillsDir"), "model": params.text("model", "", cap=1024),
            "baseUrl": params.text("baseUrl", cap=2048), "apiKeyEnv": params.text("apiKeyEnv", cap=256),
            "readVars": params.strings("readVars", ident=True), "cameraVars": params.strings("cameraVars", ident=True),
            "allowActions": params.flag("allowActions"), "allowHardware": params.flag("allowHardware"),
            "vars": params.bindings("vars"),
            "timeout": params.seconds("timeout", 180), "maxRequests": params.integer("maxRequests", 1, 100, 8),
            "maxToolCalls": params.integer("maxToolCalls", 1, 1000, 16),
            "historyTurns": params.integer("historyTurns", 1, 20, 6),
            "maxHistoryBytes": params.integer("maxHistoryBytes", 64 * 1024, 64 * 1024 * 1024,
                                              4 * 1024 * 1024),
            "promptFile": params.text("promptFile", cap=4096),
            "contextBytes": params.integer("contextBytes", 0, 64 * 1024, 4 * 1024),
            "mcpConfig": params.text("mcpConfig", cap=4096), "allowMcpTools": params.flag("allowMcpTools"),
            "workspaceDir": params.text("workspaceDir", cap=4096),
            "enableShell": params.flag("enableShell"), "allowShell": params.flag("allowShell"),
            "allowFileWrites": params.flag("allowFileWrites"),
        }
        self.require_owner("agent")
        if self.agent_lock.locked():
            raise RpcError(BUSY, "Another agent turn is running")
        async with self.agent_lock:
            self.owner = "agent"
            try:
                if self.agent is not None and self.agent_key != key:
                    await self.close_agent()
                if self.agent is None:
                    async def open_conversation():
                        self.agent = await self.open_agent(key)
                        self.agent_key = key
                    # Cancellation must not orphan resources created during initialization.
                    await self.finish(asyncio.create_task(open_conversation()),
                                      lambda: self.cancel({"id": ident}))
                    self.notify("session", self.status())
                session = self.agent["session"]
                session.on_event = lambda event: self.notify("agent.event", {"id": ident, "event": event})
                self.requests[ident]["hooks"].append(session.executor.cancel)
                if cancel.is_set():
                    session.executor.cancel()
                mark = len(session.events)
                try:
                    result = await session.ask(task)
                except BaseException as exc:
                    from .agent import AgentError, describe_failure, request_endpoint
                    events = session.events[mark:]
                    endpoint = request_endpoint(self.agent["client"])
                    if not isinstance(exc, (AgentError, AgentInterrupted, asyncio.CancelledError)):
                        exc = AgentError(f"Agent failed ({describe_failure(exc, endpoint)}); check configuration or tool receipts. "
                                         "Already dispatched actions are not rolled back or automatically retried")
                    exc.tool_events = events
                    raise exc from None
                return {**result, "tool_events": session.events[mark:]}
            except BaseException:
                await self.close_agent()
                raise
            finally:
                if self.agent is None:
                    self.owner = None

    async def open_agent(self, key):
        from .agent import AgentConfig, AgentConfigurationError, AgentSession, create_model
        from .agent_executor import RobotExecutor
        from .agent_skills import SkillsLibrary, default_skills_root
        from .session_log import create_session_log
        workspace = Path(key["workspaceDir"]).absolute() if key["workspaceDir"] else None
        if key["enableShell"] and workspace is None:
            raise AgentConfigurationError("Shell tools require a workspace; no model request was sent")
        if key["allowShell"] and not key["enableShell"]:
            raise AgentConfigurationError("allowShell requires enableShell; no model request was sent")
        if key["allowFileWrites"] and workspace is None:
            raise AgentConfigurationError("File writes require a workspace; no model request was sent")
        config = AgentConfig(model=key["model"] or os.environ.get("MYBOT_MODEL", ""),
                             base_url=key["baseUrl"] or os.environ.get("MYBOT_BASE_URL"),
                             api_key_env=key["apiKeyEnv"], timeout=key["timeout"],
                             request_limit=key["maxRequests"], tool_calls_limit=key["maxToolCalls"],
                             history_turns=key["historyTurns"], history_bytes=key["maxHistoryBytes"],
                             allow_actions=key["allowActions"],
                             allow_shell=key["allowShell"], allow_file_writes=key["allowFileWrites"],
                             mcp_config=key["mcpConfig"] or None,
                             allow_mcp_tools=key["allowMcpTools"],
                             prompt_file=key.get("promptFile") or None,
                             context_bytes=key.get("contextBytes", 4 * 1024))
        from .mcp_client import load_servers
        try:
            mcp_servers = load_servers(config.mcp_config)
        except Exception as exc:
            raise AgentConfigurationError(
                f"Cannot load MCP configuration: {exc}; no model request was sent") from None
        model, client = create_model(config)
        executor = None
        session_log = None
        try:
            session_log = create_session_log(enabled=self.enable_session_log, robot=key["robot"],
                                             model=config.model, mode="serve")
            skills = SkillsLibrary(key["skillsDir"] or default_skills_root(), required=key["skillsDir"] is not None)
            executor = RobotExecutor(key["robot"], module_paths=key["modulePaths"] or None,
                                     camera_src_root=key["cameraSrcDir"], scripts_dir=key["scriptsDir"],
                                     allow_hardware=key["allowHardware"], read_vars=key["readVars"],
                                     camera_vars=key["cameraVars"], vars=key["vars"], skills=skills,
                                     workspace_dir=workspace, enable_shell=key["enableShell"])

            async def confirm(name, arguments):
                reply = await self.ask_client("confirm", {"tool": name, "arguments": arguments})
                return isinstance(reply, dict) and reply.get("approved") is True

            session = AgentSession(executor, model, config, confirm=confirm, read_vars=key["readVars"],
                                   camera_vars=key["cameraVars"], skills=skills, session_log=session_log,
                                   workspace=workspace is not None, enable_shell=key["enableShell"],
                                   mcp_servers=mcp_servers)
            return {"session": session, "client": client}
        except BaseException as exc:
            try:
                if executor is not None:
                    await executor.close()
            finally:
                if session_log is not None:
                    session_log.close()
                await client.close()
            if isinstance(exc, SecurityError):
                raise AgentConfigurationError(f"Cannot load skills configuration: {exc}; no model request was sent") from None
            raise

    async def close_agent(self):
        # Retain ownership until both resources finish closing.
        agent = self.agent
        if agent is None:
            return

        async def close():
            try:
                for resource in (agent["session"], agent["client"]):
                    try:
                        await resource.close()
                    except BaseException as exc:
                        print(f"pymybot serve: agent cleanup: {type(exc).__name__}", file=sys.stderr)
            finally:
                self.agent = self.agent_key = None
                self.notify("session", self.status())
        cancelled = False
        while self.agent is agent:
            try:
                await self.finish(asyncio.create_task(close()))
                break
            except asyncio.CancelledError:
                cancelled = True
        if cancelled:
            raise asyncio.CancelledError

    async def m_agent_reset(self, ident, params, cancel):
        if self.agent_lock.locked():
            raise RpcError(BUSY, "Cancel the running agent turn first")
        async with self.agent_lock:
            try:
                await self.close_agent()
            finally:
                if self.owner == "agent":
                    self.owner = None
        return self.status()

    async def m_shutdown(self, ident, params, cancel):
        self.closing = True
        return {}

    async def shutdown(self):
        self.closing = True
        for ident in list(self.requests):
            self.cancel({"id": ident})
        for call in list(self.client_calls.values()):
            if not call.future.done():
                call.future.set_result(None)
        current = asyncio.current_task()
        pending = [task for task in self.tasks if task is not current]
        if pending:
            await asyncio.wait(pending, timeout=35)
        try:
            await self.deactivate()
        finally:
            try:
                async with self.agent_lock:
                    try:
                        await self.close_agent()
                    finally:
                        if self.owner == "agent":
                            self.owner = None
            finally:
                await asyncio.to_thread(self.worker.shutdown, wait=True)


def _reader(fd, queue, loop):
    """Read JSONL from a raw file descriptor without holding a buffered-I/O lock.

    ``sys.stdin.buffer.readline`` keeps the BufferedReader lock while it waits
    for the next line. The main thread may exit on ``shutdown`` while the parent
    still holds the pipe open; finalizing the interpreter then aborts with
    ``_enter_buffered_busy`` because a daemon thread owns that lock. Raw
    ``os.read`` lets the daemon block in the kernel instead, so interpreter
    shutdown stays quiet even when the client never closes stdin.
    """
    def put(item):
        loop.call_soon_threadsafe(queue.put_nowait, item)

    pending = b""
    discarding = False

    def emit(line):
        nonlocal discarding
        if discarding:
            discarding = False
            put(ValueError("Message exceeds the line limit"))
            return
        if len(line) > MAX_LINE:
            put(ValueError("Message exceeds the line limit"))
        elif line.strip():
            put(line.decode("utf-8"))

    try:
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                if discarding:
                    put(ValueError("Message exceeds the line limit"))
                elif pending:
                    emit(pending)
                break
            pending += chunk
            while True:
                newline = pending.find(b"\n")
                if newline < 0:
                    break
                line, pending = pending[:newline], pending[newline + 1:]
                emit(line)
            if len(pending) > MAX_LINE:
                pending = b""
                discarding = True
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print(f"pymybot serve: stdin: {exc}", file=sys.stderr)
    finally:
        try:
            put(None)
        except RuntimeError:
            pass


async def _main(out, stop, enable_agent, enable_session_log):
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    server = Server(out, stop, enable_agent=enable_agent, enable_session_log=enable_session_log)
    threading.Thread(target=_reader, args=(sys.stdin.fileno(), queue, loop), name="serve-stdin", daemon=True).start()

    async def watch_stop():
        while not stop.is_set() and not server.closing:
            await asyncio.sleep(0.05)
        queue.put_nowait(None)

    watcher = loop.create_task(watch_stop())
    try:
        await server.serve(queue)
    finally:
        watcher.cancel()
    return {"stopped": stop.is_set()}


def run_server(stop, *, enable_agent=True, enable_session_log=True):
    """Serve on the original stdout; fd 1 points at stderr until return."""
    sys.stdout.flush()
    sys.__stdout__.flush()
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    out = open(os.dup(protocol_fd), "w", encoding="utf-8", newline="\n")
    try:
        return asyncio.run(_main(out, stop, enable_agent, enable_session_log))
    finally:
        out.close()
        os.dup2(protocol_fd, 1)
        os.close(protocol_fd)
