"""Python robot controller with Lua drivers."""
from pathlib import Path

__version__ = "0.6.0"

_here = Path(__file__).resolve().parent
for _parent in (_here.parents if "__path__" in globals() else ()):
    _candidate = _parent / "pymybot"
    if (_candidate.is_dir() and (_candidate / "__init__.py").is_file()
            and _candidate.resolve() != _here):
        _path = str(_candidate)
        if _path not in __path__:
            __path__.append(_path)
        break
