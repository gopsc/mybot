"""Controller commands; stdout carries exactly one JSON result."""
from __future__ import annotations

import argparse
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
from .errors import ScriptError
from .hardware import Budget, ensure_ok, safe_ident
from .include import expand_includes
from .matrix import parse_matrices
from .paths import asset_path
from .robot import MAX_BINDING_BYTES, Robot, module_roots
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
        return safe_ident(name), checked_text(text, MAX_BINDING_BYTES)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def variable_env(value):
    name, separator, env_name = value.partition("=")
    try:
        if not separator:
            raise ValueError("expected NAME=ENVVAR")
        if not env_name or env_name.strip() != env_name or "=" in env_name:
            raise ValueError("environment variable name must be non-empty without whitespace or '='")
        return safe_ident(name), env_name
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def session_bindings(args):
    """Merge --var/--var-env once, before any robot is constructed."""
    bindings = {}
    for name, value in getattr(args, "var", None) or []:
        if name in bindings:
            raise UsageError("--var/--var-env names must be distinct")
        bindings[name] = value
    for name, env_name in getattr(args, "var_env", None) or []:
        if name in bindings:
            raise UsageError("--var/--var-env names must be distinct")
        if env_name not in os.environ:
            raise UsageError(f"--var-env {name}: environment variable {env_name} is not set")
        try:
            bindings[name] = checked_text(os.environ[env_name], MAX_BINDING_BYTES)
        except SecurityError as exc:
            raise UsageError(f"--var-env {name}: {exc}") from None
    return bindings


def parser():
    p = ArgumentParser(
        prog="pymybot", allow_abbrev=False,
        description="Robot controller. Structure SQL declares hardware, Python/Lua drivers implement "
                    "devices and MT actions describe timing. Command results are JSON on stdout.",
        epilog="Use only trusted Lua modules: LuaJIT FFI is not malicious-code isolation. "
               "Activation itself may write to devices, including when sampling. "
               "Examples: pymybot check --robot relay-test.sql --input relay-test.mt | "
               "pymybot run --robot relay-test.sql --input relay-test.mt --timeout 10")
    commands = p.add_subparsers(dest="command", required=True)
    descriptions = {
        "check": "Statically validate structure SQL, modules/references and optional action Includes",
        "discover": "Enumerate host UART/FTDI/I2C/SPI devices read-only and suggest structure SQL",
        "hardware": "List declared hardware without probing or activating it",
        "scripts": "List relative .mt script paths without executing Lua",
        "query": "Read structure tables using SELECT * or SHOW TABLES, without activation",
        "run": "Activate, execute an action script and deactivate (virtual-only by default)",
        "sample": "Activate and read a named variable; activation itself may write to devices",
        "apply-sql": "Apply SQL to a temporarily active robot; does not write the structure file",
        "mcp": "Standard MCP stdio server for MCP clients (read-only unless --allow-execution)",
        "doctor": "Check the interpreter, optional dependencies and bundled assets without touching hardware",
        "new": "Create a runnable robot SQL/MT/driver skeleton in the current directory",
        "assets": "List, read, write and delete bundled robots/modules/scripts asset files",
    }
    for name, description in descriptions.items():
        command = commands.add_parser(name, help=description, description=description, allow_abbrev=False)
        if name == "new":
            command.add_argument("name", help="robot name, for example mybot-arm")
            command.add_argument("--dir", default=".", metavar="DIR",
                                 help="workspace root (default: current directory)")
            command.add_argument("--force", action="store_true", help="overwrite existing generated files")
            continue
        if name == "assets":
            kinds = ("robots", "modules", "scripts")
            actions = command.add_subparsers(dest="asset_action", required=True)
            listing = actions.add_parser("list", help="list asset files under a kind root", allow_abbrev=False)
            listing.add_argument("--kind", choices=kinds + ("all",), default="all",
                                 help="which asset root to list (default: all)")
            reader = actions.add_parser("read", help="read one asset file as UTF-8 text", allow_abbrev=False)
            reader.add_argument("--kind", choices=kinds, required=True)
            reader.add_argument("--path", required=True, metavar="REL",
                                help="path relative to the kind's asset root")
            writer = actions.add_parser("write", help="create or overwrite one asset file", allow_abbrev=False)
            writer.add_argument("--kind", choices=kinds, required=True)
            writer.add_argument("--path", required=True, metavar="REL",
                                help="path relative to the kind's asset root")
            source = writer.add_mutually_exclusive_group(required=True)
            source.add_argument("--content", metavar="TEXT", help="UTF-8 text content")
            source.add_argument("--content-file", metavar="FILE", help="read content from a regular file")
            writer.add_argument("--force", action="store_true", help="overwrite an existing file")
            deleter = actions.add_parser("delete", help="delete one asset file", allow_abbrev=False)
            deleter.add_argument("--kind", choices=kinds, required=True)
            deleter.add_argument("--path", required=True, metavar="REL",
                                 help="path relative to the kind's asset root")
            deleter.add_argument("--yes", action="store_true", help="confirm permanent deletion")
            continue
        if name == "mcp":
            command.add_argument("--robot", required=True, metavar="FILE",
                                 help="structure SQL file (at most 8 MiB)")
            command.add_argument("--module-path", action="append", metavar="DIR",
                                 help="trusted Lua module root; repeatable")
            command.add_argument("--scripts-dir", default=default_scripts_dir(), metavar="DIR",
                                 help="trusted .mt script root; default: packaged assets/scripts, else source scripts")
            command.add_argument("--allow-execution", action="store_true",
                                 help="permit action scripts and variable reads; "
                                      "static tools stay available either way")
            command.add_argument("--allow-hardware", action="store_true",
                                 help="permit physical devices; requires --allow-execution")
            command.add_argument("--timeout", type=positive_timeout, default=180, metavar="SECONDS",
                                 help=f"cooperative execution budget, >0 and <={MAX_TIMEOUT} (default: 180)")
            command.add_argument("--var", type=variable, action="append", default=[], metavar="NAME=VALUE",
                                 help="session alias binding and Alias/Vars structure override; repeatable")
            command.add_argument("--var-env", type=variable_env, action="append", default=[], metavar="NAME=ENVVAR",
                                 help="session alias binding read from an environment variable at run time; repeatable")
            continue
        if name == "discover":
            command.add_argument("--buses", default="all",
                                 help="comma-separated subset of i2c,spi,uart,ftdi or all (default: all)")
            command.add_argument("--probe", action="store_true",
                                 help="briefly open each real UART port to report in-use state;"
                                      " nothing is written, but DTR/RTS may pulse")
            continue
        if name == "scripts":
            command.add_argument("--scripts-dir", help="default: packaged assets/scripts, else source scripts")
            continue
        if name == "doctor":
            continue
        command.add_argument("--robot", required=True, metavar="FILE",
                             help="structure SQL file (at most 8 MiB)")
        command.add_argument("--module-path", action="append", metavar="DIR", help="trusted Lua module root; repeatable")
        if name in {"check", "run"}:
            command.add_argument("--input", required=name == "run", metavar="MT",
                                 help="action script to validate or run")
        if name in {"query", "apply-sql"}:
            command.add_argument("--sql", required=True, metavar="TEXT", help="SQL text (at most 8 MiB)")
        if name in {"run", "sample", "apply-sql"}:
            command.add_argument("--allow-hardware", action="store_true",
                                 help="permit physical devices for direct commands")
        if name in {"run", "sample"}:
            command.add_argument("--timeout", type=positive_timeout, default=180, metavar="SECONDS",
                                 help=f"cooperative execution budget, >0 and <={MAX_TIMEOUT} (default: 180)")
        command.add_argument("--var", type=variable, action="append", default=[], metavar="NAME=VALUE",
                             help="session alias binding (text) and Alias/Vars structure override;"
                                  " repeat with distinct names")
        command.add_argument("--var-env", type=variable_env, action="append", default=[], metavar="NAME=ENVVAR",
                             help="session alias binding read from an environment variable at run time;"
                                  " repeat with distinct names")
        if name == "sample":
            command.add_argument("--name", required=True, help="declared variable name")
            command.add_argument("--count", type=bounded_int(1, MAX_SAMPLES), default=1,
                                 help=f"number of samples, 1..{MAX_SAMPLES} (default: 1)")
            command.add_argument("--interval-ms", type=bounded_int(0, MAX_INTERVAL_MS), default=0,
                                 help=f"delay between samples, 0..{MAX_INTERVAL_MS} (default: 0)")
    return p


def parse_args(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments in (["--version"], ["-V"]):
        print(f"pymybot {__version__}")
        raise SystemExit(0)
    args = parser().parse_args(arguments)
    # --robot/--input default to the bundled asset roots: an absolute path or a
    # path that already exists relative to CWD wins, otherwise a bare or relative
    # name resolves under assets/robots (or assets/scripts) so the Skill is
    # self-contained without breaking existing absolute/CWD-relative callers.
    if getattr(args, "robot", None):
        args.robot = resolve_asset_relative(args.robot, "robots")
    if getattr(args, "input", None):
        args.input = resolve_asset_relative(args.input, "scripts")
    if args.command == "mcp" and args.allow_hardware and not args.allow_execution:
        raise UsageError("--allow-hardware requires --allow-execution")
    return args


def default_scripts_dir():
    return asset_path("scripts")


ASSET_SUFFIXES = {"robots": (".sql",), "modules": (".py", ".lua"), "scripts": (".mt",)}


def resolve_asset_relative(value, kind):
    """Resolve a possibly-relative --robot/--input against its bundled asset root.

    Absolute paths and paths that already exist relative to CWD are returned
    unchanged; any other relative name resolves under ``assets/<kind>``.
    """
    if value is None:
        return None
    path = Path(value)
    if path.is_absolute() or path.exists():
        return value
    return str(asset_path(kind) / value)


def _asset_root(kind):
    root = asset_path(kind)
    if not root.is_dir():
        raise UsageError(f"Asset root for '{kind}' does not exist: {root}")
    return root.resolve()


def _asset_target(kind, rel):
    """Resolve a relative asset path safely under its kind root."""
    if not isinstance(rel, str) or not rel or rel.strip() != rel:
        raise UsageError("Asset path must be a non-empty, trimmed relative path")
    candidate = Path(rel)
    if candidate.is_absolute():
        raise UsageError("Asset path must be relative to the asset root")
    root = _asset_root(kind)
    target = (root / candidate).resolve()
    if target != root and root not in target.parents:
        raise UsageError("Asset path escaped the asset root")
    if target.suffix not in ASSET_SUFFIXES[kind]:
        raise UsageError(
            f"Asset path for '{kind}' must end in one of {', '.join(ASSET_SUFFIXES[kind])}")
    return root, target


def assets_command(args):
    """List/read/write/delete files under the bundled robots/modules/scripts roots."""
    action = args.asset_action
    if action == "list":
        kinds = ("robots", "modules", "scripts") if args.kind == "all" else (args.kind,)
        listed = {}
        for kind in kinds:
            root = _asset_root(kind)
            files = sorted(
                path.relative_to(root).as_posix()
                for path in root.rglob("*")
                if path.suffix in ASSET_SUFFIXES[kind]
                and path.is_file() and not path.is_symlink())
            listed[kind] = {"root": str(root), "files": files}
        if args.kind == "all":
            return {"assets": listed, "activated": False}
        return {"kind": args.kind, **listed[args.kind], "activated": False}
    root, target = _asset_target(args.kind, args.path)
    relative = target.relative_to(root).as_posix()
    if action == "read":
        if not target.is_file() or target.is_symlink():
            raise UsageError(f"Asset is not an existing regular file: {relative}")
        content = read_file(target)
        return {"kind": args.kind, "path": relative,
                "bytes": len(content.encode("utf-8")), "content": content}
    if action == "write":
        content = args.content if args.content is not None else read_file(Path(args.content_file))
        content = checked_text(content)
        existed = target.exists()
        if existed and not args.force:
            raise UsageError(f"Asset already exists (use --force to overwrite): {relative}")
        if target.is_symlink():
            raise UsageError("Refusing to write through a symlink")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        verb = "overwritten" if existed else "created"
        return {"kind": args.kind, "path": relative, verb: True,
                "bytes": len(content.encode("utf-8"))}
    if not args.yes:
        raise UsageError("assets delete requires --yes")
    if not target.is_file() or target.is_symlink():
        raise UsageError(f"Asset is not an existing regular file: {relative}")
    target.unlink()
    return {"kind": args.kind, "path": relative, "deleted": True}



def doctor():
    """Report the interpreter, dependencies and assets without hardware I/O."""
    required = [
        ("lupa", "lupa", "Lua runtime"),
        ("sqlparse", "sqlparse", "SQL tokenizer"),
        ("serial", "pyserial", "UART"),
        ("pyftdi", "pyftdi", "I2C/SPI"),
        ("PIL", "pillow", "image codecs"),
    ]
    optional = [
        ("mcp", "mcp", "MCP server", "pip install pymybot[mcp]"),
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
    if checks[0]["status"] == "ok":
        try:
            from .runtime import LUA_BACKEND, LUA_FFI
        except Exception as exc:
            checks[0]["status"] = "missing"
            checks[0]["error"] = type(exc).__name__
            checks[0]["hint"] = "Install a lupa wheel with LuaJIT or standard Lua support"
        else:
            checks[0]["backend"] = LUA_BACKEND
            if not LUA_FFI:
                checks.append({"name": "lua.ffi", "label": "LuaJIT FFI", "optional": True,
                               "status": "warning",
                               "detail": "LuaJIT is unavailable; standard Lua fallback is active; "
                                         "FFI-based drivers are unsupported"})
    if sys.platform.startswith("linux"):
        # smbus2 ships in the base Linux install; spidev stays opt-in because it
        # usually builds from source. Report both before a driver open fails.
        i2c = module_check("smbus2", "smbus2", "I2C (/dev/i2c-*)")
        if i2c["status"] != "ok":
            i2c["hint"] = "Install the Linux I2C dependency: pip install 'smbus2>=0.5'"
        checks.append(i2c)
        checks.append(module_check(
            "spidev", "spidev", "SPI (/dev/spidev*)", optional_check=True,
            hint="SPI needs spidev: pip install 'spidev>=3.6' "
                 "(source checkout: pip install -e '.[linux]')"))
    suffixes = {"modules": (".py", ".lua"), "robots": (".sql",), "scripts": (".mt",)}
    assets = {}
    for name, extensions in suffixes.items():
        path = asset_path(name)
        count = sum(1 for suffix in extensions for _ in path.rglob("*" + suffix)) if path.is_dir() else 0
        assets[name] = {"path": str(path), "exists": path.is_dir(), "files": count}
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
    if args.command == "new":
        from .scaffold import create_robot
        return create_robot(args.dir, args.name, force=args.force)
    if args.command == "assets":
        return assets_command(args)
    if args.command == "doctor":
        return doctor()
    if args.command == "discover":
        from .discover import DiscoveryError, discover, parse_buses
        try:
            return discover(parse_buses(args.buses), probe=args.probe)
        except DiscoveryError as exc:
            raise UsageError(str(exc)) from None
    if args.command == "scripts":
        return list_scripts(args.scripts_dir or default_scripts_dir())
    if args.command == "mcp":
        try:
            from .mcp_server import run_server
        except ModuleNotFoundError as exc:
            raise RuntimeError(f"MCP dependencies unavailable ({exc}); install pymybot[mcp] "
                               "(source checkout: pip install -e '.[mcp]')") from exc
        bindings = session_bindings(args)
        return run_server(stop, robot_path=args.robot, scripts_dir=args.scripts_dir,
                          module_paths=args.module_path,
                          vars=bindings, allow_execution=args.allow_execution,
                          allow_hardware=args.allow_hardware,
                          timeout=args.timeout)
    bindings = session_bindings(args)
    action, base_dir, matrices = None, None, None
    if getattr(args, "input", None):
        path = Path(args.input).absolute()
        action, base_dir = read_file(path), path.parent
        matrices = expand_includes(parse_matrices(action), base_dir)
    if hasattr(args, "sql"):
        checked_text(args.sql)
    if args.command == "sample":
        safe_ident(args.name)
        if (args.count - 1) * args.interval_ms / 1000 >= args.timeout:
            raise UsageError("Sample intervals exhaust --timeout; reduce count/interval or increase timeout")
    robot = Robot(read_file(args.robot), module_paths=args.module_path, stop_event=stop,
                  allow_hardware=getattr(args, "allow_hardware", False), vars=bindings)
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
            return {"outputs": robot.run(action, base_dir=str(base_dir), vars=bindings, timeout=args.timeout)}
        if args.command == "sample":
            return sample(robot, args, stop)
        return {"output": robot.apply_sql(args.sql)}
    finally:
        # A signal is an operator stop: try the drivers' safe() hooks before
        # releasing. Ordinary failures keep the historical destroy-only cleanup.
        if stop.is_set():
            try:
                robot.abort("cli-signal")
            except Exception as exc:
                print(f"Abort failed: {exc}", file=sys.stderr)
                robot.deactivate()
        else:
            # Also required when active() fails after opening only some devices.
            robot.deactivate()


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
    # Detect the protocol command before parsing: even usage errors must not
    # write CLI JSON onto the MCP channel.
    requested = list(sys.argv[1:] if argv is None else argv)
    protocol = bool(requested) and requested[0] == "mcp"
    try:
        args = parse_args(argv)
        # MCP reserves stdout for JSON-RPC: no final CLI JSON on that channel.
        protocol = args.command == "mcp"
        if (args.command in {"run", "sample", "apply-sql", "mcp"}
                and threading.current_thread() is threading.main_thread()):
            for sig in (signal.SIGINT, signal.SIGTERM):
                handlers[sig] = signal.signal(sig, lambda *_: stop.set())
        # Python prints and Lua diagnostics must not contaminate the JSON channel.
        with redirect_stdout(sys.stderr):
            result = execute(args, stop)
        if protocol:
            return 0
        output = dumps({"ok": True, "command": args.command, **result})
        code = 0
    except KeyboardInterrupt:
        stop.set()
        if protocol:
            return 130
        output = dumps({"ok": False, "error": {"type": "KeyboardInterrupt", "message": "Interrupted"}})
        code = 130
    except Exception as exc:
        print(f"pymybot: {exc}", file=sys.stderr)
        code = 2 if isinstance(exc, UsageError) else 1
        if protocol:
            return code
        output = dumps({"ok": False, "error": {"type": type(exc).__name__, "message": str(exc)}})
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    print(output)
    return code
