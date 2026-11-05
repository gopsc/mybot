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

    def flag(self, key, default=False):
        return self._get(key, (bool,), default, False)

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
    return importlib.util.find_spec("langgraph") is not None


class _RobotSession:
    """One named robot session: its own Robot, owner thread and busy state.

    Sessions are isolated from each other — a long action on one robot never
    blocks a sample on another — while the single ``owner`` flag still keeps
    the whole session layer mutually exclusive with the agent.
    """

    __slots__ = ("name", "robot", "info", "worker", "op", "idle")

    def __init__(self, name):
        self.name = name
        self.robot = None
        self.info = {}
        self.op = None
        self.idle = asyncio.Event()
        self.idle.set()
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"serve-robot-{name}")


class Server:
    def __init__(self, out, stop, *, enable_agent=True, enable_session_log=True):
        self.out = out
        self.stop = stop
        self.enable_agent = enable_agent
        self.enable_session_log = enable_session_log
        self._write_lock = threading.Lock()
        self.sessions: dict[str, _RobotSession] = {}
        self._activating: dict[str, _RobotSession] = {}
        # Ownership includes initialization and cleanup, not just published objects.
        self.owner = None
        self._root_idle = asyncio.Event()
        self._root_idle.set()
        self.deactivating: dict[str, asyncio.Task] = {}
        self.requests = {}
        self.tasks = set()
        self.client_calls = {}
        self.client_seq = 0
        self.agent = None
        self.agent_key = None
        self.agent_lock = asyncio.Lock()
        self.closing = False

    # -- compatibility views over the default (or single) session ----------
    @property
    def robot(self):
        entry = self._any_session()
        return entry.robot if entry is not None else None

    @property
    def session(self):
        entry = self._any_session()
        return entry.info if entry is not None else None

    @property
    def robot_idle(self):
        entry = self._any_session()
        return entry.idle if entry is not None else self._root_idle

    @property
    def robot_op(self):
        entry = self._any_session()
        return entry.op if entry is not None else None

    def _any_session(self):
        if not self.sessions:
            return None
        return self.sessions.get("default") or next(iter(self.sessions.values()))

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
    @staticmethod
    def _session_name(params):
        name = params.text("session", cap=64) or "default"
        try:
            safe_ident(name)
        except ValueError as exc:
            raise RpcError(INVALID_PARAMS, f"'session': {exc}") from None
        return name

    def _session(self, name=None, *, required=True):
        key = name or "default"
        entry = self.sessions.get(key)
        if entry is None and required:
            raise RpcError(WRONG_STATE, f"No active session {key!r}; call session.activate first")
        return entry

    async def on_worker(self, fn, *args, entry=None):
        entry = entry if entry is not None else self._session()
        future = asyncio.get_running_loop().run_in_executor(entry.worker, fn, *args)
        operation = entry.op
        await_cancel = (lambda: self.cancel({"id": operation[0]})) if operation else None
        return await self.finish(future, await_cancel)

    def claim(self, ident, method, entry):
        self.require_owner("session")
        if self.deactivating.get(entry.name) is not None:
            raise RpcError(BUSY, "Session is deactivating")
        if entry.op is not None:
            raise RpcError(BUSY, f"Session {entry.name!r} is busy with '{entry.op[1]}'")
        entry.op = (ident, method)
        entry.idle.clear()

    def release(self, ident, entry):
        if entry.op and entry.op[0] == ident:
            entry.op = None
            entry.idle.set()

    def require_session(self, name=None):
        entry = self._session(name)
        if entry.robot is None:
            raise RpcError(WRONG_STATE, "No active session; call session.activate first")
        return entry

    def status(self, entry=None):
        sessions = [{"session": entry.name,
                     "robot": entry.info.get("robot"),
                     "busy": entry.op[1] if entry.op else None}
                    for entry in self.sessions.values()]
        ops = [entry.op[1] for entry in (*self.sessions.values(), *self._activating.values())
               if entry.op is not None]
        view = entry if entry is not None else self._any_session()
        return {"state": "Active" if self.sessions else "Inactive",
                **(view.info if view is not None else {}),
                "busy": ops[0] if ops else None,
                "agent": self.agent is not None, "sessions": sessions}

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
        allow_hardware = params.flag("allowHardware")
        bindings = params.bindings("vars")
        name = self._session_name(params)
        self.require_owner("session")
        if name in self._activating or self.deactivating.get(name) is not None:
            raise RpcError(BUSY, "Session is activating or deactivating")
        if name in self.sessions:
            raise RpcError(WRONG_STATE, f"Session {name!r} already active; deactivate it first")
        entry = _RobotSession(name)
        self._activating[name] = entry
        self.claim(ident, "session.activate", entry)
        self.owner = "session"
        holder = {}
        self.requests[ident]["hooks"].append(lambda: holder.get("robot") and holder["robot"].stop_event.set())

        def activate():
            path = Path(robot_path).absolute()
            robot = Robot(read_file(path), module_paths=module_paths,
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
            robot, hardware = await self.on_worker(activate, entry=entry)
            if cancel.is_set():
                raise BudgetExceeded("Stop requested; activation rolled back")
            entry.robot = robot
            entry.info = {"robot": robot.structure_path, "allowHardware": allow_hardware,
                          "since": time.time(), "session": name}
            self.sessions[name] = entry
        except BaseException:
            # The owner thread must also clean partially completed activation.
            if "robot" in holder:
                await self.on_worker(holder["robot"].deactivate, entry=entry)
            entry.worker.shutdown(wait=True)
            raise
        finally:
            self.release(ident, entry)
            self._activating.pop(name, None)
            if not self.sessions and self.owner == "session":
                self.owner = None
        self.notify("session", self.status())
        return {**self.status(entry), "hardware": hardware}

    async def m_session_deactivate(self, ident, params, cancel):
        if params.raw.get("session") is None:
            # Omitted session means "tear everything down" (back-compat path).
            await self.deactivate()
        else:
            await self.deactivate(self._session_name(params))
        return self.status()

    async def m_abort(self, ident, params, cancel):
        """Best-effort stop for whichever side currently owns the hardware."""
        if self.agent is not None:
            return await self._abort_agent()
        if self.sessions:
            return await self._abort_session()
        return {"state": "Inactive", "aborted": False, "agent": False,
                "safe_failures": [], "destroy_failures": []}

    async def m_session_abort(self, ident, params, cancel):
        return await self._abort_session(
            self._session_name(params) if params.raw.get("session") is not None else None)

    async def _abort_session(self, name=None):
        """Best-effort stop for direct robot sessions; named abort ends that one,
        unnamed abort ends every session."""
        targets = ([self._session(name)] if name is not None
                   else list(self.sessions.values()))
        if not targets:
            return {"state": "Inactive", "aborted": False,
                    "safe_failures": [], "destroy_failures": []}
        self.require_owner("session")
        safe_failures, destroy_failures = [], []
        receipt = None
        for entry in targets:
            robot = entry.robot
            if robot is None:
                continue
            # Wake a running cooperative action before waiting for the owner
            # thread; the abort task itself is queued behind that action.
            robot.stop_event.set()
            if entry.op is not None:
                self.cancel({"id": entry.op[0]})
            try:
                receipt = await self.on_worker(robot.abort, "operator", entry=entry)
            finally:
                self.sessions.pop(entry.name, None)
                entry.worker.shutdown(wait=True)
            data = receipt.get("data") if isinstance(receipt, dict) else None
            body = data if isinstance(data, dict) else receipt
            if isinstance(body, dict):
                safe_failures.extend(body.get("safe_failures") or [])
                destroy_failures.extend(body.get("destroy_failures") or [])
        self.notify("session", self.status())
        if not self.sessions and self.owner == "session":
            self.owner = None
        base = receipt if isinstance(receipt, dict) else {}
        merged = {"aborted": bool(targets),
                  "safe_failures": safe_failures, "destroy_failures": destroy_failures}
        merged.update({key: value for key, value in base.items() if key != "data"})
        return merged

    async def m_agent_abort(self, ident, params, cancel):
        return await self._abort_agent()

    async def _abort_agent(self):
        """Stop the active Agent executor and close an idle conversation."""
        agent = self.agent
        if agent is None:
            return {"state": "Inactive", "aborted": False, "agent": False,
                    "safe_failures": [], "destroy_failures": []}
        session = agent["session"]
        cancel_team = getattr(session, "cancel", None)
        if callable(cancel_team):
            cancel_team()
        session.executor.cancel()
        result = await session.executor.abort()
        data = result.get("data") if isinstance(result, dict) else None
        receipt = data if isinstance(data, dict) else result
        closed = not self.agent_lock.locked()
        if closed:
            async with self.agent_lock:
                await self.close_agent()
                if self.owner == "agent":
                    self.owner = None
        if isinstance(result, dict) and result.get("ok") is False:
            receipt = {**result, "aborted": False}
        return {**receipt, "agent": True, "conversationClosed": closed}

    async def deactivate(self, name=None):
        """Deactivate one named session, or every session when unnamed.

        A session that is still activating is also targeted: the wait covers
        its rollback, so deactivation never completes before cleanup does.
        """
        names = [name] if name is not None else [*self.sessions, *self._activating]
        cancelled = False
        while any(self.owner == "session"
                  and (item in self.sessions or item in self._activating
                       or self.deactivating.get(item) is not None)
                  for item in names):
            # A cleanup task cancelled before its first step never ran its
            # finally, so it stays behind as a done entry; drop finished tasks
            # or the loop would never recreate them and spin forever.
            for item, task in list(self.deactivating.items()):
                if task.done():
                    self.deactivating.pop(item, None)
            for item in names:
                if ((item in self.sessions or item in self._activating)
                        and self.deactivating.get(item) is None):
                    self.deactivating[item] = asyncio.create_task(self._deactivate(item))
            try:
                if self.deactivating:
                    await asyncio.gather(*(self.finish(task) for task in tuple(self.deactivating.values())),
                                         return_exceptions=False)
                break
            except asyncio.CancelledError:
                cancelled = True
        if cancelled:
            raise asyncio.CancelledError

    async def _deactivate(self, name):
        cancelled = False
        entry = self.sessions.get(name) or self._activating.get(name)
        try:
            if entry is None:
                return
            if entry.op is not None:
                self.cancel({"id": entry.op[0]})
            # Loop-wide cancellation can target this cleanup task directly.
            while True:
                try:
                    await entry.idle.wait()
                    break
                except asyncio.CancelledError:
                    cancelled = True
            # An activation still in flight cleans up after its own rollback;
            # only a published session deactivates its robot here.
            if entry.robot is not None and name in self.sessions:
                await self.on_worker(entry.robot.deactivate, entry=entry)
        finally:
            # A failed or cancelled deactivation still ends the session, exactly
            # like the previous single-session teardown did.
            if name in self.sessions:
                self.sessions.pop(name, None)
                entry.worker.shutdown(wait=True)
            self.deactivating.pop(name, None)
            if not self.sessions and not self._activating and self.owner == "session":
                self.owner = None
            self.notify("session", self.status())
        if cancelled:
            raise asyncio.CancelledError

    async def m_run(self, ident, params, cancel):
        source = params.text("input", required=True)
        bindings = params.bindings("vars")
        timeout = params.seconds("timeout", 180)
        entry = self.require_session(self._session_name(params))
        robot = entry.robot
        self.claim(ident, "run", entry)
        try:
            path = Path(source).absolute()
            def run():
                return robot.run(read_file(path), base_dir=str(path.parent), vars=bindings,
                                 timeout=timeout, cancel=cancel)
            return {"outputs": await self.on_worker(run, entry=entry)}
        finally:
            self.release(ident, entry)

    async def m_apply_sql(self, ident, params, cancel):
        sql = params.text("sql", required=True)
        entry = self.require_session(self._session_name(params))
        robot = entry.robot
        self.claim(ident, "apply-sql", entry)
        try:
            output = await self.on_worker(lambda: robot.apply_sql(sql, cancel=cancel), entry=entry)
            hardware = [{"name": name, "type": table.name}
                        for name, (table, row) in robot._rows(robot.tables).items()
                        if table.name not in {"Alias", "Vars"}]
            return {"output": output, "hardware": hardware}
        finally:
            self.release(ident, entry)

    async def m_sample(self, ident, params, cancel):
        name = params.text("name", required=True)
        try:
            safe_ident(name)
        except ValueError as exc:
            raise RpcError(INVALID_PARAMS, str(exc)) from None
        count = params.integer("count", 1, MAX_SAMPLES, default=1)
        interval = params.integer("intervalMs", 0, 60000, default=0) / 1000
        timeout = params.seconds("timeout")
        entry = self.require_session(self._session_name(params))
        robot = entry.robot
        self.claim(ident, "sample", entry)
        try:
            return await self.on_worker(self.sample, robot, ident, name, count, interval,
                                        timeout, cancel, entry=entry)
        finally:
            self.release(ident, entry)

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

    # -- roles -------------------------------------------------------------
    async def m_roles_list(self, ident, params, cancel):
        from .roles import list_roles, roles_root
        roles = await asyncio.to_thread(list_roles)
        return {"root": str(roles_root()), "roles": roles}

    async def m_roles_create(self, ident, params, cancel):
        from .roles import create_role
        name = params.text("name", required=True, cap=64)
        description = params.text("description", "", cap=1024)
        skills_dir = params.text("skillsDir", cap=4096)
        mcp_config = params.text("mcpConfig", cap=4096)
        role = await asyncio.to_thread(create_role, name, description=description,
                                       skills_from=skills_dir or None, mcp_from=mcp_config or None)
        return role.info()

    async def m_roles_show(self, ident, params, cancel):
        from .roles import load_role
        name = params.text("name", required=True, cap=64)
        role = await asyncio.to_thread(load_role, name)
        return role.info()

    async def m_roles_clear_history(self, ident, params, cancel):
        from .roles import clear_role_history
        name = params.text("name", required=True, cap=64)
        if self.agent is not None and getattr(self.agent["session"], "role", None) is not None \
                and self.agent["session"].role.name == name:
            raise RpcError(WRONG_STATE, "Close this role's Agent conversation before clearing its history")
        return await asyncio.to_thread(clear_role_history, name)

    # -- agent -------------------------------------------------------------
    def _agent_key(self, params):
        return {
            "role": params.text("role", cap=64),
            "robot": params.text("robot"), "modulePaths": params.strings("modulePaths"),
            "scriptsDir": params.text("scriptsDir"),
            "skillsDir": params.text("skillsDir"), "model": params.text("model", "", cap=1024),
            "baseUrl": params.text("baseUrl", cap=2048), "apiKeyEnv": params.text("apiKeyEnv", cap=256),
            "allowActions": params.flag("allowActions"), "allowHardware": params.flag("allowHardware"),
            "allowShell": params.flag("allowShell"),
            "vars": params.bindings("vars"),
            "timeout": params.seconds("timeout", 180),
            "maxHistoryBytes": params.integer("maxHistoryBytes", 64 * 1024, 64 * 1024 * 1024,
                                              4 * 1024 * 1024),
            "maxContextTokens": params.integer("maxContextTokens", 1024, 2 * 1024 * 1024),
            "contextReserveTokens": params.integer("contextReserveTokens", 0, 64 * 1024, 2048),
            "hotTurns": params.integer("hotTurns", 1, 50, 3),
            "warmTurns": params.integer("warmTurns", 0, 200, 10),
            "promptFile": params.text("promptFile", cap=4096),
            "autoStats": params.flag("autoStats", default=True),
            "contextBytes": params.integer("contextBytes", 0, 64 * 1024, 4 * 1024),
            "intent": params.text("intent", cap=32),
            "sandbox": params.text("sandbox", cap=16),
            "protectPrompts": params.flag("protectPrompts", default=True),
            "enableWeb": params.flag("enableWeb"), "allowWeb": params.flag("allowWeb"),
            "searchEndpoint": params.text("searchEndpoint", cap=4096),
            "mcpConfig": params.text("mcpConfig", cap=4096), "allowMcpTools": params.flag("allowMcpTools"),
            "workspaceDir": params.text("workspaceDir", cap=4096),
            "enableShell": params.flag("enableShell"),
            "allowFileWrites": params.flag("allowFileWrites"),
            "teamSteps": params.integer("teamSteps", 1, 50, 8),
            "missionTimeout": params.seconds("missionTimeout", 1800),
            "missionTokens": params.integer("missionTokens", 1024, 10_000_000, 400_000),
            "maxRequests": params.integer("maxRequests", 1, 10_000, 64),
            "maxToolCalls": params.integer("maxToolCalls", 1, 100_000, 128),
            "turnTimeout": params.integer("turnTimeout", 0, 86400, 0),
            "modelRetries": params.integer("modelRetries", 0, 10, 0),
            "fallbackModels": params.strings("fallbackModels"),
            "requirePlanApproval": params.flag("requirePlanApproval"),
        }

    async def m_agent_ask(self, ident, params, cancel):
        if not self.enable_agent:
            raise RpcError(METHOD_NOT_FOUND, "Agent methods are disabled (--no-agent)")
        task = params.text("task", required=True, cap=16 * 1024)
        if not task.strip():
            raise RpcError(INVALID_PARAMS, "'task' must not be empty")
        key = self._agent_key(params)
        if not key["role"]:
            raise RpcError(INVALID_PARAMS, "Agent conversations require a role; pass 'role' "
                                           "(create one with 'pymybot roles create NAME')")
        self.require_owner("agent")
        if self.agent_lock.locked():
            raise RpcError(BUSY, "Another agent turn is running")
        async with self.agent_lock:
            self.owner = "agent"
            try:
                session = await self._prepare_agent(ident, key)
                if cancel.is_set():
                    session.executor.cancel()
                mark = len(session.events)
                status = getattr(session, "auto_status", None)
                if callable(status) and status().get("running"):
                    if status().get("state") in {"idle", "thinking"} \
                            and callable(getattr(session, "auto_stop", None)):
                        # One-shot work takes over an idle autonomous loop.
                        await session.auto_stop()
                    else:
                        raise RpcError(BUSY, "An autonomous loop is already running; stop it first")
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

    async def m_agent_status(self, ident, params, cancel):
        if self.agent is None:
            return {"state": "idle", "running": False, "mission": None, "memory": None}
        session = self.agent["session"]
        status = getattr(session, "auto_status", None)
        return status() if callable(status) else {"state": "single", "running": False}

    async def m_agent_start(self, ident, params, cancel):
        key = self._agent_key(params)
        if not key["role"]:
            raise RpcError(INVALID_PARAMS, "Autonomous missions require a role")
        self.require_owner("agent")
        if self.agent_lock.locked():
            raise RpcError(BUSY, "Another agent turn is running")
        async with self.agent_lock:
            self.owner = "agent"
            try:
                session = await self._prepare_agent(ident, key)
                status = getattr(session, "auto_status", None)
                if callable(status) and status().get("running"):
                    raise RpcError(BUSY, "An autonomous loop is already running; stop it first")
                seed = params.text("task", cap=16 * 1024)
                await session.auto_start(
                    seed or None,
                    max_missions=params.integer("maxMissions", 1, 1000, 20),
                    max_seconds=params.seconds("maxSeconds", 3600),
                    pause=params.seconds("pauseSeconds", 1))
                return session.auto_status()
            except BaseException:
                await self.close_agent()
                raise
            finally:
                if self.agent is None:
                    self.owner = None

    async def m_agent_memory(self, ident, params, cancel):
        if self.agent is None:
            return {"entries": [], "stats": None}
        session = self.agent["session"]
        review = getattr(session, "memory_review", None)
        if not callable(review):
            return {"entries": [], "stats": None}
        return await asyncio.to_thread(
            review, params.integer("limit", 1, 500, 50),
            kinds=params.strings("kinds") or None, tags=params.strings("tags") or None)

    async def m_agent_forget_memory(self, ident, params, cancel):
        if self.agent is None:
            return {"removed": [], "count": 0}
        session = self.agent["session"]
        forget = getattr(session, "forget_memory", None)
        if not callable(forget):
            raise RpcError(METHOD_NOT_FOUND, "This agent has no long-term memory store")
        status = getattr(session, "auto_status", None)
        if callable(status) and status().get("running"):
            raise RpcError(BUSY, "Stop the autonomous loop before editing long-term memory")
        return await asyncio.to_thread(
            forget, params.strings("ids") or None,
            kinds=params.strings("kinds") or None, tags=params.strings("tags") or None)

    async def m_agent_missions(self, ident, params, cancel):
        if self.agent is None:
            return {"missions": []}
        session = self.agent["session"]
        review = getattr(session, "mission_review", None)
        if not callable(review):
            return {"missions": []}
        return await asyncio.to_thread(review, params.integer("limit", 1, 200, 20))

    async def m_agent_stop(self, ident, params, cancel):
        if self.agent is None:
            return {"state": "idle", "running": False}
        session = self.agent["session"]
        stop = getattr(session, "auto_stop", None)
        if not callable(stop):
            return {"state": "single", "running": False}
        return await stop()

    async def _prepare_agent(self, ident, key):
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
        return session

    async def open_agent(self, key):
        from .agent import AgentConfig, AgentConfigurationError, AgentSession, create_model
        from .agent_executor import RobotExecutor
        from .agent_skills import SkillsLibrary, default_skills_root
        from .session_log import create_session_log
        from .roles import load_role
        try:
            role = load_role(key["role"]) if key.get("role") else None
        except (OSError, SecurityError) as exc:
            raise AgentConfigurationError(f"Cannot load role: {exc}; no model request was sent") from None
        if role is not None:
            # The CLI rejects role + path overrides; the JSON-RPC surface must
            # not silently ignore a conflicting value either.
            for name, owned in (("workspaceDir", role.workspace_dir),
                                ("skillsDir", role.skills_dir),
                                ("mcpConfig", role.mcp_config)):
                value = key.get(name)
                if not value:
                    continue
                actual = os.path.normcase(os.path.abspath(os.path.expanduser(str(value))))
                expected = os.path.normcase(str(Path(owned).absolute()))
                if actual != expected:
                    raise AgentConfigurationError(
                        f"Role '{role.name}' owns {name}; omit it or use the role path")
        mcp_config = (str(role.mcp_config) if role is not None and role.mcp_config.is_file()
                      else key["mcpConfig"] or None if role is None else None)
        workspace = (role.workspace_dir if role is not None
                     else Path(key["workspaceDir"]).absolute() if key["workspaceDir"] else None)
        if key["enableShell"] and workspace is None:
            raise AgentConfigurationError("Shell tools require a workspace; no model request was sent")
        if key["allowFileWrites"] and workspace is None:
            raise AgentConfigurationError("File writes require a workspace; no model request was sent")
        if key["robot"] and not Path(key["robot"]).is_file():
            raise AgentConfigurationError(
                f"Robot structure not found: {key['robot']}; no model request was sent")
        config = AgentConfig(model=key["model"] or os.environ.get("MYBOT_MODEL", ""),
                             base_url=key["baseUrl"] or os.environ.get("MYBOT_BASE_URL"),
                             api_key_env=key["apiKeyEnv"], timeout=key["timeout"],
                             history_bytes=key["maxHistoryBytes"],
                             max_context_tokens=key.get("maxContextTokens"),
                             context_reserve_tokens=key.get("contextReserveTokens", 2048),
                             allow_actions=key["allowActions"],
                             allow_file_writes=key["allowFileWrites"],
                             allow_shell=key["allowShell"],
                             mcp_config=mcp_config,
                             allow_mcp_tools=key["allowMcpTools"],
                             prompt_file=key.get("promptFile") or None,
                             auto_stats=key.get("autoStats", True),
                             context_bytes=key.get("contextBytes", 4 * 1024),
                             intent_mode=key.get("intent") or "auto",
                             sandbox_mode=key.get("sandbox") or "auto",
                             protect_prompts=key.get("protectPrompts", True),
                             enable_web=key.get("enableWeb", False),
                             allow_web=key.get("allowWeb", False),
                             search_endpoint=key.get("searchEndpoint") or "",
                             hot_turns=key.get("hotTurns", 3),
                             warm_turns=key.get("warmTurns", 10),
                             max_requests=key.get("maxRequests", 64),
                             max_tool_calls=key.get("maxToolCalls", 128),
                             turn_timeout=key.get("turnTimeout", 0) or 0,
                             model_retries=key.get("modelRetries", 0),
                             fallback_models=tuple(key.get("fallbackModels") or ()))
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
            session_log = create_session_log(enabled=self.enable_session_log, robot=key["robot"] or "",
                                             model=config.model, mode="serve",
                                             role=role.name if role is not None else "")
            skills_dir = role.skills_dir if role is not None else (key["skillsDir"] or default_skills_root())
            skills = SkillsLibrary(skills_dir, required=role is not None or key["skillsDir"] is not None)
            executor = RobotExecutor(key["robot"] or None, module_paths=key["modulePaths"] or None,
                                     scripts_dir=key["scriptsDir"] or None,
                                     allow_hardware=key["allowHardware"],
                                     vars=key["vars"], skills=skills,
                                     workspace_dir=workspace, enable_shell=key["enableShell"],
                                     sandbox=config.sandbox_mode)

            async def confirm(name, arguments):
                reply = await self.ask_client("confirm", {"tool": name, "arguments": arguments})
                return isinstance(reply, dict) and reply.get("approved") is True

            worker = AgentSession(executor, model, config, confirm=confirm,
                                  skills=skills, session_log=session_log,
                                  workspace=workspace is not None, enable_shell=key["enableShell"],
                                  mcp_servers=mcp_servers, role=role)
            from .agent_team import TeamSession
            session = TeamSession(worker, model, role=role,
                                  max_steps=key.get("teamSteps", 8),
                                  max_seconds=key.get("missionTimeout", 1800),
                                  max_tokens=key.get("missionTokens", 400_000),
                                  confirm=confirm,
                                  require_plan_approval=key.get("requirePlanApproval", False))
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
        clear_history = params.flag("clearHistory")
        role_name = params.text("role", cap=64)
        if self.agent_lock.locked():
            raise RpcError(BUSY, "Cancel the running agent turn first")
        async with self.agent_lock:
            try:
                # The request names the role the operator is looking at; only fall
                # back to the active conversation's role when the caller sent none.
                # Overwriting it would erase an inactive role after a role switch.
                if not role_name and self.agent is not None:
                    active_role = getattr(self.agent["session"], "role", None)
                    if active_role is not None:
                        role_name = active_role.name
                await self.close_agent()
                if clear_history and role_name:
                    from .roles import clear_role_history
                    await asyncio.to_thread(clear_role_history, role_name)
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
                workers = [entry.worker for entry in list(self.sessions.values())]
                self.sessions.clear()
                if workers:
                    await asyncio.to_thread(lambda: [worker.shutdown(wait=True) for worker in workers])


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
