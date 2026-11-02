"""Run one action declared by a trusted ``skill.json`` manifest.

The model never supplies an executable, argv or a path outside a declared root.
The manifest is operator-authored code configuration, so Skill directories and
entrypoints are trusted in-process content, with the same standing as drivers.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path, PureWindowsPath
import re
import stat
import subprocess
import sys
import tempfile
import time

from .agent_skills import SkillsLibrary
from .paths import frozen
from .process import kill_tree
from .security import SecurityError, checked_text, read_file

MAX_MANIFEST_BYTES = 64 * 1024
MAX_STDOUT_BYTES = 64 * 1024
MAX_STDERR_BYTES = 16 * 1024
MAX_TIMEOUT = 3600
MAX_ACTIONS = 64
MAX_PARAMS = 16
MAX_ARGV = 64
_NAME = re.compile(r"[a-z][a-z0-9_-]{0,63}\Z")
_PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]{0,63})\}\Z")
_HARDWARE_FLAG = "--allow-hardware"
_SAFE_ENV = (
    "PATH", "PATHEXT", "SYSTEMROOT", "WINDIR", "COMSPEC", "HOME", "USERPROFILE",
    "TEMP", "TMP", "TMPDIR", "MYBOT_HOME",
)


class SkillRunError(RuntimeError):
    pass


def _relative_file(value, suffix):
    checked_text(value, 4096)
    win = PureWindowsPath(value)
    if (not value or win.drive or win.root or value.startswith("/")
            or "\\" in value or ":" in value
            or any(part in {"", ".", ".."} for part in value.split("/"))
            or not value.endswith(suffix)):
        raise SecurityError(f"Expected a relative {suffix} path")
    return value


def _no_links(path, stop):
    if path.is_symlink():
        raise SecurityError("Linked Skill paths are not allowed")
    current = path
    stop = stop.resolve(strict=True)
    while True:
        try:
            info = current.lstat()
        except OSError as exc:
            raise SecurityError("Cannot inspect Skill path") from exc
        if (stat.S_ISLNK(info.st_mode)
                or getattr(info, "st_file_attributes", 0) & 0x400
                or getattr(current, "is_junction", lambda: False)()):
            raise SecurityError("Linked Skill paths are not allowed")
        if current == stop:
            break
        current = current.parent


def _regular_file(path, stop, suffix=None):
    _no_links(path, stop)
    try:
        resolved = path.resolve(strict=True)
        info = resolved.stat()
    except (OSError, RuntimeError):
        raise SecurityError("Skill file does not exist") from None
    if not resolved.is_relative_to(stop) or not stat.S_ISREG(info.st_mode):
        raise SecurityError("Skill file must be a regular file inside the Skill")
    if suffix is not None and resolved.suffix != suffix:
        raise SecurityError(f"Expected a {suffix} file")
    return resolved


def _number(spec, value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SecurityError(f"Argument '{name}' must be a number")
    value = float(value)
    if not math.isfinite(value):
        raise SecurityError(f"Argument '{name}' must be finite")
    low, high = spec.get("min"), spec.get("max")
    if low is not None and value < low:
        raise SecurityError(f"Argument '{name}' is below the minimum")
    if high is not None and value > high:
        raise SecurityError(f"Argument '{name}' exceeds the maximum")
    return format(value, ".15g")


class SkillRunner:
    """Load one Skill manifest, validate parameters and run its fixed entrypoint."""

    def __init__(self, skills, *, roots=None):
        if not isinstance(skills, SkillsLibrary):
            raise SecurityError("Skills are not configured")
        self.skills = skills
        self.roots = {name: Path(path).absolute() for name, path in (roots or {}).items()
                      if _NAME.fullmatch(name)}
        if len(self.roots) > 16:
            raise SecurityError("Too many Skill roots")

    def _manifest(self, skill):
        checked_text(skill, 64)
        if not _NAME.fullmatch(skill):
            raise SecurityError("Invalid Skill name")
        entry = self.skills.skills.get(skill)
        if entry is None:
            raise SecurityError("Skill is not registered")
        directory = entry["directory"].resolve(strict=True)
        path = _regular_file(directory / "skill.json", directory, ".json")
        try:
            text = read_file(path, MAX_MANIFEST_BYTES)
            document = json.loads(
                text, parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            raise SecurityError(f"Invalid skill.json: {exc}") from None
        if not isinstance(document, dict) or document.get("version") != 1:
            raise SecurityError("skill.json must be a version 1 object")
        run = document.get("run")
        if not isinstance(run, dict) or set(run) - {"entrypoint", "packaged", "actions"}:
            raise SecurityError("skill.json run must declare entrypoint and actions")
        if set(run) < {"entrypoint", "actions"}:
            raise SecurityError("skill.json run must declare entrypoint and actions")
        if run.get("packaged", "source") not in {"source", "cli"}:
            raise SecurityError("Skill packaged mode must be source or cli")
        entrypoint = _relative_file(run["entrypoint"], ".py")
        actions = run["actions"]
        if not isinstance(actions, dict) or not 0 < len(actions) <= MAX_ACTIONS:
            raise SecurityError("skill.json must declare 1..64 actions")
        return directory, entrypoint, actions, run.get("packaged", "source")

    def _action(self, actions, action):
        checked_text(action, 64)
        if not _NAME.fullmatch(action):
            raise SecurityError("Invalid Skill action")
        spec = actions.get(action)
        if not isinstance(spec, dict) or set(spec) - {"effect", "output", "argv", "params", "hardwareFlag"}:
            raise SecurityError("Unknown Skill action")
        if spec.get("effect") not in {"read", "execute"} or spec.get("output") != "json":
            raise SecurityError("Skill action must be read/execute with JSON output")
        argv = spec.get("argv")
        params = spec.get("params", {})
        if (not isinstance(argv, list) or not 0 < len(argv) <= MAX_ARGV
                or any(not isinstance(item, str) or not item for item in argv)):
            raise SecurityError("Skill action argv must be a nonempty string list")
        if not isinstance(params, dict) or len(params) > MAX_PARAMS:
            raise SecurityError("Skill action params must be an object")
        for item in argv:
            if item == _HARDWARE_FLAG or (item.startswith("--") and item not in {"--robot", "--input", "--timeout"}):
                raise SecurityError("Skill argv contains a reserved option")
            match = _PLACEHOLDER.fullmatch(item)
            if "{" in item and (match is None or match.group(1) not in params):
                raise SecurityError("Skill argv contains an unknown placeholder")
        hardware = spec.get("hardwareFlag")
        if hardware not in (None, _HARDWARE_FLAG) or (hardware and spec["effect"] != "execute"):
            raise SecurityError("Invalid Skill hardware flag")
        for name, param in params.items():
            if not _NAME.fullmatch(name) or not isinstance(param, dict):
                raise SecurityError("Invalid Skill parameter")
            kind = param.get("type")
            if kind == "path":
                if set(param) - {"type", "scope", "suffix", "required"}:
                    raise SecurityError("Invalid path parameter")
                scopes, suffix, required = param.get("scope"), param.get("suffix"), param.get("required", False)
                if (not isinstance(scopes, list) or not scopes
                        or any(not isinstance(scope, str) or not _NAME.fullmatch(scope) for scope in scopes)):
                    raise SecurityError("Invalid path scopes")
                if not isinstance(suffix, str) or not suffix.startswith(".") or "/" in suffix:
                    raise SecurityError("Invalid path suffix")
                _relative_file("placeholder" + suffix, suffix)
                if type(required) is not bool:
                    raise SecurityError("Invalid required flag")
            elif kind == "number":
                if set(param) - {"type", "min", "max", "default", "required"}:
                    raise SecurityError("Invalid number parameter")
                for key in ("min", "max", "default"):
                    if key in param and (isinstance(param[key], bool)
                                         or not isinstance(param[key], (int, float))
                                         or not math.isfinite(param[key])):
                        raise SecurityError("Invalid numeric limit")
                if ("min" in param and "max" in param and param["min"] > param["max"]):
                    raise SecurityError("Invalid numeric range")
            else:
                raise SecurityError("Unsupported Skill parameter type")
        return spec

    def _resolve_path(self, value, scopes, suffix, name, roots):
        if type(value) is not dict or set(value) != {"scope", "path"}:
            raise SecurityError(f"Argument '{name}' must contain scope and path")
        scope = value["scope"]
        if not isinstance(scope, str) or scope not in scopes:
            raise SecurityError(f"Scope for '{name}' is not allowed")
        root = roots.get(scope)
        if root is None or not root.is_dir():
            raise SecurityError(f"Scope for '{name}' is unavailable")
        relative = _relative_file(value["path"], suffix)
        return str(_regular_file(root.joinpath(*relative.split("/")), root, suffix))

    def _arguments(self, spec, arguments, roots):
        if arguments is None:
            arguments = {}
        if type(arguments) is not dict:
            raise SecurityError("Skill arguments must be an object")
        params = spec.get("params", {})
        if not arguments.keys() <= params.keys():
            raise SecurityError("Unknown Skill arguments")
        values = {}
        for name, param in params.items():
            present = name in arguments
            if not present:
                if param.get("required"):
                    raise SecurityError(f"Missing Skill argument '{name}'")
                if "default" in param:
                    values[name] = format(float(param["default"]), ".15g")
                continue
            value = arguments[name]
            if param["type"] == "path":
                values[name] = self._resolve_path(value, param["scope"], param["suffix"], name, roots)
            else:
                values[name] = _number(param, value, name)
        return values

    def _argv(self, spec, values, allow_hardware):
        argv = [values.get(token[1:-1], token) if _PLACEHOLDER.fullmatch(token) else token
                for token in spec["argv"]]
        if spec.get("hardwareFlag") and allow_hardware:
            argv.append(_HARDWARE_FLAG)
        return argv

    @staticmethod
    def _environment():
        env = {name: os.environ[name] for name in _SAFE_ENV if os.environ.get(name)}
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        return env

    @staticmethod
    def _read(stream, cap):
        stream.seek(0)
        data = stream.read(cap + 1)
        return data[:cap], len(data) > cap

    def run(self, skill, action, arguments=None, *, allow_hardware=False, deadline=None,
            check=lambda: None, started=None):
        """Run one manifest action; caller supplies cancellation and deadline checks."""
        directory, entrypoint, actions, packaged = self._manifest(skill)
        spec = self._action(actions, action)
        roots = {**self.roots, "skill": directory,
                 "skill_assets": directory / "references" / "assets"}
        values = self._arguments(spec, arguments, roots)
        argv = self._argv(spec, values, allow_hardware)
        candidate = directory.joinpath(*entrypoint.split("/"))
        if candidate.is_file():
            executable = _regular_file(candidate, directory, ".py")
            command = [sys.executable, "-I", str(executable), *argv]
        elif packaged == "cli":
            command = ([sys.executable, *argv] if frozen()
                       else [sys.executable, "-I", "-m", "pymybot", *argv])
        else:
            raise SecurityError("Skill entrypoint does not exist")
        now = time.monotonic()
        limit = deadline if deadline is not None else now + MAX_TIMEOUT
        process = None
        stdout, stderr = tempfile.TemporaryFile(), tempfile.TemporaryFile()
        try:
            check()
            if now >= limit:
                raise SkillRunError("Skill process timed out")
            process = subprocess.Popen(
                command,
                cwd=str(directory), env=self._environment(), stdin=subprocess.DEVNULL,
                stdout=stdout, stderr=stderr, start_new_session=os.name != "nt")
            if started is not None:
                started()
            while True:
                check()
                now = time.monotonic()
                if now >= limit:
                    kill_tree(process)
                    raise SkillRunError("Skill process timed out")
                try:
                    process.wait(timeout=min(0.1, max(0.001, limit - now)))
                    break
                except subprocess.TimeoutExpired:
                    continue
            check()
            code = process.returncode
            out, out_truncated = self._read(stdout, MAX_STDOUT_BYTES)
            err, err_truncated = self._read(stderr, MAX_STDERR_BYTES)
        except BaseException:
            if process is not None and process.poll() is None:
                kill_tree(process)
                try:
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            raise
        finally:
            stdout.close()
            stderr.close()
        output = None
        output_error = None
        try:
            decoded = out.decode("utf-8")
            output = json.loads(decoded, parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))
            if not isinstance(output, dict):
                raise ValueError("expected a JSON object")
        except (UnicodeDecodeError, ValueError) as exc:
            output_error = f"Invalid JSON output: {exc}"
        text = err.decode("utf-8", "replace")
        return {
            "skill": skill, "action": action, "exit_code": code, "output": output,
            "output_error": output_error, "stderr": text,
            "stdout_truncated": out_truncated, "stderr_truncated": err_truncated,
        }