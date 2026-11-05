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
# A manifest-free skill is a CLI passthrough. Keep the model on the documented
# hardware-controller surface; administrative mutators (assets write/delete,
# roles, prompts, sessions, new, gui, serve, mcp, agent) are not reachable.
# discover joins doctor as a read-only host enumeration surface.
_GENERIC_COMMANDS = frozenset({"assets", "discover", "doctor", "hardware", "scripts",
                               "query", "check", "run", "sample"})
_ASSET_READ_COMMANDS = frozenset({"list", "read"})
_HARDWARE_COMMANDS = frozenset({"run", "sample"})
_VAR_COMMANDS = frozenset({"hardware", "query", "check", "run", "sample"})
_ROBOT_COMMANDS = _VAR_COMMANDS
_PATH_KINDS = {"--robot": ("robots", "assets/robots/"),
               "--input": ("scripts", "assets/scripts/")}


def python_scripts(directory):
    """Return the top-level runnable Python scripts of one skill directory."""
    scripts_dir = Path(directory) / "scripts"
    if not scripts_dir.is_dir() or scripts_dir.is_symlink():
        return []
    return sorted(path for path in scripts_dir.iterdir()
                  if path.suffix == ".py" and path.is_file() and not path.is_symlink())


def _generic_actions(stem, *, restricted=False):
    """One manifest-free action that forwards a documented CLI invocation."""
    return {"run": {
        "description": f"Run {stem} with a documented hardware-controller subcommand",
        "effect": "read",
        "output": "json",
        "params": {
            "command": {
                "type": "string",
                "description": ("One of: " + ", ".join(sorted(_GENERIC_COMMANDS)))
                if restricted else "Optional CLI subcommand",
            },
            "args": {
                "type": "array",
                "description": "Additional CLI arguments, one list item per token",
            },
        },
        "passthrough": True,
        "_restricted": restricted,
    }}


class SkillRunner:
    """Resolve one trusted Skill entrypoint and run it in a bounded subprocess."""

    def __init__(self, skills, *, roots=None, module_paths=None):
        if not isinstance(skills, SkillsLibrary):
            raise SecurityError("Skills are not configured")
        self.skills = skills
        self.roots = {name: Path(path).absolute() for name, path in (roots or {}).items()}
        self.module_paths = tuple(Path(path).absolute() for path in (module_paths or ()) if str(path).strip())

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
        restricted = directory.name in CLI_SKILLS
        if scripts:
            return (directory, f"scripts/{scripts[0].name}",
                    _generic_actions(scripts[0].stem, restricted=restricted), "source")
        if directory.name in CLI_SKILLS:
            # The packaged controller CLI is the entrypoint; no script ships.
            return (directory, "scripts/hardware_controller.py",
                    _generic_actions("hardware_controller", restricted=True), "cli")
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

    def _resolve_generic_path(self, flag, value):
        """Resolve documented asset aliases and workspace-relative CLI paths."""
        value = str(value)
        if not value or value == "-" or os.path.isabs(value):
            return value
        if flag in _PATH_KINDS:
            kind, prefix = _PATH_KINDS[flag]
            if value.startswith(prefix):
                # SKILL.md documents assets/robots/x.sql and assets/scripts/x.mt;
                # the packaged CLI resolves those bare names against its asset root.
                value = value[len(prefix):]
            rel = Path(value)
            candidates = [rel]
            if len(rel.parts) > 1 and rel.parts[0] == kind:
                candidates.append(Path(rel.name))
            roots = [self.roots.get(kind), self.roots.get("skill_assets"),
                     self.roots.get("workspace")]
            workspace_kind = self.roots.get("workspace")
            if workspace_kind is not None:
                roots.append(workspace_kind / kind)
            for root in roots:
                if root is None:
                    continue
                for candidate in candidates:
                    path = root / candidate
                    if path.is_file():
                        return str(path.resolve())
            return value
        if flag in {"--scripts-dir", "--module-path"}:
            roots = [self.roots.get("scripts"), self.roots.get("workspace"),
                     self.roots.get("skill_assets")]
            if flag == "--scripts-dir" and value.startswith("assets/scripts/"):
                value = value[len("assets/scripts/"):]
            if flag == "--scripts-dir" and value in {"", ".", "scripts"}:
                root = self.roots.get("scripts") or self.roots.get("workspace")
                if root is not None and root.is_dir():
                    return str(root.resolve())
                return value
            for root in roots:
                if root is not None and (root / value).is_dir():
                    return str((root / value).resolve())
        return value

    def _rewrite_generic_paths(self, argv):
        """Keep relative host paths useful without trusting model absolute paths."""
        out, index = [], 0
        while index < len(argv):
            token = argv[index]
            flag, separator, inline = token.partition("=")
            if flag in _PATH_KINDS or flag in {"--scripts-dir", "--module-path"}:
                if separator:
                    out.append(flag + "=" + self._resolve_generic_path(flag, inline))
                    index += 1
                    continue
                if index + 1 < len(argv):
                    out.extend((flag, self._resolve_generic_path(flag, argv[index + 1])))
                    index += 2
                    continue
            out.append(token)
            index += 1
        return out

    @staticmethod
    def _existing_var_names(argv):
        names = set()
        for index, token in enumerate(argv):
            if token == "--var" and index + 1 < len(argv):
                names.add(argv[index + 1].split("=", 1)[0])
            elif token.startswith("--var="):
                names.add(token[6:].split("=", 1)[0])
        return names

    def _argv(self, spec, values, allow_hardware, bindings):
        if spec.get("passthrough"):
            argv = []
            restricted = bool(spec.get("_restricted"))
            command = str(values.pop("command", "")).strip()
            if restricted:
                if not command:
                    raise SecurityError("Skill CLI command is required")
                if command not in _GENERIC_COMMANDS:
                    raise SecurityError(
                        "Skill subcommand is not allowed: " + command[:80]
                        + "; allowed: " + ", ".join(sorted(_GENERIC_COMMANDS)))
            if command:
                argv.append(command)
            raw_args = [str(item) for item in (values.pop("args", None) or [])]
            if command == "assets" and (not raw_args or raw_args[0] not in _ASSET_READ_COMMANDS):
                raise SecurityError("Only read-only 'assets list' and 'assets read' are allowed")
            argv.extend(raw_args)
            for name, value in values.items():
                if value.lower() in ("true", "false"):
                    if value.lower() == "true":
                        argv.append(f"--{name}")
                else:
                    argv.extend((f"--{name}", value))
            argv = self._rewrite_generic_paths(argv)
            if allow_hardware and command in _HARDWARE_COMMANDS:
                argv.append(_HARDWARE_FLAG)
            if command in _VAR_COMMANDS:
                existing = self._existing_var_names(argv)
                for name, value in (bindings or {}).items():
                    if name not in existing:
                        argv.extend(("--var", f"{name}={value}"))
            for path in (self.module_paths if command in _ROBOT_COMMANDS else ()):
                argv.extend(("--module-path", str(path)))
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
