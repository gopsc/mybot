"""Self-contained Agent roles under ``~/.mybot/roles``.

A role owns its prompt library, skills, optional MCP configuration and complete
conversation history. Creation copies the trusted bundled prompt baseline;
loading a role never changes the global prompt library or grants permissions.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat

from .agent_skills import SkillsLibrary
from .mcp_client import MAX_CONFIG_BYTES, parse_servers
from .prompts import PromptLibrary
from .security import SecurityError, checked_text, read_file

FORMAT = 1
MAX_ROLE_NAME = 64
MAX_DESCRIPTION = 1024
MAX_METADATA = 64 * 1024
MAX_HISTORY = 64 * 1024 * 1024 + 1024 * 1024
_NAME = re.compile(r"[\w][\w.-]{0,63}\Z", re.UNICODE)


def roles_root(root=None):
    if root is not None:
        return Path(root).expanduser().absolute()
    base = os.environ.get("MYBOT_HOME", "").strip()
    home = Path(base).expanduser() if base else Path.home() / ".mybot"
    return home / "roles"


def validate_role_name(name):
    if not isinstance(name, str) or name != name.strip() or not _NAME.fullmatch(name):
        raise SecurityError(
            f"Role name must be 1..{MAX_ROLE_NAME} letters, numbers, '_', '-' or '.', without spaces")
    if name in {".", ".."} or name.startswith("."):
        raise SecurityError("Role name must not start with '.'")
    if os.name == "nt" and name.rstrip(".") != name:
        raise SecurityError("Role name must not end with '.' on Windows")
    return name


def _private(path, mode):
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _no_links(path, root):
    try:
        for part in (path, *path.parents):
            info = part.lstat()
            if part == root.parent:
                break
            if (stat.S_ISLNK(info.st_mode)
                    or getattr(info, "st_file_attributes", 0) & 0x400
                    or getattr(part, "is_junction", lambda: False)()):
                raise SecurityError("Role paths must not contain links or junctions")
            if part != root.parent and not stat.S_ISDIR(info.st_mode):
                raise SecurityError("Role root must be a directory")
    except FileNotFoundError:
        raise SecurityError("Role does not exist") from None


def _regular_file(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if (stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400
            or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
        raise SecurityError("Role files must be non-linked regular files")
    return True


def _metadata(path, expected=None):
    _regular_file(path / "role.json")
    try:
        document = json.loads(read_file(path / "role.json", MAX_METADATA))
    except (OSError, ValueError) as exc:
        raise SecurityError(f"Invalid role metadata: {type(exc).__name__}") from None
    if (type(document) is not dict or set(document) != {"version", "name", "description"}
            or type(document["version"]) is not int or document["version"] != FORMAT
            or type(document["description"]) is not str):
        raise SecurityError("Invalid or unsupported role metadata")
    validate_role_name(document["name"])
    checked_text(document["description"], MAX_DESCRIPTION)
    if expected is not None and document["name"] != expected:
        raise SecurityError("Role directory and metadata names differ")
    return document


def _write_json(path, document):
    """Atomically publish bounded UTF-8 JSON beside the destination."""
    data = (json.dumps(document, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8")
    if len(data) > MAX_HISTORY:
        raise SecurityError("Role JSON exceeds its size limit")
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}.tmp"
    descriptor = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _private(path, 0o600)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_history(path):
    """Return raw serialized turns; PydanticAI validation belongs to AgentSession."""
    path = Path(path)
    if not path.exists():
        return []
    _regular_file(path)
    try:
        document = json.loads(read_file(path, MAX_HISTORY))
    except (OSError, ValueError) as exc:
        raise SecurityError(f"Cannot load role history: {type(exc).__name__}") from None
    if (type(document) is not dict or set(document) != {"version", "turns"}
            or type(document["version"]) is not int or document["version"] != FORMAT
            or type(document["turns"]) is not list):
        raise SecurityError("Invalid or unsupported role history")
    return document["turns"]


def write_history(path, turns):
    if not isinstance(turns, list):
        raise SecurityError("Role history turns must be a list")
    _write_json(Path(path), {"version": FORMAT, "turns": turns})


@dataclass(frozen=True)
class Role:
    name: str
    description: str
    root: Path

    @property
    def prompts_dir(self):
        return self.root / "prompts"

    @property
    def skills_dir(self):
        return self.root / "skills"

    @property
    def mcp_config(self):
        return self.root / "mcp.json"

    @property
    def history_file(self):
        return self.root / "history.json"

    def prompt_library(self):
        return PromptLibrary(home=self.prompts_dir)

    def info(self):
        skills = SkillsLibrary(self.skills_dir, required=True).index()["skills"]
        history = read_history(self.history_file)
        return {
            "name": self.name,
            "description": self.description,
            "root": str(self.root),
            "prompts_dir": str(self.prompts_dir),
            "skills_dir": str(self.skills_dir),
            "skills": [item["name"] for item in skills],
            "mcp_config": str(self.mcp_config) if self.mcp_config.is_file() else None,
            "history_file": str(self.history_file),
            "history_turns": len(history),
            "history_bytes": self.history_file.stat().st_size if self.history_file.is_file() else 0,
        }


def role_path(name, root=None):
    return roles_root(root) / validate_role_name(name)


def load_role(name, root=None):
    path = role_path(name, root)
    base = path.parent
    _no_links(path, base)
    document = _metadata(path, expected=name)
    role = Role(name=name, description=document["description"], root=path)
    if not role.prompts_dir.is_dir() or not role.skills_dir.is_dir():
        raise SecurityError("Role prompts and skills directories are required")
    _regular_file(role.mcp_config)
    _regular_file(role.history_file)
    return role


def list_roles(root=None):
    base = roles_root(root)
    if not base.is_dir():
        return []
    result = []
    for child in sorted(base.iterdir(), key=lambda item: item.name.casefold()):
        if child.is_symlink() or not child.is_dir():
            continue
        try:
            validate_role_name(child.name)
            result.append(load_role(child.name, base).info())
        except (OSError, SecurityError):
            # A malformed directory must not hide other usable roles. `show`
            # remains available to report the validation error for that role.
            continue
    return result


def _copy_skills(source, destination):
    library = SkillsLibrary(Path(source).expanduser(), required=True)
    for name, entry in library.skills.items():
        for relative in entry["files"]:
            source_file = entry["directory"].joinpath(*relative.split("/"))
            target = destination / name / Path(*relative.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(read_file(source_file), encoding="utf-8")
            _private(target, 0o600)


def create_role(name, *, description="", skills_from=None, mcp_from=None, root=None):
    validate_role_name(name)
    checked_text(description, MAX_DESCRIPTION)
    base = roles_root(root)
    base.mkdir(parents=True, exist_ok=True)
    _private(base, 0o700)
    target = base / name
    if target.exists():
        raise SecurityError(f"Role '{name}' already exists")
    staging = base / f".{name}.{secrets.token_hex(8)}.tmp"
    staging.mkdir(mode=0o700)
    try:
        # PromptLibrary copies and validates every bundled baseline layer.
        PromptLibrary(home=staging / "prompts").ensure_home()
        skills = staging / "skills"
        skills.mkdir(mode=0o700)
        if skills_from:
            _copy_skills(skills_from, skills)
        if mcp_from:
            source = Path(mcp_from).expanduser().absolute()
            text = read_file(source, MAX_CONFIG_BYTES)
            parse_servers(text, source.parent)
            (staging / "mcp.json").write_text(text, encoding="utf-8")
            _private(staging / "mcp.json", 0o600)
        _write_json(staging / "role.json", {
            "version": FORMAT, "name": name, "description": description,
        })
        write_history(staging / "history.json", [])
        os.replace(staging, target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return load_role(name, base)


def clear_role_history(name, root=None):
    role = load_role(name, root)
    write_history(role.history_file, [])
    return role.info()
