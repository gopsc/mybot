"""Persisted GUI configuration.

Only operator preferences are stored: no API key, no variable value, no approval
decision and no hardware permission outlives the process, so a saved file can
never pre-authorize a risky run or leak a credential.
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


def _key_env(value):
    """Only a variable *name* is ever stored, never the secret it holds."""
    text = _text(value, 256)
    return text if text.isidentifier() else ""


def _bindings(value, cap=64):
    if not isinstance(value, dict):
        return {}
    checked = {}
    for name, text in list(value.items())[:cap]:
        if (isinstance(name, str) and name.isidentifier()
                and isinstance(text, str) and len(text) <= MAX_TEXT and "\x00" not in text):
            checked[name] = text
    return checked


@dataclass
class GuiConfig:
    """Everything the window needs; CLI flags override the stored values."""

    workspace: str = ""
    python: str = ""
    robot: str = ""
    role: str = ""
    task: str = ""
    scripts_dir: str = ""
    skills_dir: str = ""
    module_paths: list[str] = field(default_factory=list)
    mcp_config: str = ""
    model: str = ""
    base_url: str = ""
    api_key_env: str = ""
    vars: dict[str, str] = field(default_factory=dict)
    timeout: float = 180.0
    max_history_bytes: int = 4 * 1024 * 1024
    max_context_tokens: int | None = None
    context_reserve_tokens: int = 2048
    hot_turns: int = 3
    warm_turns: int = 10
    prompt_file: str = ""
    max_requests: int = 64
    max_tool_calls: int = 128
    turn_timeout: float = 0.0
    model_retries: int = 0
    fallback_models: list[str] = field(default_factory=list)
    require_plan_approval: bool = False
    auto_stats: bool = True
    context_bytes: int = 4 * 1024
    intent_mode: str = "off"
    sandbox_mode: str = "auto"
    protect_prompts: bool = True
    enable_web: bool = False
    search_endpoint: str = ""
    session_log: bool = True
    # First-run model wizard: shown once, then remembered (even when skipped).
    model_setup_done: bool = False
    # Tool availability is a preference; approval grants stay runtime-only.
    enable_file_tools: bool = False
    enable_shell: bool = False
    # Runtime-only: initial toggle state for this launch, never written to disk.
    allow_hardware: bool = False
    allow_actions: bool = False
    allow_file_writes: bool = False
    allow_web: bool = False
    allow_mcp_tools: bool = False

    def sanitized(self):
        return GuiConfig(
            workspace=_text(self.workspace),
            python=_text(self.python),
            robot=_text(self.robot),
            role=_text(self.role, 64),
            task=_text(self.task, 16 * 1024),
            scripts_dir=_text(self.scripts_dir),
            skills_dir=_text(self.skills_dir),
            module_paths=_paths(self.module_paths),
            mcp_config=_text(self.mcp_config),
            model=_text(self.model, 1024),
            base_url=_text(self.base_url, 2048),
            api_key_env=_key_env(self.api_key_env),
            vars=_bindings(self.vars),
            timeout=self.timeout if isinstance(self.timeout, (int, float)) and 0 < self.timeout <= 3600 else 180.0,
            max_history_bytes=(self.max_history_bytes if isinstance(self.max_history_bytes, int)
                               and 64 * 1024 <= self.max_history_bytes <= 64 * 1024 * 1024
                               else 4 * 1024 * 1024),
            max_context_tokens=(self.max_context_tokens if type(self.max_context_tokens) is int
                                and 1024 <= self.max_context_tokens <= 2 * 1024 * 1024 else None),
            context_reserve_tokens=(self.context_reserve_tokens if type(self.context_reserve_tokens) is int
                                    and 0 <= self.context_reserve_tokens <= 64 * 1024 else 2048),
            hot_turns=self.hot_turns if type(self.hot_turns) is int and 1 <= self.hot_turns <= 50 else 3,
            warm_turns=self.warm_turns if type(self.warm_turns) is int and 0 <= self.warm_turns <= 200 else 10,
            prompt_file=_text(self.prompt_file),
            max_requests=(self.max_requests if type(self.max_requests) is int
                          and 1 <= self.max_requests <= 10_000 else 64),
            max_tool_calls=(self.max_tool_calls if type(self.max_tool_calls) is int
                            and 1 <= self.max_tool_calls <= 100_000 else 128),
            turn_timeout=(float(self.turn_timeout) if isinstance(self.turn_timeout, (int, float))
                          and not isinstance(self.turn_timeout, bool)
                          and 0 <= self.turn_timeout <= 86400 else 0.0),
            model_retries=(self.model_retries if type(self.model_retries) is int
                           and 0 <= self.model_retries <= 10 else 0),
            fallback_models=_paths(self.fallback_models),
            require_plan_approval=bool(self.require_plan_approval),
            auto_stats=self.auto_stats if isinstance(self.auto_stats, bool) else True,
            context_bytes=(self.context_bytes if isinstance(self.context_bytes, int)
                           and 0 <= self.context_bytes <= 64 * 1024 else 4 * 1024),
            intent_mode=(self.intent_mode if self.intent_mode in
                         {"auto", "off", "chat", "inspect", "control", "author", "diagnose"}
                         else "auto"),
            sandbox_mode=(self.sandbox_mode if self.sandbox_mode in {"auto", "off", "bwrap"}
                          else "auto"),
            protect_prompts=self.protect_prompts if isinstance(self.protect_prompts, bool) else True,
            enable_web=bool(self.enable_web),
            search_endpoint=_text(self.search_endpoint, 2048),
            allow_web=bool(self.allow_web and self.enable_web),
            session_log=self.session_log if isinstance(self.session_log, bool) else True,
            model_setup_done=bool(self.model_setup_done),
            enable_file_tools=bool(self.enable_file_tools or self.enable_shell),
            enable_shell=bool(self.enable_shell),
            allow_hardware=bool(self.allow_hardware),
            allow_actions=bool(self.allow_actions),
            allow_file_writes=bool(self.allow_file_writes and (self.enable_file_tools or self.enable_shell)),
            allow_mcp_tools=bool(self.allow_mcp_tools and (self.mcp_config or self.role)),
        )

    def store(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        data = asdict(self.sanitized())
        # A one-shot prompt hint, per-launch approvals and variable values are not
        # preferences; variable values may hold credentials, so they never reach disk.
        for key in ("task", "allow_hardware", "allow_actions", "allow_file_writes",
                    "allow_mcp_tools", "allow_web", "vars"):
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
        "role": getattr(args, "role", None),
        "task": getattr(args, "task", None),
        "scripts_dir": getattr(args, "scripts_dir", None),
        "skills_dir": getattr(args, "skills_dir", None),
        "mcp_config": getattr(args, "mcp_config", None),
        "model": getattr(args, "model", None),
        "base_url": getattr(args, "base_url", None),
        "api_key_env": getattr(args, "api_key_env", None),
        "timeout": getattr(args, "timeout", None),
        "prompt_file": getattr(args, "prompt_file", None),
        "context_bytes": getattr(args, "context_bytes", None),
        "intent_mode": getattr(args, "intent", None),
        "sandbox_mode": getattr(args, "sandbox", None),
        "enable_web": getattr(args, "web", None) or None,
        "allow_web": getattr(args, "allow_web", None) or None,
        "search_endpoint": getattr(args, "search_endpoint", None),
        "allow_hardware": getattr(args, "allow_hardware", None) or None,
        "allow_actions": getattr(args, "allow_actions", None) or None,
    }
    for name, value in overrides.items():
        if value not in (None, "", []):
            setattr(cfg, name, value)
    if getattr(args, "module_path", None):
        cfg.module_paths = list(args.module_path)
    if getattr(args, "no_prompt_stats", False):
        cfg.auto_stats = False
    if not cfg.workspace:
        cfg.workspace = default_workspace()
    return cfg.sanitized()
