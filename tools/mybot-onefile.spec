# -*- mode: python ; coding: utf-8 -*-
"""Single-file Windows bundle; temporary variant of mybot.spec for onefile builds."""
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
    excludes=["pytest", "tests", "implementations", "tkinter", "_tkinter"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
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
