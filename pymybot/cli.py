"""Local commands and an optional agent; stdout remains one JSON result."""
from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import faulthandler
import importlib
import importlib.metadata
import math
import os
from pathlib import Path
import platform
import signal
import sys
import threading
import time

from . import __version__
from .errors import AgentInterrupted, ScriptError
from .hardware import Budget, ensure_ok, safe_ident
from .include import expand_includes
from .matrix import parse_matrices
from .paths import asset_path, frozen
from .robot import Robot, module_roots
from .security import MAX_BODY, SecurityError, checked_text, dumps, read_file

MAX_TIMEOUT = 3600
MAX_SAMPLES = 1000
MAX_INTERVAL_MS = 60000


class UsageError(ValueError):
    pass


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def bounded_int(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("must be an integer") from None
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"must be in {low}..{high}")
        return number
    return parse


def positive_timeout(value):
    try:
        number = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number of seconds") from None
    if not math.isfinite(number) or not 0 < number <= MAX_TIMEOUT:
        raise argparse.ArgumentTypeError(f"must be positive and at most {MAX_TIMEOUT} seconds")
    return number


def variable(value):
    name, separator, text = value.partition("=")
    try:
        if not separator:
            raise ValueError("expected NAME=VALUE")
        return safe_ident(name), checked_text(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def parser():
    p = ArgumentParser(
        prog="pymybot", allow_abbrev=False,
        description="GUI-first robot controller. Without a command it opens the PySide6 agent window; "
                    "use --no-gui for the command-line interface (agent REPL or direct controller commands). "
                    "Command-line results are JSON on stdout.",
        epilog="Use only trusted Lua modules: LuaJIT FFI is not malicious-code isolation. "
               "Activation itself may write to devices, including when sampling. "
               "Examples: pymybot --robot robot.sql   (GUI) | "
               "pymybot --no-gui --robot robot.sql --task 'List hardware'   (terminal agent)")
    p.add_argument("--no-gui", action="store_true",
                   help="command-line interface instead of the GUI (the GUI is the default)")
    p.add_argument("--no-agent", action="store_true",
                   help="bypass models; with --robot use --input to run a script (implies --no-gui)")
    commands = p.add_subparsers(dest="command", required=True)
    descriptions = {
        "check": "Statically validate structure SQL, modules/references and optional action Includes",
        "hardware": "List declared hardware without probing or activating it",
        "scripts": "List relative .mt script paths without executing Lua",
        "query": "Read structure tables using SELECT * or SHOW TABLES, without activation",
        "run": "Activate, execute an action script and deactivate (virtual-only by default)",
        "sample": "Activate and read a named variable; activation itself may write to devices",
        "apply-sql": "Apply SQL to a temporarily active robot; does not write the structure file",
        "agent": "PydanticAI task or interactive session on the terminal (see --no-gui)",
        "gui": "PySide6 agent window (the default entry; no command required)",
        "serve": "Long-lived stdio JSON-RPC 2.0 server for IDE frontends (one JSON object per line)",
        "doctor": "Check the interpreter, optional dependencies and bundled assets without touching hardware",
        "sessions": "List or prune conversation transcripts under ~/.mybot/sessions",
    }
    for name, description in descriptions.items():
        command = commands.add_parser(name, help=description, description=description, allow_abbrev=False)
        if name == "gui":
            # The window is always agent-centric: no agent/controller mode switch.
            command.add_argument("--robot", metavar="FILE", help="structure SQL file to open with")
            command.add_argument("--task", help="pre-fill the prompt box (not sent automatically)")
            command.add_argument("--workspace-dir", metavar="DIR", help="workspace root (default: current directory)")
            command.add_argument("--module-path", action="append", metavar="DIR", help="trusted Lua module root; repeatable")
            command.add_argument("--camera-src-dir", metavar="DIR", help="local camera image root")
            command.add_argument("--scripts-dir", metavar="DIR", help="trusted .mt script root offered to the agent")
            command.add_argument("--skills-dir", metavar="DIR", help="operator skill directories")
            command.add_argument("--model", help="provider:model; defaults to MYBOT_MODEL")
            command.add_argument("--base-url", help="provider endpoint; defaults to MYBOT_BASE_URL")
            command.add_argument("--api-key-env", help="environment variable holding the API key")
            command.add_argument("--read-var", action="append", default=[], metavar="NAME", help="allowlist a readable variable; repeatable")
            command.add_argument("--camera-var", action="append", default=[], metavar="NAME", help="allow image capture from this Camera variable; repeatable")
            command.add_argument("--allow-actions", action="store_true", help="start with agent action approval disabled")
            command.add_argument("--allow-hardware", action="store_true", help="start with physical device access checked")
            command.add_argument("--max-requests", type=bounded_int(1, 100), default=8, help="model requests per task (default: 8)")
            command.add_argument("--max-tool-calls", type=bounded_int(1, 1000), default=16, help="tool calls per task (default: 16)")
            command.add_argument("--timeout", type=positive_timeout, default=180, metavar="SECONDS",
                                 help="per-task wall-clock budget (default: 180)")
            continue
        if name == "sessions":
            command.add_argument("--no-agent", action="store_true",
                                 help="accepted for CLI consistency; sessions never uses a model")
            command.add_argument("--prune", action="store_true",
                                 help="delete old transcripts instead of listing them")
            command.add_argument("--keep", type=bounded_int(1, 10_000), default=20,
                                 help="keep the newest N sessions (default: 20)")
            command.add_argument("--older-than", type=bounded_int(0, 3650), metavar="DAYS",
                                 help="only prune sessions at least DAYS old")
            command.add_argument("--dry-run", action="store_true", help="show what --prune would delete")
            command.add_argument("--yes", action="store_true", help="confirm deletion (required with --prune)")
            continue
        command.add_argument("--no-agent", action="store_true",
                             help="disable agent.* methods" if name == "serve"
                             else "bypass the model; agent entry requires --input MT")
        if name in {"serve", "agent"}:
            command.add_argument("--no-session-log", action="store_true",
                                 help="do not write conversation transcripts under ~/.mybot/sessions")
        if name == "scripts":
            command.add_argument("--scripts-dir", help="default: packaged assets/scripts, else source scripts")
            continue
        if name in {"serve", "doctor"}:
            continue
        command.add_argument("--robot", required=True, metavar="FILE", help="structure SQL file (at most 8 MiB)")
        command.add_argument("--module-path", action="append", metavar="DIR", help="trusted Lua module root; repeatable")
        command.add_argument("--camera-src-dir", metavar="DIR", help="explicit local camera image root")
        if name in {"check", "run", "agent"}:
            command.add_argument("--input", required=name == "run", metavar="MT", help="direct action script (agent entry requires --no-agent)")
        if name in {"query", "apply-sql"}:
            command.add_argument("--sql", required=True, metavar="TEXT", help="SQL text (at most 8 MiB)")
        if name in {"run", "sample", "apply-sql", "agent"}:
            command.add_argument("--allow-hardware", action="store_true",
                                 help="permit physical devices; activation itself may write, even for sample")
        if name in {"run", "sample", "agent"}:
            command.add_argument("--timeout", type=positive_timeout, default=180, metavar="SECONDS",
                                 help=f"cooperative execution/task budget, >0 and <={MAX_TIMEOUT} (default: 180)")
        if name in {"run", "agent"}:
            command.add_argument("--var", type=variable, action="append", default=[], metavar="NAME=VALUE",
                                 help="session alias binding (text); repeat with distinct names")
        if name == "sample":
            command.add_argument("--name", required=True, help="declared variable name")
            command.add_argument("--count", type=bounded_int(1, MAX_SAMPLES), default=1,
                                 help=f"number of samples, 1..{MAX_SAMPLES} (default: 1)")
            command.add_argument("--interval-ms", type=bounded_int(0, MAX_INTERVAL_MS), default=0,
                                 help=f"delay between samples, 0..{MAX_INTERVAL_MS} (default: 0)")
        if name == "agent":
            command.add_argument("--task", help="one natural-language task; omit for interactive TTY mode")
            command.add_argument("--model", help="provider:model; defaults to MYBOT_MODEL")
            command.add_argument("--base-url", help="provider endpoint; defaults to MYBOT_BASE_URL")
            command.add_argument("--api-key-env", help="environment variable holding the API key (never the key itself)")
            command.add_argument("--scripts-dir", help="trusted root of existing .mt scripts available to the agent")
            command.add_argument("--skills-dir", metavar="DIR",
                                 help="trusted root of operator skill directories (SKILL.md + markdown references);"
                                      " default: packaged assets/skills, else source skills")
            command.add_argument("--read-var", action="append", default=[], metavar="NAME", help="allowlist a readable variable; repeatable")
            command.add_argument("--camera-var", action="append", default=[], metavar="NAME", help="allow image capture from this declared Camera variable; repeatable")
            command.add_argument("--allow-actions", action="store_true",
                                 help="preapprove agent scripts/reads/capture for this session; does NOT imply --allow-hardware")
            command.add_argument("--workspace-dir", metavar="DIR",
                                 help="enable file tools in this existing directory; file contents may be sent to the model")
            command.add_argument("--enable-shell", action="store_true",
                                 help="enable host shell execution (requires --workspace-dir); NOT sandboxed or limited by --allow-hardware")
            command.add_argument("--allow-shell", action="store_true",
                                 help="preapprove shell commands; requires --enable-shell; grants host-user permissions")
            command.add_argument("--allow-file-writes", action="store_true",
                                 help="preapprove workspace file creation/edits; requires --workspace-dir")
            command.add_argument("--max-requests", type=bounded_int(1, 100), default=8, help="model requests per task (default: 8)")
            command.add_argument("--max-tool-calls", type=bounded_int(1, 1000), default=16, help="tool calls per task (default: 16)")
            command.add_argument("--max-history-bytes", type=bounded_int(64 * 1024, 64 * 1024 * 1024),
                                 default=4 * 1024 * 1024,
                                 help="upper bound for retained conversation history (default: 4 MiB)")
    return p


def parse_args(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments in (["--version"], ["-V"]):
        print(f"pymybot {__version__}")
        raise SystemExit(0)
    commands = {"check", "hardware", "scripts", "query", "run", "sample", "apply-sql",
                "agent", "gui", "serve", "doctor", "sessions"}
    # --no-gui is a top-level switch: the GUI is the default entry, so drop it
    # before choosing a command, and let a subcommand keep its own semantics.
    no_gui = "--no-gui" in arguments
    if no_gui:
        arguments = [token for token in arguments if token != "--no-gui"]
    # --no-agent only means something to the command-line controller, so a
    # top-level use selects the CLI instead of failing against the GUI.
    head = []
    for token in arguments:
        if token in commands:
            break
        head.append(token)
    if "--no-agent" in head:
        no_gui = True
    if len(arguments) > 1 and arguments[0] == "--no-agent" and arguments[1] in commands:
        arguments[:2] = [arguments[1], "--no-agent"]
    if not arguments or arguments[0] not in commands | {"--help", "-h"}:
        arguments.insert(0, "agent" if no_gui else "gui")
    args = parser().parse_args(arguments)
    if args.command != "agent":
        return args  # Existing subcommands always bypass the model.
    if args.no_agent:
        if (args.task is not None or args.model or args.base_url or args.api_key_env
                or args.allow_actions or args.read_var or args.camera_var or args.workspace_dir
                or args.enable_shell or args.allow_shell or args.allow_file_writes):
            raise UsageError("--no-agent cannot be combined with model/task/agent tool options")
        if not args.input:
            raise UsageError("--no-agent requires --input MT; or use check/hardware/query/run/sample directly")
        args.command = "run"
        return args
    if (args.enable_shell or args.allow_file_writes) and not args.workspace_dir:
        raise UsageError("--enable-shell/--allow-file-writes require --workspace-dir")
    if args.allow_shell and not args.enable_shell:
        raise UsageError("--allow-shell requires --enable-shell")
    if args.input or args.var:
        raise UsageError("--input/--var require --no-agent or the run command; use --task for an agent")
    if args.task is None and not sys.stdin.isatty():
        raise UsageError("Non-interactive agent mode requires --task; use --no-agent --input for direct execution")
    if args.task is not None:
        checked_text(args.task, 16 * 1024)
        if not args.task.strip():
            raise UsageError("--task must not be empty")
    for name in [*args.read_var, *args.camera_var]:
        safe_ident(name)
    args.scripts_dir = args.scripts_dir or default_scripts_dir()
    return args


def default_scripts_dir():
    return asset_path("scripts")


def doctor():
    """Report the interpreter, dependencies and assets without hardware I/O."""
    required = [
        ("lupa.luajit21", "lupa", "LuaJIT runtime"),
        ("sqlparse", "sqlparse", "SQL tokenizer"),
        ("serial", "pyserial", "UART"),
        ("pyftdi", "pyftdi", "I2C/SPI"),
        ("PIL", "pillow", "image codecs"),
    ]
    optional = [
        ("av", "av", "camera capture", "pip install pymybot[camera]"),
        ("pydantic_ai", "pydantic-ai-slim", "agent mode", "pip install pymybot[agent]"),
        ("PySide6.QtWidgets", "PySide6", "GUI", "pip install pymybot[gui]"),
    ]

    def module_check(module, distribution, label, *, optional_check=False, hint=""):
        entry = {"name": module, "label": label, "optional": optional_check}
        try:
            importlib.import_module(module)
        except Exception as exc:
            entry["status"] = "warning" if optional_check else "missing"
            if hint:
                entry["hint"] = hint
            entry["error"] = type(exc).__name__
            return entry
        entry["status"] = "ok"
        if distribution:
            try:
                entry["version"] = importlib.metadata.version(distribution)
            except importlib.metadata.PackageNotFoundError:
                pass
        return entry

    checks = [module_check(module, distribution, label) for module, distribution, label in required]
    checks.extend(module_check(module, distribution, label, optional_check=True, hint=hint)
                  for module, distribution, label, hint in optional)

    suffixes = {"modules": ".lua", "robots": ".sql", "scripts": ".mt", "skills": ".md"}
    assets = {}
    for name, suffix in suffixes.items():
        path = asset_path(name)
        files = list(path.rglob("*" + suffix)) if path.is_dir() else []
        assets[name] = {"path": str(path), "exists": path.is_dir(), "files": len(files)}
    assets_ok = all(item["exists"] and item["files"] for item in assets.values())

    python_ok = sys.version_info >= (3, 11)
    healthy = python_ok and assets_ok and all(
        item["status"] == "ok" for item in checks if not item["optional"])
    return {
        "version": __version__,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "healthy": healthy,
        "python_supported": python_ok,
        "assets": assets,
        "module_paths": [str(path) for path in module_roots()],
        "checks": checks,
    }


def list_scripts(directory):
    root = Path(directory).resolve(strict=True)
    if not root.is_dir():
        raise SecurityError("Scripts root must be an existing directory")
    scripts = []
    def walk_error(error):
        raise error
    for base, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        dirs[:] = [name for name in dirs if not (Path(base) / name).is_symlink()]
        for name in files:
            path = Path(base) / name
            if path.suffix == ".mt" and not path.is_symlink() and path.is_file():
                scripts.append(path.relative_to(root).as_posix())
    return {"scripts_dir": str(root), "scripts": sorted(scripts), "activated": False}


def sample(robot, args, stop):
    budget = Budget(stop, args.timeout)
    # Referenced variables may also read Lua; give them the same deadline.
    previous = [(var, var.budget) for var in robot.registry.values() if hasattr(var, "budget")]
    samples, size = [], 0
    try:
        for var, _ in previous:
            var.budget = budget
        target = robot.registry.require(args.name)
        last_count = 0
        for index in range(args.count):
            budget.check()
            if index:
                remaining = max(0, budget.deadline - time.monotonic())
                stop.wait(min(args.interval_ms / 1000, remaining))
                budget.check()
            if target.kind == "daemon":
                value = target.wait_for_sample(after=last_count, timeout=max(0, budget.deadline - time.monotonic()))
                last_count = value["count"]
            else:
                value = target.read()
            budget.check()
            if isinstance(value, dict):
                ensure_ok(value, f"sample {args.name}")
            size += len(dumps(value).encode("utf-8"))
            if size > MAX_BODY:
                raise SecurityError("Samples exceed the 8 MiB result budget")
            samples.append(value)
        return {"name": args.name, "samples": samples}
    finally:
        for var, old_budget in previous:
            var.budget = old_budget


def execute(args, stop):
    if args.command == "doctor":
        return doctor()
    if args.command == "sessions":
        from .session_log import list_sessions, prune_sessions, session_root
        if args.prune:
            if args.dry_run and args.yes:
                raise UsageError("choose --dry-run or --yes, not both")
            if not args.yes and not args.dry_run:
                raise UsageError("--prune requires --yes or --dry-run")
            try:
                return prune_sessions(keep=args.keep, older_than_days=args.older_than,
                                      dry_run=args.dry_run)
            except ValueError as exc:
                raise UsageError(str(exc)) from None
        if (args.keep != 20 or args.older_than is not None
                or args.dry_run or args.yes):
            raise UsageError("--keep/--older-than/--dry-run/--yes require --prune")
        return {"root": str(session_root()), "sessions": list_sessions()}
    if args.command == "scripts":
        return list_scripts(args.scripts_dir or default_scripts_dir())
    if args.command == "gui":
        hide_console_window()
        from .gui import GuiUnavailable, run_gui
        try:
            return run_gui(args)
        except GuiUnavailable as exc:
            raise RuntimeError(
                f"Cannot open the GUI ({exc}); pass --no-gui for the command-line interface"
            ) from None
    if args.command == "serve":
        from .serve import run_server
        return run_server(stop, enable_agent=not args.no_agent, enable_session_log=not args.no_session_log)
    if args.command == "agent":
        try:
            from .agent import run_cli_agent
        except ModuleNotFoundError as exc:
            raise RuntimeError(f"Agent dependencies unavailable ({exc}); install pymybot[agent] "
                               "(source checkout: pip install -e '.[agent]'), "
                               "or use --no-agent --input MT") from exc
        return asyncio.run(run_cli_agent(args, stop))
    action, base_dir, matrices = None, None, None
    if getattr(args, "input", None):
        path = Path(args.input).absolute()
        action, base_dir = read_file(path), path.parent
        matrices = expand_includes(parse_matrices(action), base_dir)
    if hasattr(args, "sql"):
        checked_text(args.sql)
    if args.command == "run" and len(dict(args.var)) != len(args.var):
        raise UsageError("--var names must be distinct")
    if args.command == "sample":
        safe_ident(args.name)
        if (args.count - 1) * args.interval_ms / 1000 >= args.timeout:
            raise UsageError("Sample intervals exhaust --timeout; reduce count/interval or increase timeout")
    robot = Robot(read_file(args.robot), module_paths=args.module_path,
                  camera_src_root=args.camera_src_dir, stop_event=stop,
                  allow_hardware=getattr(args, "allow_hardware", False))
    robot._validate(robot.tables)
    if args.command == "check":
        return {"valid": True, "activated": False, "tables": list(robot.tables),
                "action_blocks": [matrix.name for matrix in matrices] if matrices is not None else None}
    if args.command == "hardware":
        hardware = [{"name": name, "type": table.name,
                     "metadata": {col: table.inherited(row, i) for i, col in enumerate(table.header) if col != "name"}}
                    for name, (table, row) in robot._rows(robot.tables).items()
                    if table.name not in {"Alias", "Vars"}]
        return {"hardware": hardware, "activated": False}
    if args.command == "query":
        return {"output": robot.query_sql(args.sql), "activated": False}
    if args.command == "sample" and args.name not in robot._rows(robot.tables):
        raise ScriptError(f"Hardware variable '{args.name}' is not defined")
    try:
        robot.active()
        if args.command == "run":
            return {"outputs": robot.run(action, base_dir=str(base_dir), vars=dict(args.var), timeout=args.timeout)}
        if args.command == "sample":
            return sample(robot, args, stop)
        return {"output": robot.apply_sql(args.sql)}
    finally:
        # Also required when active() fails after opening only some devices.
        robot.deactivate()


def hide_console_window():
    """A double-clicked frozen exe should show the GUI, not a console behind it."""
    if os.name != "nt" or not frozen():
        return
    try:
        import ctypes
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, 0)
    except (AttributeError, OSError):
        pass


def disable_windows_faulthandler():
    """LuaJIT on Windows x64 raises every Lua error() as SEH exception 0xE24C4A02.

    CPython's faulthandler only whitelists MSVC/COM codes, so it treats each one as a
    crash and walks all thread stacks inside the exception handler. With daemon
    threads running that races and can segfault, breaking the one-JSON contract.
    """
    if sys.platform == "win32" and faulthandler.is_enabled():
        faulthandler.disable()
        print("pymybot: faulthandler disabled on Windows (LuaJIT SEH errors are not crashes)",
              file=sys.stderr)


def utf8_streams():
    """stdout/stderr are UTF-8 regardless of the console/pipe locale.

    Windows pipes default to the ANSI code page (e.g. GBK): Chinese results reached
    consumers as GBK bytes, and characters outside that code page made print() raise
    before any JSON was written. RFC 8259 requires UTF-8 for the JSON channel; stderr
    follows so callers decode both streams one way (as Python's UTF-8 mode, the
    default from 3.15 per PEP 686, would). stderr keeps backslashreplace.
    """
    # Windowed builds have no console streams; print() must not raise there.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w", encoding="utf-8", errors="backslashreplace")
    for stream, errors in ((sys.stdout, "strict"), (sys.stderr, "backslashreplace")):
        encoding = (getattr(stream, "encoding", None) or "").lower().replace("-", "").replace("_", "")
        reconfigure = getattr(stream, "reconfigure", None)
        if encoding != "utf8" and reconfigure is not None:
            reconfigure(encoding="utf-8", errors=errors)


def main(argv=None):
    utf8_streams()
    disable_windows_faulthandler()
    stop = threading.Event()
    handlers = {}
    args = None
    try:
        args = parse_args(argv)
        if args.command in {"run", "sample", "apply-sql", "agent", "serve"} and threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM):
                handlers[sig] = signal.signal(sig, lambda *_: stop.set())
        # Python prints and Lua diagnostics must not contaminate the JSON channel.
        with redirect_stdout(sys.stderr):
            result = execute(args, stop)
        output = dumps({"ok": True, "command": args.command, **result})
        code = 0
    except (KeyboardInterrupt, AgentInterrupted) as exc:
        stop.set()
        extra = {key: getattr(exc, key) for key in ("tool_events", "cleanup_errors") if hasattr(exc, key)}
        output = dumps({"ok": False, "error": {"type": "KeyboardInterrupt", "message": "Interrupted"}, **extra})
        code = 130
    except Exception as exc:
        extra = {key: getattr(exc, key) for key in ("tool_events", "cleanup_errors") if hasattr(exc, key)}
        output = dumps({"ok": False, "error": {"type": type(exc).__name__, "message": str(exc)}, **extra})
        print(f"pymybot: {exc}", file=sys.stderr)
        code = 2 if isinstance(exc, UsageError) else 1
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    print(output)
    return code
