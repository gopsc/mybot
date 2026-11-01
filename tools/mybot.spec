# -*- mode: python ; coding: utf-8 -*-
"""One-directory Windows/Linux bundle built from a tagged public commit.

Build:
    pip install -e ".[agent,camera,package]"
    python -m PyInstaller --noconfirm --clean tools/mybot.spec

The console EXE hides its console when it starts the GUI. The GUI launches
``pymybot.exe serve`` with CREATE_NO_WINDOW (see pymybot/gui/protocol.py).
"""
import sys
from pathlib import Path

ROOT = Path(SPECPATH).resolve().parent
sys.path.insert(0, str(ROOT / "tools"))
from bundle_assets import asset_datas, hidden_imports, metadata_datas

datas = list(asset_datas(ROOT)) + metadata_datas()
hiddenimports = hidden_imports()

a = Analysis(
    [str(ROOT / "tools" / "entry_cli.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["pytest", "tests", "tkinter", "_tkinter"],
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
