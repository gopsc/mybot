# -*- mode: python ; coding: utf-8 -*-
"""One-directory Windows/Linux bundle built from a tagged public commit.

Build:
    pip install -e ".[agent,camera,package]"
    python -m PyInstaller --noconfirm --clean tools/mybot.spec

The console EXE hides its console when it starts the GUI. The GUI launches
``pymybot.exe serve`` with CREATE_NO_WINDOW (see pymybot/gui/protocol.py).
"""
from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules, copy_metadata

ROOT = Path(SPECPATH).resolve().parent
ASSET_SUFFIXES = {"modules": ".lua", "robots": ".sql", "scripts": ".mt", "skills": ".md"}

datas = []
for name, suffix in ASSET_SUFFIXES.items():
    for source in sorted((ROOT / name).rglob("*" + suffix)):
        relative = source.relative_to(ROOT)
        datas.append((str(source), str(Path("pymybot/assets") / relative.parent)))

for source in sorted((ROOT / "pymybot" / "gui" / "assets").glob("*.svg")):
    datas.append((str(source), "pymybot/gui/assets"))

for extra in ("README.md", "LICENSE", "CHANGELOG.md"):
    candidate = ROOT / extra
    if candidate.is_file():
        datas.append((str(candidate), "."))

for distribution in (
    "pydantic-ai-slim", "pydantic-graph", "pydantic", "openai", "anthropic",
    "genai-prices", "httpx2", "httpcore2", "griffelib", "truststore", "jiter",
    "tiktoken", "lupa", "sqlparse", "pyserial", "pyftdi", "pillow", "av", "PySide6",
    "mcp",
):
    try:
        datas += copy_metadata(distribution)
    except Exception:
        pass

hiddenimports = ["PySide6.QtCore", "PySide6.QtGui", "PySide6.QtWidgets", "PySide6.QtSvg"]
for package in (
    "pydantic_ai", "pydantic_graph", "openai", "anthropic", "genai_prices",
    "httpx2", "httpcore2", "griffelib", "truststore", "jiter", "tiktoken",
    "lupa", "PIL", "serial", "pyftdi", "av", "mcp",
):
    try:
        hiddenimports += collect_submodules(package)
    except Exception:
        pass

a = Analysis(
    [str(ROOT / "tools" / "entry_cli.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["pytest", "tests", "implementations", "tkinter", "_tkinter"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="pymybot",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(ROOT / "tools" / "icon.ico"),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="mybot",
)

# PyInstaller 6 places data under _internal/. Keep the operator-facing examples
# next to the executable so double-click and README commands work unchanged.
import shutil

bundle = Path(DISTPATH) / "mybot"
for name in ("robots", "scripts"):
    shutil.copytree(ROOT / name, bundle / name, dirs_exist_ok=True)
for extra in ("README.md", "LICENSE"):
    if (ROOT / extra).is_file():
        shutil.copy2(ROOT / extra, bundle / extra)
