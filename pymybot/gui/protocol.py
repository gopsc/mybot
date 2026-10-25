"""Process boundary for the tkinter GUI.

The GUI never executes robot code itself: it either drives one long-lived
``python -m pymybot serve`` over stdio JSON-RPC 2.0 (agent mode) or runs
one-shot CLI commands (controller mode). This module owns those pipes so the
Tk thread only ever touches widgets.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import Future
from dataclasses import dataclass, field
from pathlib import Path

from ..paths import frozen

MAX_STDOUT = 32 * 1024 * 1024
MAX_STDERR = 256 * 1024
EXITED = -32099
CANCELLED = -32800
BUSY = -32001
WRONG_STATE = -32002


class RpcError(Exception):
    """A JSON-RPC error reply, or a transport failure."""

    def __init__(self, message, code=EXITED, data=None):
        super().__init__(message)
        self.code = code
        self.data = data if isinstance(data, dict) else {}

    @property
    def tool_events(self):
        events = self.data.get("tool_events")
        return events if isinstance(events, list) else []


def parse_result(stdout):
    """Return the CLI's single JSON result line, ignoring anything else.

    ``serve`` also prints a final CLI result line; callers that only want
    ``journal`` style output simply get ``None`` for non-JSON lines.
    """
    for line in reversed([item for item in stdout.splitlines() if item.strip()]):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("ok"), bool):
            return value
    return None


def _frozen_sibling():
    """Return the console CLI shipped next to a frozen GUI, if present."""
    if not frozen():
        return None
    name = "pymybot.exe" if os.name == "nt" else "pymybot"
    candidate = Path(sys.executable).with_name(name)
    return candidate if candidate.is_file() else None


def _spawn_options():
    """Never flash a console window for children of a frozen GUI on Windows."""
    if os.name == "nt" and frozen():
        return {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)}
    return {}


def _frozen_args(python, args):
    """A frozen CLI takes ``serve`` directly, not ``-m pymybot serve``."""
    sibling = _frozen_sibling()
    if sibling is None or Path(python).resolve() != sibling.resolve():
        return list(args)
    values = list(args)
    if values[:2] == ["-m", "pymybot"]:
        return values[2:]
    return values


def cli_args(
    command,
    *,
    robot="",
    script="",
    sql="",
    name="",
    count=1,
    interval_ms=0,
    timeout=None,
    allow_hardware=False,
    module_paths=(),
    camera_src_dir="",
    scripts_dir="",
):
    """Build the argv for one controller-mode command.

    Every value uses ``--option=value`` so text that starts with ``-`` is never
    parsed as an option.
    """
    args = ["-m", "pymybot", command]
    if command == "scripts":
        if scripts_dir:
            args.append(f"--scripts-dir={scripts_dir}")
        return args
    if not str(robot).strip():
        raise ValueError(f"{command} requires a structure file")
    args.append(f"--robot={robot}")
    for path in module_paths:
        if str(path).strip():
            args.append(f"--module-path={path}")
    if str(camera_src_dir).strip():
        args.append(f"--camera-src-dir={camera_src_dir}")
    if command in {"check", "run"}:
        if command == "run" and not str(script).strip():
            raise ValueError("run requires an action script")
        if str(script).strip():
            args.append(f"--input={script}")
    if command in {"query", "apply-sql"}:
        if not str(sql).strip():
            raise ValueError(f"{command} requires SQL text")
        args.append(f"--sql={sql}")
    if command in {"run", "sample"} and timeout is not None:
        args.append(f"--timeout={timeout}")
    if command == "sample":
        if not str(name).strip():
            raise ValueError("sample requires a variable name")
        args.extend(
            (
                f"--name={name}",
                f"--count={int(count)}",
                f"--interval-ms={int(interval_ms)}",
            )
        )
    if allow_hardware and command in {"run", "sample", "apply-sql"}:
        args.append("--allow-hardware")
    return args


def _child_env():
    return {**os.environ, "PYTHONUNBUFFERED": "1", "PYTHONUTF8": "1"}


@dataclass
class CliResult:
    argv: list[str]
    code: int | None
    json: dict | None
    stdout: str
    stderr: str
    duration_ms: int
    # Set when the process could not be started at all.
    error: str = ""
    raw: list[str] = field(default_factory=list)


class CliCall:
    """One one-shot ``python -m pymybot <command>`` process."""

    def __init__(self, python, args, cwd, on_stderr=None):
        self.argv = [python, *_frozen_args(python, args)]
        self._on_stderr = on_stderr
        self._stderr: list[str] = []
        self._started = time.monotonic()
        self._proc = subprocess.Popen(
            self.argv,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=_child_env(),
            **_spawn_options(),
        )
        self._stderr_thread = threading.Thread(target=self._pump_stderr, name="gui-cli-stderr", daemon=True)
        self._stderr_thread.start()

    def _pump_stderr(self):
        stream = self._proc.stderr
        if stream is None:
            return
        try:
            for line in stream:
                self._stderr.append(line)
                if len(self._stderr) > 4000:
                    del self._stderr[:1000]
                if self._on_stderr is not None:
                    try:
                        self._on_stderr(line)
                    except Exception:
                        pass
        except (OSError, ValueError):
            pass

    def kill(self):
        if self._proc.poll() is None:
            try:
                self._proc.kill()
            except OSError:
                pass

    def wait(self):
        stdout = ""
        try:
            stream = self._proc.stdout
            if stream is not None:
                stdout = stream.read(MAX_STDOUT)
        except (OSError, ValueError):
            stdout = ""
        code = self._proc.wait()
        self._stderr_thread.join(timeout=5)
        stderr = "".join(self._stderr)[-MAX_STDERR:]
        return CliResult(
            argv=self.argv,
            code=code,
            json=parse_result(stdout),
            stdout=stdout,
            stderr=stderr,
            duration_ms=int((time.monotonic() - self._started) * 1000),
        )


class ServeClient:
    """One ``python -m pymybot serve`` process.

    ``on_notify(method, params)``, ``on_request(ident, method, params)``,
    ``on_stderr(chunk)`` and ``on_exit(code)`` are called from reader threads:
    the caller must marshal them onto the Tk thread itself.
    """

    def __init__(
        self,
        python,
        cwd,
        *,
        on_notify=None,
        on_request=None,
        on_stderr=None,
        on_exit=None,
        python_args=("-m", "pymybot", "serve"),
    ):
        self.argv = [python, *_frozen_args(python, python_args)]
        self._on_notify = on_notify
        self._on_request = on_request
        self._on_stderr = on_stderr
        self._on_exit = on_exit
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._pending: dict[int, Future] = {}
        self._seq = 0
        self._closed = False
        self._proc = subprocess.Popen(
            self.argv,
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=_child_env(),
            **_spawn_options(),
        )
        threading.Thread(target=self._read_stdout, name="gui-serve-stdout", daemon=True).start()
        threading.Thread(target=self._read_stderr, name="gui-serve-stderr", daemon=True).start()

    @property
    def alive(self):
        return not self._closed

    # -- transport ---------------------------------------------------------
    def _send(self, message):
        line = json.dumps(message, ensure_ascii=False)
        with self._write_lock:
            if self._closed or self._proc.stdin is None or self._proc.stdin.closed:
                raise RpcError("pymybot serve is not running")
            try:
                self._proc.stdin.write(line + "\n")
                self._proc.stdin.flush()
            except (OSError, ValueError) as exc:
                raise RpcError(f"Cannot write to pymybot serve: {exc}") from None

    def _read_stdout(self):
        stream = self._proc.stdout
        if stream is not None:
            try:
                for line in stream:
                    self._receive(line.strip())
            except (OSError, ValueError):
                pass
        self._fail_all("pymybot serve exited")
        try:
            code = self._proc.wait()
        except OSError:
            code = None
        if self._on_exit is not None:
            try:
                self._on_exit(code)
            except Exception:
                pass

    def _read_stderr(self):
        stream = self._proc.stderr
        if stream is None:
            return
        try:
            for chunk in stream:
                if self._on_stderr is not None:
                    try:
                        self._on_stderr(chunk)
                    except Exception:
                        pass
        except (OSError, ValueError):
            pass

    def _receive(self, line):
        if not line:
            return
        try:
            message = json.loads(line)
        except ValueError:
            return
        # The CLI's final result line has no jsonrpc member.
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return
        method = message.get("method")
        if isinstance(method, str):
            ident = message.get("id")
            if ident is None:
                if method != "cancel" and self._on_notify is not None:
                    self._on_notify(method, message.get("params") or {})
            elif self._on_request is not None:
                # Server-initiated request; answered later from the Tk thread.
                self._on_request(ident, method, message.get("params") or {})
            return
        ident = message.get("id")
        with self._lock:
            future = self._pending.pop(ident, None) if isinstance(ident, int) else None
        if future is None or future.done():
            return
        error = message.get("error")
        if isinstance(error, dict):
            future.set_exception(
                RpcError(str(error.get("message") or "Unknown error"),
                         error.get("code") if isinstance(error.get("code"), int) else -32603,
                         error.get("data"))
            )
        else:
            future.set_result(message.get("result") or {})

    def _fail_all(self, message):
        self._closed = True
        with self._lock:
            pending, self._pending = self._pending, {}
        for future in pending.values():
            if not future.done():
                future.set_exception(RpcError(message))

    # -- API ---------------------------------------------------------------
    def start_request(self, method, params=None):
        """Send a request and return ``(id, Future)``; ``id`` also tags events."""
        with self._lock:
            self._seq += 1
            ident = self._seq
            future: Future = Future()
            self._pending[ident] = future
        try:
            self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}})
        except RpcError:
            with self._lock:
                self._pending.pop(ident, None)
            raise
        return ident, future

    def request(self, method, params=None, timeout=None):
        _, future = self.start_request(method, params)
        return future.result(timeout)

    def respond(self, ident, result):
        """Answer a server-initiated request such as ``confirm``."""
        self._send({"jsonrpc": "2.0", "id": ident, "result": result})

    def cancel(self, ident):
        if ident is None:
            return
        try:
            self._send({"jsonrpc": "2.0", "method": "cancel", "params": {"id": ident}})
        except RpcError:
            pass

    def stop(self, grace=8.0):
        """Ask the server to clean up, then close stdin and wait."""
        if self._closed:
            return
        try:
            self.request("shutdown", timeout=2.0)
        except (RpcError, TimeoutError):
            pass
        self._closed = True
        try:
            if self._proc.stdin is not None:
                self._proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self._proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self._proc.kill()


def resolve_python(workspace, configured=""):
    """Explicit setting, frozen sibling CLI, workspace venv, this interpreter."""
    if str(configured).strip():
        return str(configured).strip()
    sibling = _frozen_sibling()
    if sibling is not None:
        return str(sibling)
    root = Path(workspace) if str(workspace).strip() else None
    if root is not None:
        for parts in (
            (".venv", "bin", "python"),
            (".venv", "Scripts", "python.exe"),
            ("venv", "bin", "python"),
            ("venv", "Scripts", "python.exe"),
        ):
            candidate = root.joinpath(*parts)
            if candidate.is_file():
                return str(candidate)
    return sys.executable
