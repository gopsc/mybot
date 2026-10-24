"""Persisted GUI configuration.

Only operator preferences are stored: no API key, no approval decision and no
hardware permission outlives the process, so a saved file can never pre-authorize
a risky run.
"""
from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

APP_DIR = "pymybot-gui"
MAX_TEXT = 4096


def config_home():
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~\\AppData\\Roaming")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(base) / APP_DIR


def _text(value, cap=MAX_TEXT):
    return value if isinstance(value, str) and len(value) <= cap and "\x00" not in value else ""


def _paths(value, cap=32):
    if not isinstance(value, list):
        return []
    return [item for item in (_text(entry) for entry in value) if item][:cap]


def _names(value, cap=64):
    checked = []
    for item in _paths(value, cap):
        if item.isidentifier() and item not in checked:
            checked.append(item)
    return checked


def _key_env(value):
    """Only a variable *name* is ever stored, never the secret it holds."""
    text = _text(value, 256)
    return text if text.isidentifier() else ""


@dataclass
class GuiConfig:
    """Everything the window needs; CLI flags override the stored values."""

    workspace: str = ""
    python: str = ""
    robot: str = ""
    task: str = ""
    scripts_dir: str = ""
    skills_dir: str = ""
    module_paths: list[str] = field(default_factory=list)
    camera_src_dir: str = ""
    model: str = ""
    base_url: str = ""
    api_key_env: str = ""
    read_vars: list[str] = field(default_factory=list)
    camera_vars: list[str] = field(default_factory=list)
    timeout: float = 180.0
    max_requests: int = 8
    max_tool_calls: int = 16
    # Runtime-only: initial toggle state for this launch, never written to disk.
    allow_hardware: bool = False
    allow_actions: bool = False

    def sanitized(self):
        return GuiConfig(
            workspace=_text(self.workspace),
            python=_text(self.python),
            robot=_text(self.robot),
            task=_text(self.task, 16 * 1024),
            scripts_dir=_text(self.scripts_dir),
            skills_dir=_text(self.skills_dir),
            module_paths=_paths(self.module_paths),
            camera_src_dir=_text(self.camera_src_dir),
            model=_text(self.model, 1024),
            base_url=_text(self.base_url, 2048),
            api_key_env=_key_env(self.api_key_env),
            read_vars=_names(self.read_vars),
            camera_vars=_names(self.camera_vars),
            timeout=self.timeout if isinstance(self.timeout, (int, float)) and 0 < self.timeout <= 3600 else 180.0,
            max_requests=self.max_requests if isinstance(self.max_requests, int) and 1 <= self.max_requests <= 100 else 8,
            max_tool_calls=self.max_tool_calls if isinstance(self.max_tool_calls, int) and 1 <= self.max_tool_calls <= 1000 else 16,
            allow_hardware=bool(self.allow_hardware),
            allow_actions=bool(self.allow_actions),
        )

    def store(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        data = asdict(self.sanitized())
        # A one-shot prompt hint and per-launch approvals are not preferences.
        for key in ("task", "allow_hardware", "allow_actions"):
            data.pop(key, None)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    @classmethod
    def load(cls, path):
        try:
            raw = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()
        if not isinstance(raw, dict):
            return cls()
        known = {field.name for field in cls.__dataclass_fields__.values()}
        values = {key: value for key, value in raw.items() if key in known}
        try:
            return cls(**values).sanitized()
        except TypeError:
            return cls()


def default_workspace():
    """The GUI starts in the directory it was launched from."""
    try:
        return str(Path.cwd())
    except OSError:
        return str(Path.home())


def merge_args(cfg, args):
    """Apply explicit CLI flags on top of the stored configuration."""
    overrides = {
        "workspace": getattr(args, "workspace_dir", None),
        "robot": getattr(args, "robot", None),
        "task": getattr(args, "task", None),
        "scripts_dir": getattr(args, "scripts_dir", None),
        "skills_dir": getattr(args, "skills_dir", None),
        "camera_src_dir": getattr(args, "camera_src_dir", None),
        "model": getattr(args, "model", None),
        "base_url": getattr(args, "base_url", None),
        "api_key_env": getattr(args, "api_key_env", None),
        "timeout": getattr(args, "timeout", None),
        "max_requests": getattr(args, "max_requests", None),
        "max_tool_calls": getattr(args, "max_tool_calls", None),
        "allow_hardware": getattr(args, "allow_hardware", None) or None,
        "allow_actions": getattr(args, "allow_actions", None) or None,
    }
    for name, value in overrides.items():
        if value not in (None, "", []):
            setattr(cfg, name, value)
    if getattr(args, "module_path", None):
        cfg.module_paths = list(args.module_path)
    if getattr(args, "read_var", None):
        cfg.read_vars = _names(args.read_var)
    if getattr(args, "camera_var", None):
        cfg.camera_vars = _names(args.camera_var)
    if not cfg.workspace:
        cfg.workspace = default_workspace()
    return cfg.sanitized()
