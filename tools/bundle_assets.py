"""Shared PyInstaller data plan for onedir and onefile specs.

Keep this module free of PyInstaller imports at import time so the plan can be
tested without the packaging extra installed.
"""
from pathlib import Path

ASSET_SUFFIXES = {
    "modules": (".lua", ".py"),
    "robots": (".sql",),
    "scripts": (".mt",),
    "skills": (".md",),
    "prompts": (".md", ".json"),
}

METADATA_DISTRIBUTIONS = (
    "pydantic-ai-slim", "pydantic-graph", "pydantic", "openai", "anthropic",
    "genai-prices", "httpx2", "httpcore2", "griffelib", "truststore", "jiter",
    "tiktoken", "lupa", "sqlparse", "pyserial", "pyftdi", "pillow", "av", "PySide6",
    "mcp", "httpx", "beautifulsoup4",
)

HIDDEN_PACKAGES = (
    "pydantic_ai", "pydantic_graph", "openai", "anthropic", "genai_prices",
    "httpx2", "httpcore2", "griffelib", "truststore", "jiter", "tiktoken",
    "lupa", "PIL", "serial", "pyftdi", "av", "mcp", "httpx", "bs4",
)


def asset_datas(root):
    """Return ``(source, destination)`` pairs for bundled runtime assets."""
    root = Path(root)
    datas = []
    for name, suffixes in ASSET_SUFFIXES.items():
        for source in sorted((root / name).rglob("*")):
            if source.is_file() and source.suffix in suffixes:
                relative = source.relative_to(root)
                datas.append((str(source), str(Path("pymybot/assets") / relative.parent)))
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
    imports = ["PySide6.QtCore", "PySide6.QtGui", "PySide6.QtWidgets", "PySide6.QtSvg"]
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
