"""Python robot controller with Lua drivers."""
from pathlib import Path

__version__ = "0.5.1"

_runtime = Path(__file__).resolve().parent.parent / "skills" / "hardware-controller" / "scripts" / "pymybot"
if _runtime.is_dir():
    # Keep pymybot.* imports working while the Skill owns the controller sources.
    __path__.append(str(_runtime))
