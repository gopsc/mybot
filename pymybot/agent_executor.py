"""Single-owner, framework-independent execution of operator-approved tools.

Lua modules and robot declarations are trusted operator inputs, not a sandbox.
Physical access requires allow_hardware at the existing runtime/HAL boundary;
virtual devices remain available without it. Deadlines are cooperative: native
active/read/run calls cannot be forcibly interrupted.
"""
from __future__ import annotations

import asyncio
import base64
import copy
import math
import os
from pathlib import Path, PureWindowsPath
import stat
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor

from .agent_skills import SkillsLibrary
from .agent_workspace import WORKSPACE_TOOLS, Workspace
from .sandbox import SANDBOX_MODES, describe_backend
from .errors import BudgetExceeded
from .hal import HALManager
from .hardware import Budget, ensure_ok, safe_ident
from .include import MAX_INCLUDE_BYTES, _Expander, expand_includes
from .matrix import is_control, parse_matrices, reflex_name
from .robot import MAX_BINDING_BYTES, Robot
from .security import MAX_BODY, SecurityError, checked_text, dumps
from .sql import parse_sql

MAX_LIST = 1000
MAX_TEXT = 64 * 1024
MAX_IMAGE_BASE64 = 2 * 1024 * 1024
MAX_IMAGES = 16
_UNKNOWN = "Execution outcome is unknown; do not retry. Executor is faulted; operator inspection is required."
_NOT_EXECUTED = "Request was not executed. Check operator configuration and tool arguments."
_TOOLS = {
    "list_hardware": (set(), set()),
    "list_action_scripts": (set(), set()),
    "read_action_script": ({"script"}, {"script"}),
    "query_sql": ({"sql"}, {"sql"}),
    "run_action_script": ({"script"}, {"script", "vars"}),
    "read_variables": ({"names"}, {"names"}),
    "capture_image": ({"name"}, {"name"}),
    "list_skills": (set(), set()),
    "read_skill": ({"name"}, {"name", "file"}),
    **WORKSPACE_TOOLS,
}
EXECUTION_TOOLS = frozenset({"run_action_script", "read_variables", "capture_image"})


def _session_vars(values):
    if values is None:
        return {}
    if type(values) is not dict or len(values) > MAX_LIST:
        raise SecurityError("Invalid session bindings")
    return {safe_ident(name): checked_text(text, MAX_BINDING_BYTES) for name, text in values.items()}


def _identity(info):
    return info.st_dev, info.st_ino


def _version(info):
    # On Windows/Python 3.12 stat().ctime can be birth time while fstat().ctime
    # is change time. Compare ctime only within the same kind of stat below.
    return _identity(info), info.st_size, info.st_mtime_ns


def _no_links(path):
    # FILE_ATTRIBUTE_REPARSE_POINT also catches junctions on Python 3.11.
    for part in (path, *path.parents):
        info = part.lstat()
        if (stat.S_ISLNK(info.st_mode)
                or getattr(info, "st_file_attributes", 0) & 0x400
                or getattr(part, "is_junction", lambda: False)()):
            raise SecurityError("Linked paths are not allowed")


def _relative(value):
    checked_text(value)
    win = PureWindowsPath(value)
    if (not value or win.drive or win.root or value.startswith("/")
            or "\\" in value or ":" in value
            or any(p in {"", ".", ".."} for p in value.split("/"))
            or not value.endswith(".mt")):
        raise SecurityError("Expected a relative .mt path")
    return value


def _read_stable(path, check, cap=MAX_BODY):
    check()
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise SecurityError("Expected a regular file")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        check()
        if not stat.S_ISREG(opened.st_mode) or _version(before) != _version(opened):
            raise SecurityError("File changed while opening")
        data = stream.read(cap + 1)
        after = os.fstat(stream.fileno())
    check()
    current = path.stat()
    if (_version(before) != _version(after) or _version(before) != _version(current)
            or before.st_ctime_ns != current.st_ctime_ns
            or opened.st_ctime_ns != after.st_ctime_ns):
        raise SecurityError("File changed while reading")
    if len(data) > cap:
        raise SecurityError("File exceeds input limit")
    return checked_text(data.decode("utf-8"), cap)


class _Scripts:
    def __init__(self, directory):
        self.path = Path(directory).absolute()
        _no_links(self.path)
        self.canonical = self.path.resolve(strict=True)
        info = self.path.stat()
        if not stat.S_ISDIR(info.st_mode):
            raise SecurityError("Expected a scripts directory")
        self.identity = _identity(info)

    def check(self, path=None):
        _no_links(self.path)
        if (self.path.resolve(strict=True) != self.canonical
                or _identity(self.path.stat()) != self.identity):
            raise SecurityError("Scripts root was replaced")
        if path is not None:
            path.relative_to(self.path)
            _no_links(path)
            if not path.resolve(strict=True).is_relative_to(self.canonical):
                raise SecurityError("Path escaped scripts directory")

    def read(self, path, cap=MAX_BODY):
        return _read_stable(path, lambda: self.check(path), cap)

    def listing(self, check):
        self.check()
        result = []
        truncated = False

        def walk_error(error):
            raise error

        for base, dirs, files in os.walk(self.path, followlinks=False, onerror=walk_error):
            check()
            self.check(Path(base))
            allowed = []
            for name in dirs:
                try:
                    self.check(Path(base) / name)
                except SecurityError:
                    continue
                allowed.append(name)
            dirs[:] = sorted(allowed)
            for name in sorted(files):
                if not name.endswith(".mt"):
                    continue
                path = Path(base) / name
                try:
                    _relative(path.relative_to(self.path).as_posix())
                    self.check(path)
                except SecurityError:
                    continue
                if not stat.S_ISREG(path.stat().st_mode):
                    continue
                if len(result) == MAX_LIST:
                    truncated = True
                    break
                result.append(path.relative_to(self.path).as_posix())
            if truncated:
                break
        self.check()
        return {"scripts": sorted(result), "truncated": truncated}

    def prepare(self, relative, check):
        path = self.path.joinpath(*_relative(relative).split("/"))
        matrices = parse_matrices(self.read(path))
        check()
        # Reuse expand_includes' implementation with stronger reads and a pinned
        # outer root. No global monkeypatch: other executors/CLI remain unaffected.
        pending = list(matrices)
        directives = False
        while pending:
            matrix = pending.pop()
            directives |= matrix.name.strip() in {"Include", "Merge"}
            pending.extend(matrix.children)
        matrices = (_PinnedExpander(path.parent, self, check).run(matrices) if directives
                    else expand_includes(matrices, path.parent))
        lines = []

        def render(seq, *, implicit=False):
            if (implicit and len(seq) == 1 and seq[0].name == "Action"
                    and seq[0].rows and not seq[0].children):
                # An explicit wrapper would consume an extra level of the block-depth budget.
                lines.extend(" ".join(row) + ";\n" for row in seq[0].rows)
                return
            for matrix in seq:
                if matrix.name.strip() in {"Include", "Merge"}:
                    raise SecurityError("Unexpanded file directive")
                lines.append("@" + matrix.name + "\n")
                if matrix.json_text is not None:
                    lines.append(matrix.json_text + "\n")
                else:
                    lines.extend(" ".join(row) + ";\n" for row in matrix.rows)
                render(matrix.children, implicit=is_control(matrix.name) or reflex_name(matrix.name) is not None)
                lines.append("@\n")

        render(matrices)
        frozen = checked_text("".join(lines))
        if parse_matrices(frozen) != matrices:
            raise SecurityError("Cannot losslessly freeze action script")
        self.check(path)
        check()
        # Robot.run receives only this immutable, expanded snapshot. In particular,
        # replacing an Include during activation cannot change the executed action.
        return frozen, path.parent


class _PinnedExpander(_Expander):
    def __init__(self, base, scripts, check):
        self.scripts, self.check_budget = scripts, check
        scripts.check(base)
        super().__init__(base)

    def check_path(self, path):
        self.check_budget()
        self.scripts.check(path)
        super().check_path(path)

    def read(self, path):
        self.check_path(path)
        text = self.scripts.read(path, MAX_INCLUDE_BYTES - self.total_bytes)
        self.total_bytes += len(text.encode("utf-8"))
        self.check_budget()
        return parse_matrices(text)


def _bounded(payload):
    """Bound every list and the entire JSON envelope, not just its raw strings."""
    clipped = False

    def visit(value):
        nonlocal clipped
        if isinstance(value, (list, tuple)):
            clipped |= len(value) > MAX_LIST
            return [visit(v) for v in value[:MAX_LIST]]
        if isinstance(value, dict):
            return {k: visit(v) for k, v in value.items()}
        return value

    payload = visit(payload)
    if clipped:
        payload["truncated"] = True
    if len(dumps(payload).encode("utf-8")) <= MAX_TEXT:
        return payload
    content = dumps(payload.get("data", payload))
    envelope = {k: payload[k] for k in ("ok", "executed", "state") if k in payload}
    envelope["truncated"] = True
    low, high = 0, min(len(content), MAX_TEXT)
    while low < high:
        middle = (low + high + 1) // 2
        if len(dumps({**envelope, "output": content[:middle]}).encode("utf-8")) <= MAX_TEXT:
            low = middle
        else:
            high = middle - 1
    return {**envelope, "output": content[:low]}


def _image(value):
    ensure_ok(value)
    encoded = value.get("b64", value.get("base64"))
    if not isinstance(encoded, str) or not 0 < len(encoded) <= MAX_IMAGE_BASE64:
        raise SecurityError("Invalid image size or encoding")
    if any(value[key] != encoded for key in ("b64", "base64") if key in value):
        raise SecurityError("Conflicting image copies")
    data = base64.b64decode(encoded, validate=True)
    if base64.b64encode(data).decode("ascii") != encoded:
        raise SecurityError("Noncanonical base64")
    fmt, _ = HALManager._image_header(data)
    media_type = "image/" + fmt
    if value.get("format") != fmt or value.get("mime") != media_type:
        raise SecurityError("Image format/mime mismatch")

    def strip(item):
        if isinstance(item, dict):
            return {key: strip(v) for key, v in item.items() if key not in {"b64", "base64"}}
        if isinstance(item, list):
            return [strip(v) for v in item]
        return item

    return strip(value), {"data": data, "media_type": media_type}


def _lift_images(outputs):
    """Move base64 image payloads out of action results into binary attachments.

    An image left inline in a receipt would be cut mid-string by _bounded and burn
    the whole tool-result budget, so the model would see base64 fragments rather
    than a picture. Each lifted result keeps an index correlating it with the
    attachment, and payloads past MAX_IMAGES are marked instead of dropped.
    """
    images, omitted = [], 0

    def visit(value):
        nonlocal omitted
        if isinstance(value, dict):
            if not isinstance(value.get("b64", value.get("base64")), str):
                return {key: visit(item) for key, item in value.items()}
            if len(images) >= MAX_IMAGES:
                omitted += 1
                rest = {key: visit(item) for key, item in value.items()
                        if key not in {"b64", "base64"}}
                return {**rest, "image_omitted": f"more than {MAX_IMAGES} images in one action"}
            data, image = _image(value)
            images.append(image)
            return {**data, "image_index": len(images) - 1}
        if isinstance(value, list):
            return [visit(item) for item in value]
        return value

    return visit(outputs), images, omitted


class RobotExecutor:
    """Own one Robot on one worker; use from a single asyncio event loop.

    start() returns a bounded static {robot, hardware, scripts} context (or a
    not_executed error). call() returns the documented execution envelope. A
    cancelled call waits for its worker and returns an unknown/not_executed
    envelope instead of abandoning a possibly running action. close() also waits
    through cancellation, then re-raises CancelledError after owner cleanup.
    """

    def __init__(self, robot_path, *, module_paths=None, camera_src_root=None,
                 scripts_dir, allow_hardware=False, read_vars=(), camera_vars=(),
                 stop_event=None, robot_factory=Robot, skills=None, workspace_dir=None, enable_shell=False,
                 vars=None, sandbox="off"):
        if enable_shell and workspace_dir is None:
            raise ValueError("Shell tools require a workspace directory")
        if sandbox not in SANDBOX_MODES:
            raise ValueError("sandbox must be one of off, auto or bwrap")
        self._sandbox = sandbox
        self._vars = _session_vars(vars)
        self._workspace_dir = Path(workspace_dir).absolute() if workspace_dir is not None else None
        self._enable_shell = enable_shell is True
        self._workspace = None
        self._robot_path = Path(robot_path).absolute()
        self._scripts_dir = Path(scripts_dir).absolute()
        self._skills = skills if isinstance(skills, SkillsLibrary) else None
        self._module_paths = module_paths
        self._camera_src_root = camera_src_root
        self._allow_hardware = allow_hardware is True
        self._read_vars = frozenset(read_vars)
        self._camera_vars = frozenset(camera_vars)
        self._stop = stop_event if stop_event is not None else threading.Event()
        self._factory = robot_factory
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="robot-owner")
        self._owner_thread_id = None
        self._faulted = False
        self._interrupted = False
        self._robot = None
        self._ready = False
        self._active = False
        self._needs_cleanup = False
        self._closing = False
        self._close_task = None
        self.records: list = []
        self._records_lock = threading.Lock()

    @property
    def owner_thread_id(self):
        return self._owner_thread_id

    @property
    def robot_path(self):
        return self._robot_path

    @property
    def scripts_dir(self):
        return self._scripts_dir

    @property
    def workspace_dir(self):
        return self._workspace_dir

    @property
    def sandbox_mode(self):
        return self._sandbox

    @property
    def sandbox_label(self):
        return describe_backend(self._sandbox)

    @property
    def skills(self):
        return self._skills

    @property
    def module_paths(self):
        return tuple(self._module_paths or ())

    @property
    def faulted(self):
        return self._faulted

    @property
    def interrupted(self):
        """Whether cancellation preceded the fault, rather than resulted from it."""
        return self._interrupted

    @property
    def stop_event(self):
        return self._stop

    def cancel(self):
        self._stop.set()

    def _owner(self):
        ident = threading.get_ident()
        if self._owner_thread_id is None:
            self._owner_thread_id = ident
        if self._owner_thread_id != ident:
            raise RuntimeError("Robot accessed outside owner thread")

    def _check(self, deadline):
        self._owner()
        if self._stop.is_set():
            raise BudgetExceeded("Stop requested")
        if deadline is not None and time.monotonic() >= deadline:
            raise BudgetExceeded("Deadline expired")

    def _remaining(self, deadline):
        self._check(None)
        remaining = deadline - time.monotonic()
        # Budget treats zero/negative timeout as unbounded. Never pass one,
        # including when path checks or preparation used the last of the budget.
        if remaining <= 0:
            raise BudgetExceeded("Deadline expired")
        return remaining

    @staticmethod
    def _failure(exc, executed=False):
        return {"ok": False, "executed": executed,
                "state": "unknown" if executed else "not_executed",
                "error": {"type": type(exc).__name__,
                          "message": _UNKNOWN if executed else _NOT_EXECUTED}}

    def _record(self, name, result, *, control=False):
        known = isinstance(name, str) and (name in _TOOLS or (control and name == "deactivate"))
        with self._records_lock:
            self.records.append({"tool": name if known else "unknown",
                                 **{k: result[k] for k in ("state", "ok", "executed")}})
            self.records[:] = self.records[-MAX_LIST:]
        return result

    async def _wait(self, future, *, propagate=False):
        cancelled = False
        while True:
            try:
                result = await asyncio.shield(future)
                break
            except asyncio.CancelledError:
                cancelled = True
                self.cancel()
                if future.cancelled():
                    # Re-awaiting an already cancelled Future never yields and
                    # would spin forever. Owner cleanup uses a non-Task Future.
                    raise
        if cancelled and propagate:
            raise asyncio.CancelledError
        return result

    def _load(self, deadline):
        self._check(deadline)
        if self._ready:
            return
        scripts = _Scripts(self._scripts_dir)
        if self._workspace_dir is not None and self._workspace is None:
            self._workspace = Workspace(self._workspace_dir, enable_shell=self._enable_shell,
                                        sandbox=self._sandbox)
        sql = _read_stable(self._robot_path, lambda: _no_links(self._robot_path))
        self._check(deadline)
        # Keep even a partially validated robot available for owner-thread close.
        if self._robot is None:
            self._robot = self._factory(sql, module_paths=self._module_paths,
                                        camera_src_root=self._camera_src_root,
                                        stop_event=self._stop, allow_hardware=self._allow_hardware,
                                        vars=self._vars)
        # Construction may already have consumed the whole budget; do not
        # enumerate metadata or validate a robot once the turn has expired.
        self._check(deadline)
        self._robot._validate(self._robot.tables)
        self._rows = self._robot._rows(self._robot.tables)
        self._scripts = scripts
        self._check(deadline)
        self._ready = True

    def _hardware(self):
        items = []
        truncated = False
        for name, (table, row) in self._rows.items():
            if table.name in {"Alias", "Vars"}:
                continue
            if len(items) == MAX_LIST:
                truncated = True
                break
            items.append({"name": name, "type": table.name,
                          "metadata": {col: table.inherited(row, i)
                                       for i, col in enumerate(table.header) if col != "name"}})
        return {"hardware": items, "truncated": truncated}

    def _start(self, deadline=None):
        try:
            self._check(deadline)
            if self._faulted:
                raise SecurityError("Executor faulted")
            self._load(deadline)
            hardware = self._hardware()
            scripts = self._scripts.listing(lambda: self._check(deadline))
            context = {"robot": self._robot_path.stem, "hardware": hardware["hardware"],
                       "scripts": scripts["scripts"],
                       "truncated": hardware["truncated"] or scripts["truncated"]}
            if self._workspace is not None:
                context["workspace"] = {"root": str(self._workspace.path), "shell_enabled": self._enable_shell,
                                        "shell_sandboxed": False}
            self._check(deadline)
            return _bounded(context)
        except Exception as exc:
            return self._failure(exc)

    async def start(self, *, deadline=None) -> dict:
        if self._closing:
            return self._failure(SecurityError())
        return await self._wait(asyncio.wrap_future(self._pool.submit(self._start, deadline)),
                                propagate=True)

    def status(self):
        """Cheap status snapshot; safe to call while an owner-thread call is queued."""
        with self._records_lock:
            last = self.records[-1] if self.records else None
        return {"loaded": self._ready, "active": self._active,
                "faulted": self._faulted, "interrupted": self._interrupted,
                "last_receipt": last}

    def _deactivate(self):
        self._owner()
        if not self._faulted:
            self._cleanup()
        return {"active": self._active, "faulted": self._faulted}

    async def deactivate(self) -> dict:
        """Release an idle robot without ending the session.

        Reactivation happens on the next execution tool. This is not an
        emergency stop and it never clears a latched fault.
        """
        if self._closing:
            return self._record("deactivate", self._failure(SecurityError()), control=True)
        try:
            future = self._pool.submit(self._deactivate)
        except Exception as exc:
            return self._record("deactivate", self._failure(exc), control=True)
        data = await self._wait(asyncio.wrap_future(future))
        return self._record("deactivate", {"ok": True, "executed": False, "state": "completed", "data": data},
                            control=True)

    @staticmethod
    def _arguments(name, arguments):
        if not isinstance(name, str) or name not in _TOOLS or type(arguments) is not dict:
            raise SecurityError("Unknown tool or arguments")
        required, allowed = _TOOLS[name]
        if not required <= arguments.keys() or not arguments.keys() <= allowed:
            raise SecurityError("Wrong tool arguments")
        checked_text(dumps(arguments))
        if name in WORKSPACE_TOOLS:
            Workspace.validate(name, arguments)
        elif name == "read_action_script":
            _relative(arguments["script"])
        elif name == "query_sql":
            checked_text(arguments["sql"])
            if any(s.kind not in {"SHOW", "SELECT"} for s in parse_sql(arguments["sql"])):
                raise SecurityError("Only read-only SQL is allowed")
        elif name == "run_action_script":
            _relative(arguments["script"])
            bindings = arguments.get("vars", {})
            if type(bindings) is not dict or len(bindings) > MAX_LIST:
                raise SecurityError("Invalid session bindings")
            for key, value in bindings.items():
                safe_ident(key)
                checked_text(value)
        elif name == "read_variables":
            names = arguments["names"]
            if type(names) is not list or not 0 < len(names) <= MAX_LIST:
                raise SecurityError("Invalid variable list")
            for item in names:
                safe_ident(item)
            if len(set(names)) != len(names):
                raise SecurityError("Duplicate variables")
        elif name == "capture_image":
            safe_ident(arguments["name"])
        elif name == "read_skill":
            checked_text(arguments["name"])
            if "file" in arguments:
                checked_text(arguments["file"])

    def _preflight_io(self, name, arguments):
        # Host approval belongs to AgentSession. This flag is passed to Robot,
        # which blocks actual physical opens while still allowing virtual/file IO.
        if name == "read_variables":
            for variable in arguments["names"]:
                if variable not in self._read_vars or variable not in self._rows:
                    raise PermissionError("Variable is not allowed")
                if self._rows[variable][0].name in {"Alias", "Vars", "Camera"}:
                    raise PermissionError("Variable kind is not readable by this tool")
        elif name == "capture_image":
            variable = arguments["name"]
            if (variable not in self._camera_vars or variable not in self._rows
                    or self._rows[variable][0].name != "Camera"):
                raise PermissionError("Camera is not allowed")

    def _read(self, names, deadline):
        budget = Budget(self._stop, self._remaining(deadline))
        budget.deadline = deadline  # Never extend the original call deadline.
        previous = [(v, v.budget) for v in self._robot.registry.values() if hasattr(v, "budget")]
        result = {}
        try:
            for variable, _ in previous:
                variable.budget = budget
            for name in names:
                self._check(deadline)
                target = self._robot.registry.require(name)
                if target.kind not in {"lua", "python", "daemon"}:
                    raise SecurityError("Unexpected runtime variable kind")
                if target.kind == "daemon":
                    value = target.wait_for_sample(timeout=self._remaining(deadline))
                else:
                    value = target.read()
                self._check(deadline)
                if isinstance(value, dict):
                    ensure_ok(value)
                result[name] = value
            return result
        finally:
            for variable, old in previous:
                variable.budget = old

    def _cleanup(self):
        self._owner()
        if self._robot is not None and self._needs_cleanup:
            self._robot.deactivate()
            self._needs_cleanup = False
            self._active = False

    def _call(self, name, arguments, deadline):
        executed = False

        def started():
            nonlocal executed
            executed = True

        try:
            self._check(deadline)
            if self._faulted:
                raise SecurityError("Executor faulted")
            self._arguments(name, arguments)
            self._load(deadline)
            image = None
            images = None
            if name == "list_hardware":
                data = self._hardware()
            elif name == "list_action_scripts":
                data = self._scripts.listing(lambda: self._check(deadline))
            elif name == "read_action_script":
                path = self._scripts.path.joinpath(*_relative(arguments["script"]).split("/"))
                self._scripts.check(path)
                data = {"script": arguments["script"], "content": self._scripts.read(path)}
            elif name == "query_sql":
                data = {"output": self._robot.query_sql(arguments["sql"])}
            elif name == "list_skills":
                if self._skills is None or not self._skills.enabled:
                    raise SecurityError("Skills are not configured")
                data = self._skills.index()
            elif name == "read_skill":
                if self._skills is None or not self._skills.enabled:
                    raise SecurityError("Skills are not configured")
                file = arguments.get("file", "SKILL.md")
                data = {"name": arguments["name"], "file": file,
                        "content": self._skills.read(arguments["name"], file)}
            elif name in WORKSPACE_TOOLS:
                if self._workspace is None:
                    raise SecurityError("Workspace tools are not configured")
                data = self._workspace.call(name, arguments, lambda: self._check(deadline), started)
            else:
                self._preflight_io(name, arguments)
                if name == "run_action_script":
                    script, base = self._scripts.prepare(arguments["script"], lambda: self._check(deadline))
                self._check(deadline)
                executed = True  # active() may already have written before raising.
                if not self._active:
                    self._needs_cleanup = True
                    # There is no hard deadline inside native activation. Do not
                    # abandon this Future or allow another action to overtake it.
                    self._robot.active()
                    self._active = True
                self._check(deadline)
                if name == "run_action_script":
                    self._scripts.check()
                    # Operator-provided bindings win over model-supplied ones.
                    bindings = {**arguments.get("vars", {}), **self._vars}
                    outputs, images, omitted = _lift_images(self._robot.run(
                        script, base_dir=str(base), vars=bindings,
                        timeout=self._remaining(deadline)))
                    data = {"outputs": outputs}
                    if omitted:
                        data["images_omitted"] = omitted
                elif name == "read_variables":
                    data = self._read(arguments["names"], deadline)
                else:
                    value = self._read([arguments["name"]], deadline)[arguments["name"]]
                    data, image = _image(value)
            self._check(deadline)
            ok = data["exit_code"] == 0 if name == "shell" else True
            result = _bounded({"ok": ok, "executed": executed, "state": "completed", "data": data})
            self._check(deadline)
            if image is not None:
                result["image"] = image
            if images:
                result["images"] = images
        except BaseException as exc:
            if executed:
                # Operator-only diagnostics: the model still receives the
                # deliberately vague unknown receipt, but the GUI log and
                # terminal need the failure class. Never print str(exc):
                # driver errors may contain secrets or user data.
                print(f"pymybot: {name} failed after dispatch: {type(exc).__name__}", file=sys.stderr)
                self._interrupted = self._stop.is_set()
                self._faulted = True
                self.cancel()
                try:
                    self._cleanup()
                except BaseException:
                    pass  # close will retry cleanup, never the action.
            result = self._failure(exc, executed)
            if isinstance(name, str) and name in WORKSPACE_TOOLS and not executed and isinstance(exc, SecurityError):
                result["error"]["message"] = str(exc)
        return self._record(name, result)

    async def call(self, name, arguments: dict, *, timeout: float = 180) -> dict:
        began = time.monotonic()
        if self._closing:
            return self._record(name, self._failure(SecurityError()))
        try:
            if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
                raise ValueError("Timeout must be finite and positive")
            # Snapshot JSON arguments before queuing: caller mutation must not
            # change the operation that is awaiting its owner-thread preflight.
            arguments = copy.deepcopy(arguments)
            future = self._pool.submit(self._call, name, arguments, began + timeout)
        except Exception as exc:
            return self._record(name, self._failure(exc))
        return await self._wait(asyncio.wrap_future(future))

    def _close_owner(self):
        self._owner()
        try:
            # Loaded robots also receive deactivate, on this same owner thread.
            if self._robot is not None:
                self._robot.deactivate()
                self._needs_cleanup = False
                self._active = False
        except BaseException as exc:
            self._faulted = True
            raise RuntimeError("Owner cleanup failed; operator inspection is required (" + type(exc).__name__ + ").") from None

    async def close(self):
        if self._close_task is None:
            self._closing = True
            owner_cleanup = self._pool.submit(self._close_owner)
            finished = Future()
            finished.set_running_or_notify_cancel()

            def finish():
                error = None
                try:
                    owner_cleanup.result()
                except BaseException as exc:
                    error = exc
                try:
                    self._pool.shutdown(wait=True, cancel_futures=False)
                except BaseException as exc:
                    error = error or exc
                if error is None:
                    finished.set_result(None)
                else:
                    finished.set_exception(error)

            # This joiner does not touch Robot. Unlike an asyncio shutdown Task,
            # its completion cannot be cancelled by loop-wide task cancellation.
            threading.Thread(target=finish, name="robot-owner-close", daemon=True).start()
            self._close_task = asyncio.wrap_future(finished)
        await self._wait(self._close_task, propagate=True)
