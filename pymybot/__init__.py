"""Python robot controller with Lua drivers."""
import sys
from pathlib import Path

__version__ = "0.6.0"

_root = Path(__file__).resolve().parent
if getattr(sys, "frozen", False) or "__compiled__" in globals():
    # Frozen builds ship the controller sources beside this package.
    if (_root / "cli.py").is_file():
        __path__.append(str(_root))
else:
    _runtime = _root.parent / "skills" / "hardware-controller" / "scripts" / "pymybot"
    if _runtime.is_dir():
        # Keep pymybot.* imports working while the Skill owns the controller sources.
        __path__.append(str(_runtime))
