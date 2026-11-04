"""Run one trusted skill script.

Skills are trusted operator-installed code. Anthropic-style skills expose their
entry script under ``scripts/``; a legacy ``skill.json`` manifest, when present,
still fixes the entrypoint and argv shape. The model supplies a skill name, an
action name and arguments, never an entrypoint. Paths, parameter bounds, output
size and the skill subprocess budget are deliberately unrestricted because the
operator opted into trusted skills.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from .agent_skills import CLI_SKILLS, SkillsLibrary
from .paths import frozen
from .process import kill_tree
from .security import SecurityError

_PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]{0,63})\}")
_HARDWARE_FLAG = "--allow-hardware"
_SAFE_ENV = (
    "PATH", "PATHEXT", "SYSTEMROOT", "WINDIR", "COMSPEC", "HOME", "USERPROFILE",
    "TEMP", "TMP", "TMPDIR", "MYBOT_HOME",
)


def python_scripts(directory):
    """Return the top-level runnable Python scripts of one skill directory."""
    scripts_dir = Path(directory) / "scripts"
    if not scripts_dir.is_dir() or scripts_dir.is_symlink():
        return []
    return sorted(path for path in scripts_dir.iterdir()
                  if path.suffix == ".py" and path.is_file() and not path.is_symlink())


def _generic_actions(stem):
    """One manifest-free action that forwards a documented CLI invocation."""
    return {"run": {
        "description": f"Run {stem} with CLI arguments",
        "effect": "read",
        "output": "json",
        "params": {
            "command": {
                "type": "string",
                "description": "CLI subcommand documented by the skill, for example doctor",
            },
            "args": {
                "type": "array",
                "description": "Additional CLI arguments, one list item per token",
            },
        },
        "passthrough": True,
    }}


class SkillRunner:
    """Resolve one trusted Skill entrypoint and run it in a bounded subprocess."""

    def __init__(self, skills, *, roots=None):
        if not isinstance(skills, SkillsLibrary):
            raise SecurityError("Skills are not configured")
        self.skills = skills
        self.roots = {name: Path(path).absolute() for name, path in (roots or {}).items()}

    def _manifest(self, skill):
        entry = self.skills.skills.get(skill)
        if entry is None:
            raise SecurityError("Skill is not registered")
        directory = entry["directory"].resolve()
        manifest_path = directory / "skill.json"
        if manifest_path.is_file():
            try:
                document = json.loads(
                    manifest_path.read_text(encoding="utf-8"),
                    parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))
            except (OSError, UnicodeDecodeError, ValueError) as exc:
                raise SecurityError(f"Invalid skill.json: {exc}") from None
            run = document.get("run") if isinstance(document, dict) else None
            if not isinstance(run, dict):
                raise SecurityError("skill.json must declare run")
            entrypoint = run.get("entrypoint")
            actions = run.get("actions")
            if not isinstance(entrypoint, str) or not entrypoint:
                raise SecurityError("skill.json must declare an entrypoint")
            if not isinstance(actions, dict) or not actions:
                raise SecurityError("skill.json must declare actions")
            return directory, entrypoint, actions, run.get("packaged", "source")
        scripts = python_scripts(directory)
        if scripts:
            return directory, f"scripts/{scripts[0].name}", _generic_actions(scripts[0].stem), "source"
        if directory.name in CLI_SKILLS:
            # The packaged controller CLI is the entrypoint; no script ships.
            return directory, "scripts/hardware_controller.py", _generic_actions("hardware_controller"), "cli"
        raise SecurityError("Skill has neither skill.json nor scripts/ directory")

    def _action(self, actions, action):
        spec = actions.get(action)
        if not isinstance(spec, dict):
            raise SecurityError("Unknown Skill action")
        argv = spec.get("argv", [])
        params = spec.get("params", {})
        if not isinstance(argv, list) or any(not isinstance(item, str) for item in argv):
            raise SecurityError("Skill action argv must be a string list")
        if not isinstance(params, dict):
            raise SecurityError("Skill action params must be an object")
        return spec

    def _resolve_path(self, value, roots):
        if isinstance(value, dict):
            path, scope = value.get("path"), value.get("scope")
        else:
            path, scope = value, None
        if path is None:
            return ""
        path = str(path)
        if isinstance(scope, str) and scope in roots and not os.path.isabs(path):
            return str((roots[scope] / path).resolve())
        return path

    def _arguments(self, spec, arguments, roots):
        arguments = arguments if isinstance(arguments, dict) else {}
        values = {}
        for name, param in spec.get("params", {}).items():
            if name in arguments:
                value = arguments[name]
                if isinstance(param, dict) and param.get("type") == "path":
                    values[name] = self._resolve_path(value, roots)
                elif isinstance(param, dict) and param.get("type") == "array":
                    values[name] = ([str(item) for item in value]
                                    if isinstance(value, list) else [str(value)])
                elif isinstance(value, bool):
                    values[name] = "true" if value else "false"
                elif isinstance(value, (dict, list)):
                    values[name] = json.dumps(value, ensure_ascii=False)
                else:
                    values[name] = str(value)
            elif isinstance(param, dict) and "default" in param:
                values[name] = str(param["default"])
        for name, value in arguments.items():
            if name in values:
                continue
            if isinstance(value, bool):
                values[name] = "true" if value else "false"
            elif isinstance(value, (dict, list)):
                values[name] = json.dumps(value, ensure_ascii=False)
            else:
                values[name] = str(value)
        return values

    def _argv(self, spec, values, allow_hardware, bindings):
        if spec.get("passthrough"):
            argv = []
            command = values.pop("command", "")
            if command:
                argv.append(str(command))
            argv.extend(str(item) for item in (values.pop("args", None) or []))
            for name, value in values.items():
                if value.lower() in ("true", "false"):
                    if value.lower() == "true":
                        argv.append(f"--{name}")
                else:
                    argv.extend((f"--{name}", value))
            return argv
        argv = [_PLACEHOLDER.sub(
            lambda match: values.get(match.group(1), match.group(0)), token)
            for token in spec.get("argv", [])]
        if "--robot" in spec.get("argv", []):
            for name, value in bindings.items():
                argv.extend(("--var", f"{name}={value}"))
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
    def _read(stream):
        stream.seek(0)
        return stream.read()

    def run(self, skill, action, arguments=None, *, allow_hardware=False, bindings=None,
            deadline=None, check=lambda: None, started=None):
        """Run one trusted manifest action; the caller still supplies stop checks."""
        directory, entrypoint, actions, packaged = self._manifest(skill)
        spec = self._action(actions, action)
        roots = {**self.roots, "skill": directory,
                 "skill_assets": directory / "assets"}
        values = self._arguments(spec, arguments, roots)
        argv = self._argv(spec, values, allow_hardware, bindings or {})
        candidate = directory / entrypoint
        if candidate.is_file():
            command = [sys.executable, "-I", str(candidate), *argv]
        elif packaged == "cli":
            command = ([sys.executable, *argv] if frozen()
                       else [sys.executable, "-I", "-m", "pymybot", *argv])
        else:
            raise SecurityError("Skill entrypoint does not exist")
        process = None
        stdout, stderr = tempfile.TemporaryFile(), tempfile.TemporaryFile()
        try:
            check()
            process = subprocess.Popen(
                command,
                cwd=str(directory), env=self._environment(), stdin=subprocess.DEVNULL,
                stdout=stdout, stderr=stderr, start_new_session=os.name != "nt")
            if started is not None:
                started()
            while True:
                check()
                try:
                    process.wait(timeout=0.1)
                    break
                except subprocess.TimeoutExpired:
                    continue
            check()
            code = process.returncode
            out = self._read(stdout)
            err = self._read(stderr)
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
            "stdout_truncated": False, "stderr_truncated": False,
        }
