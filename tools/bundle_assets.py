"""Shared PyInstaller data plan for onedir and onefile specs.

Keep this module free of PyInstaller imports at import time so the plan can be
tested without the packaging extra installed.
"""
import json
from pathlib import Path

ASSET_SUFFIXES = {
    "modules": (".lua", ".py"),
    "robots": (".sql",),
    "scripts": (".mt",),
    "skills": (".md", ".json"),
    "prompts": (".md", ".json"),
}

METADATA_DISTRIBUTIONS = (
    "langchain", "langchain-core", "langchain-openai", "langchain-anthropic",
    "langgraph", "langgraph-checkpoint", "langgraph-prebuilt", "langgraph-sdk",
    "langsmith", "pydantic", "openai", "anthropic",
    "httpx2", "httpcore2", "griffelib", "truststore", "jiter",
    "tiktoken", "lupa", "sqlparse", "pyserial", "pyftdi", "pillow", "av", "PySide6",
    "mcp", "httpx", "beautifulsoup4",
)

HIDDEN_PACKAGES = (
    "langchain", "langgraph", "langchain_openai", "langchain_anthropic", "langsmith",
    "openai", "anthropic", "httpx2", "httpcore2", "griffelib", "truststore",
    "jiter", "tiktoken", "lupa", "sqlparse", "PIL", "serial", "pyftdi", "av", "mcp", "httpx", "bs4",
)
CONTROLLER_MODULES = (
    "pymybot.actions", "pymybot.agent_executor", "pymybot.agent_skill_runner",
    "pymybot.agent_skills", "pymybot.camera", "pymybot.images",
    "pymybot.agent_workspace", "pymybot.cli", "pymybot.daemon", "pymybot.errors",
    "pymybot.expr", "pymybot.hal", "pymybot.hardware", "pymybot.include",
    "pymybot.matrix", "pymybot.mcp_server", "pymybot.native", "pymybot.paths",
    "pymybot.process", "pymybot.robot", "pymybot.runtime", "pymybot.sandbox",
    "pymybot.scaffold", "pymybot.security", "pymybot.serve", "pymybot.sql",
)


def skill_script_files(root):
    """Skill entrypoints ship unless the controller Runtime is already packaged."""
    skills_dir = Path(root) / "skills"
    for skill_dir in sorted(skills_dir.iterdir()):
        if not skill_dir.is_dir():
            continue
        manifest = skill_dir / "skill.json"
        if manifest.is_file():
            try:
                document = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            run = document.get("run") if isinstance(document, dict) else None
            if isinstance(run, dict) and run.get("packaged") == "cli":
                continue
        elif (skill_dir / "scripts" / "pymybot").is_dir():
            continue
        scripts_dir = skill_dir / "scripts"
        if scripts_dir.is_dir():
            for source in sorted(scripts_dir.rglob("*.py")):
                if "__pycache__" not in source.parts:
                    yield source


def asset_datas(root):
    """Return ``(source, destination)`` pairs for bundled runtime assets."""
    root = Path(root)
    datas = []
    for name, suffixes in ASSET_SUFFIXES.items():
        source_root = (root / "skills" / "hardware-controller" / "assets"
                       if name in {"modules", "robots", "scripts"} else root)
        for source in sorted((source_root / name).rglob("*")):
            if source.is_file() and source.suffix in suffixes:
                relative = source.relative_to(source_root)
                datas.append((str(source), str(Path("pymybot/assets") / relative.parent)))
    for source in skill_script_files(root):
        relative = source.relative_to(root / "skills")
        datas.append((str(source), str(Path("pymybot/assets/skills") / relative.parent)))
    # SKILL.md points at scripts/requirements.txt; keep it beside the skill assets.
    for source in sorted((root / "skills").rglob("requirements.txt")):
        relative = source.relative_to(root / "skills")
        datas.append((str(source), str(Path("pymybot/assets/skills") / relative.parent)))
    for source in sorted((root / "pymybot" / "gui" / "assets").glob("*.svg")):
        datas.append((str(source), "pymybot/gui/assets"))
    for extra in ("README.md", "LICENSE", "CHANGELOG.md"):
        candidate = root / extra
        if candidate.is_file():
            datas.append((str(candidate), "."))
    return datas


def metadata_datas():
    """Collect distribution metadata, ignoring packages absent from the build."""
    from PyInstaller.utils.hooks import copy_metadata
    datas = []
    for distribution in METADATA_DISTRIBUTIONS:
        try:
            datas += copy_metadata(distribution)
        except Exception:
            pass
    return datas


def hidden_imports():
    """Collect submodules for optional packages available in the build."""
    from PyInstaller.utils.hooks import collect_submodules
    imports = ["PySide6.QtCore", "PySide6.QtGui", "PySide6.QtWidgets", "PySide6.QtSvg",
               "sqlparse", *CONTROLLER_MODULES]
    for package in HIDDEN_PACKAGES:
        options = {}
        if package == "mcp":
            # mcp.cli calls sys.exit(1) when the optional typer CLI dependency
            # is absent. It is not part of the stdio server and must not abort
            # or silently empty the whole MCP collection.
            options["filter"] = lambda name: name != "mcp.cli" and not name.startswith("mcp.cli.")
        try:
            imports += collect_submodules(package, **options)
        except (Exception, SystemExit):
            # Optional packages may still call sys.exit() from another import.
            pass
    return imports
