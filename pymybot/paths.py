"""Locate bundled assets in a source checkout, wheel or frozen build.

Nothing else in the package may assume that the current working directory is the
repository root. PyInstaller puts data under ``sys._MEIPASS`` and Nuitka next to
the executable; wheels place it under ``pymybot/assets``; editable checkouts read
the top-level source dirs.
"""
from __future__ import annotations

import sys
from pathlib import Path

__all__ = ["asset_dir", "asset_path", "frozen", "package_dir", "source_root"]


def frozen() -> bool:
    """True inside a PyInstaller or Nuitka build."""
    # Nuitka deliberately leaves sys.frozen unset and injects __compiled__ instead.
    return bool(getattr(sys, "frozen", False)) or "__compiled__" in globals()


def package_dir() -> Path:
    """Directory containing the installed ``pymybot`` package."""
    return Path(__file__).resolve().parent


def source_root() -> Path:
    """Repository root for a source checkout (the package's parent)."""
    return package_dir().parent


def asset_dir() -> Path:
    """Best existing bundle directory, or the expected frozen/wheel location."""
    package = package_dir()
    if frozen():
        base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
        candidates = [
            base / "pymybot" / "assets",
            base / "assets",
            Path(sys.executable).parent / "pymybot" / "assets",
        ]
    else:
        candidates = [package / "assets"]
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return candidates[0]


def asset_path(name: str) -> Path:
    """Return ``assets/<name>`` if packaged, else the source-tree directory.

    A frozen build must not silently fall back to a developer checkout; a
    missing asset is reported as a missing path instead.
    """
    packaged = asset_dir() / name
    if frozen() or packaged.exists():
        return packaged
    return source_root() / name
