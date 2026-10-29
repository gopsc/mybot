"""Standard MCP over stdio; one operator-configured robot per process.

The server is a thin protocol adapter over RobotExecutor, so it inherits the
same owner-thread serialization, bounded receipts and fault latching as agent
mode. It is read-only by default: execution tools answer ``not_executed``
unless ``--allow-execution`` was passed, and physical hardware still requires
the separate ``--allow-hardware`` switch. The config file, trusted .mt scripts
and Lua drivers are operator-owned inputs, not a sandbox.

stdout is reserved for MCP JSON-RPC; fd 1 is redirected to stderr while
serving, so Lua or native output cannot corrupt the protocol stream.
"""
from __future__ import annotations

import asyncio
import base64
from contextlib import contextmanager
import math
import os
import sys
import threading
import time
from urllib.parse import quote

import anyio
from mcp import types
from mcp.server.lowlevel import Server
from mcp.server.lowlevel.helper_types import ReadResourceContents
from mcp.server.stdio import stdio_server
from mcp.shared.exceptions import McpError

from . import __version__
from .agent_executor import EXECUTION_TOOLS, MAX_LIST, RobotExecutor
from .security import MAX_BODY, dumps

MAX_LINE = MAX_BODY + 1024 * 1024
INSTRUCTIONS = (
    "Control only the operator-configured robot and trusted action scripts. "
    "Static queries do not activate hardware. Execution, reads, capture and teardown can have physical effects. "
    "An unknown outcome is not a rollback: do not retry it. Check get_status after cancellation or failure. "
    "Only the operator may change launch permissions or restart a faulted process. "
    "Reference resources describe SQL, MT and Lua; they do not grant execution permission."
)
RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "ok": {"type": "boolean"},
        "executed": {"type": "boolean"},
        "state": {"enum": ["completed", "not_executed", "unknown"]},
        "data": {"type": "object"},
        "error": {"type": "object"},
        "truncated": {"type": "boolean"},
        "output": {"type": "string"},
    },
    "required": ["ok", "executed", "state"],
    "additionalProperties": False,
}


def tool_definitions(timeout):
    ident = {"type": "string", "minLength": 1, "maxLength": 256}
    script = {"type": "string", "minLength": 1, "maxLength": 4096}
    seconds = {"type": "number", "exclusiveMinimum": 0, "maximum": timeout}
    entries = [
        ("get_status", "Read current state and the last receipt, including while faulted.", {}, []),
        ("list_hardware", "List declared hardware without activating drivers.", {}, []),
        ("list_action_scripts", "List relative .mt paths inside the trusted scripts directory.", {}, []),
        ("read_action_script", "Read one trusted .mt script without executing it.",
         {"script": script}, ["script"]),
        ("query_sql", "Read structure tables using SHOW TABLES or SELECT *; no mutations.",
         {"sql": {"type": "string", "maxLength": MAX_BODY}}, ["sql"]),
        ("run_action_script", "Execute an existing trusted MT script. Never retry an unknown outcome.",
         {"script": script, "vars": {"type": "object", "maxProperties": MAX_LIST,
          "additionalProperties": {"type": "string", "maxLength": 65536}}, "timeout": seconds}, ["script"]),
        ("read_variables", "Read allowlisted variables. Activation and reads may write to devices.",
         {"names": {"type": "array", "items": ident, "minItems": 1, "maxItems": MAX_LIST,
                    "uniqueItems": True}, "timeout": seconds}, ["names"]),
        ("capture_image", "Capture an allowlisted Camera and return MCP image content. May activate hardware.",
         {"name": ident, "timeout": seconds}, ["name"]),
        ("deactivate", "Release an idle robot; not an emergency stop and never clears a fault.", {}, []),
    ]
    return [types.Tool(
        name=name, description=description,
        inputSchema={"type": "object", "properties": properties,
                     "required": required, "additionalProperties": False},
        outputSchema=RESULT_SCHEMA,
        annotations=types.ToolAnnotations(
            readOnlyHint=name not in EXECUTION_TOOLS and name != "deactivate",
            destructiveHint=name in EXECUTION_TOOLS,
            idempotentHint=name not in EXECUTION_TOOLS,
            openWorldHint=name in EXECUTION_TOOLS),
    ) for name, description, properties, required in entries]


def _not_executed(message):
    return {"ok": False, "executed": False, "state": "not_executed",
            "error": {"type": "PermissionError", "message": message}}


def tool_result(receipt):
    receipt = dict(receipt)
    images = list(receipt.pop("images", ()))
    image = receipt.pop("image", None)
    if image is not None:
        images.append(image)
    content = [types.TextContent(type="text", text=dumps(receipt))]
    content.extend(types.ImageContent(type="image", mimeType=image["media_type"],
                                      data=base64.b64encode(image["data"]).decode("ascii"))
                   for image in images)
    return types.CallToolResult(content=content, structuredContent=receipt, isError=not receipt["ok"])


def create_server(executor, *, timeout=180, allow_execution=False):
    if (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
            or not math.isfinite(timeout) or not 0 < timeout <= 3600):
        raise ValueError("Timeout must be finite, positive and at most 3600 seconds")
    if type(allow_execution) is not bool:
        raise ValueError("allow_execution must be a boolean")
    server = Server("pymybot", version=__version__, instructions=INSTRUCTIONS)
    tools = tool_definitions(timeout)
    names = {tool.name for tool in tools}
    resource_map = {}

    @server.list_tools()
    async def list_tools():
        return tools

    @server.call_tool()
    async def call_tool(name, arguments):
        if name not in names:
            return tool_result(_not_executed("Unknown tool"))
        arguments = dict(arguments)
        seconds = arguments.pop("timeout", timeout)
        if name == "get_status":
            status = executor.status()
            state = "faulted" if status["faulted"] else ("active" if status["active"] else "loaded")
            receipt = {"ok": True, "executed": False, "state": "completed",
                       "data": {**status, "state": state}}
        elif name in EXECUTION_TOOLS and not allow_execution:
            receipt = _not_executed(
                "Execution is disabled; the operator must restart with --allow-execution")
        elif name == "deactivate":
            receipt = await executor.deactivate()
        else:
            receipt = await executor.call(name, arguments, timeout=seconds)
        # The SDK must observe cancellation instead of replying a second time.
        await anyio.lowlevel.checkpoint()
        return tool_result(receipt)

    async def resource_data(name, arguments):
        result = await executor.call(name, arguments, timeout=timeout)
        await anyio.lowlevel.checkpoint()
        if not result["ok"] or result.get("truncated"):
            raise _resource_error("Resource unavailable, busy or exceeds the output limit")
        return result["data"]

    @server.list_resources()
    async def list_resources():
        entries, mapping = [], {}
        index = await resource_data("list_action_scripts", {})
        for script in index["scripts"]:
            uri = "mybot://scripts/" + quote(script, safe="/")
            entries.append(types.Resource(uri=uri, name=script, mimeType="text/plain"))
            mapping[uri] = ("read_action_script", {"script": script})
        skills = await executor.call("list_skills", {}, timeout=timeout)
        await anyio.lowlevel.checkpoint()
        if skills["ok"]:
            for skill in skills["data"]["skills"]:
                for reference in skill["files"]:
                    if len(entries) >= MAX_LIST:
                        raise _resource_error("Too many reference resources")
                    uri = ("mybot://skills/" + quote(skill["name"], safe="")
                           + "/" + quote(reference, safe="/"))
                    entries.append(types.Resource(uri=uri, name=f"{skill['name']}/{reference}",
                                                  description=skill["description"], mimeType="text/markdown"))
                    mapping[uri] = ("read_skill", {"name": skill["name"], "file": reference})
        resource_map.clear()
        resource_map.update(mapping)
        return entries

    @server.read_resource()
    async def read_resource(uri):
        if not resource_map:
            await list_resources()
        entry = resource_map.get(str(uri))
        if entry is None:
            raise _resource_error("Unknown resource")
        name, arguments = entry
        data = await resource_data(name, arguments)
        return [ReadResourceContents(content=data["content"],
                                     mime_type="text/markdown" if name == "read_skill" else "text/plain")]

    return server


def _resource_error(message):
    return McpError(types.ErrorData(code=-32002, message=message))


class _Input:
    """Async line iterator over a raw descriptor; never holds a buffered lock."""

    def __init__(self, fd):
        self.queue = asyncio.Queue()
        self.loop = asyncio.get_running_loop()
        threading.Thread(target=self._read, args=(fd,), name="mcp-stdin", daemon=True).start()

    def _put(self, value):
        try:
            self.loop.call_soon_threadsafe(self.queue.put_nowait, value)
        except RuntimeError:
            pass  # The session exited while the reader was still blocked.

    def _read(self, fd):
        pending = b""
        discarding = False
        try:
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    if discarding:
                        self._put(ValueError("Message exceeds the line limit"))
                    elif pending:
                        self._emit(pending)
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if discarding or len(line) > MAX_LINE:
                        self._put(ValueError("Message exceeds the line limit"))
                    elif line.strip():
                        self._emit(line)
                    discarding = False
                if len(pending) > MAX_LINE:
                    pending = b""
                    discarding = True
        except (OSError, ValueError) as exc:
            print(f"pymybot mcp: stdin: {exc}", file=sys.stderr)
        finally:
            self._put(None)

    def _emit(self, line):
        try:
            self._put(line.decode("utf-8"))
        except UnicodeDecodeError:
            self._put(ValueError("Message is not UTF-8"))

    def __aiter__(self):
        return self

    async def __anext__(self):
        value = await self.queue.get()
        if value is None:
            raise StopAsyncIteration
        if isinstance(value, ValueError):
            raise value
        return value


@contextmanager
def _protocol_output():
    """Point fd 1 at stderr; yield the private protocol stream."""
    sys.stdout.flush()
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    out = open(os.dup(protocol_fd), "w", encoding="utf-8", newline="\n")
    try:
        yield out
    finally:
        # Keep fd 1 redirected: native buffers may flush only at process exit.
        try:
            sys.stdout.flush()
        finally:
            out.close()
            os.close(protocol_fd)


async def _run(out, stop, *, timeout, allow_execution, **config):
    executor = RobotExecutor(**config)
    server = create_server(executor, timeout=timeout, allow_execution=allow_execution)
    try:
        context = await executor.start(deadline=time.monotonic() + timeout)
        if context.get("ok") is False:
            raise RuntimeError("Cannot load robot, scripts or reference skills; check local configuration")
        async with anyio.create_task_group() as group:
            async def watch_stop():
                while not stop.is_set():
                    await anyio.sleep(0.05)
                executor.cancel()
                group.cancel_scope.cancel()

            group.start_soon(watch_stop)
            try:
                async with stdio_server(stdin=_Input(sys.stdin.fileno()),
                                        stdout=anyio.wrap_file(out)) as streams:
                    await server.run(*streams, server.create_initialization_options())
            finally:
                group.cancel_scope.cancel()
    finally:
        with anyio.CancelScope(shield=True):
            await executor.close()


def run_server(stop, *, robot_path, scripts_dir, module_paths=None, camera_src_root=None,
               vars=None, allow_execution=False, allow_hardware=False, read_vars=(), camera_vars=(),
               timeout=180, skills_dir=None):
    """Serve MCP on stdout; exits with a stderr diagnostic instead of JSON."""
    if allow_hardware and not allow_execution:
        raise ValueError("--allow-hardware requires --allow-execution")
    from .agent_skills import SkillsLibrary, default_skills_root
    try:
        skills = SkillsLibrary(skills_dir if skills_dir is not None else default_skills_root(),
                               required=skills_dir is not None)
    except Exception as exc:
        print(f"pymybot mcp: cannot load skills: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
    try:
        with _protocol_output() as out:
            asyncio.run(_run(out, stop, timeout=timeout, allow_execution=allow_execution,
                             robot_path=robot_path, scripts_dir=scripts_dir,
                             module_paths=module_paths, camera_src_root=camera_src_root,
                             vars=vars, allow_hardware=allow_hardware, read_vars=read_vars,
                             camera_vars=camera_vars, skills=skills))
    except KeyboardInterrupt:
        # The CLI installs SIGINT/SIGTERM handlers that set stop; a direct or
        # embedded Ctrl+C still reaches this branch after asyncio has cleaned up.
        return {"stopped": True}
    except SystemExit:
        raise
    except BaseException as exc:
        print(f"pymybot mcp: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
    return {"stopped": stop.is_set()}
