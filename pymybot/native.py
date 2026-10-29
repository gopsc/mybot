from __future__ import annotations

import builtins
import math
from pathlib import Path
import re
import sys
from types import ModuleType
from uuid import uuid4

from .errors import BudgetExceeded, DriverError, ScriptError
from .hardware import Budget
from .runtime import DriverRuntime


def compile_driver(path):
    with Path(path).open("rb") as stream:
        source = stream.read(8 * 1024 * 1024 + 1)
    if len(source) > 8 * 1024 * 1024:
        raise ScriptError("Python driver source exceeds 8 MiB")
    try:
        return compile(source.decode("utf-8"), str(path), "exec", dont_inherit=True)
    except (SyntaxError, ValueError, UnicodeError) as exc:
        raise ScriptError(f"Invalid Python driver {path}: {exc}") from exc


class DriverContext:
    def __init__(self, runtime):
        self._runtime = runtime

    def call(self, operation, *args):
        if self._runtime._closed:
            raise DriverError("Python driver context is closed")
        return self._runtime._hal_values(operation, *args)

    def check(self):
        self._runtime._check()


def _primitive(value, depth=0):
    if depth > 9:
        raise DriverError("Python driver value exceeds maximum nesting depth")
    kind = type(value)
    if value is None or kind in (str, bool, int):
        return value
    if kind is float and math.isfinite(value):
        return value
    if kind is dict:
        if any(type(key) is not str for key in value):
            raise DriverError("Python driver keys must be strings")
        return {key: _primitive(item, depth + 1) for key, item in value.items()}
    if kind in (list, tuple):
        return [_primitive(item, depth + 1) for item in value]
    raise DriverError(f"Unsupported Python driver value: {kind.__name__}")


class PythonState(DriverRuntime):
    def __init__(self, module_paths, hal, stop_event, *, allow_hardware=False):
        super().__init__(module_paths, hal, stop_event, allow_hardware=allow_hardware)
        self.module = None
        self.driver = None
        self._virtual = None
        self.context = DriverContext(self)

    @staticmethod
    def _print(*args, **kwargs):
        kwargs.setdefault("file", sys.stderr)
        builtins.print(*args, **kwargs)

    def load(self, path):
        path = self._allowed_path(path)
        code = compile_driver(path)
        self.module = ModuleType("_pymybot_driver_" + uuid4().hex)
        self.module.__file__ = str(path)
        self.module.__builtins__ = dict(vars(builtins), print=self._print)
        sys.modules[self.module.__name__] = self.module
        previous, self.budget = self.budget, Budget(self.stop_event, 30)
        try:
            self._check()
            exec(code, self.module.__dict__)
            factory = self.module.__dict__.get("Driver")
            if not isinstance(factory, type):
                raise DriverError("Python module must export a Driver class")
            self.driver = factory(self.context)
            for name in ("build", "call"):
                if not self.has_function(name):
                    raise DriverError(f"Python Driver must define {name}(data)")
            self._check()
        except (BudgetExceeded, ScriptError, DriverError):
            raise
        except Exception as exc:
            raise DriverError(f"Cannot load Python driver {path}: {exc}") from exc
        finally:
            self.budget = previous

    def has_function(self, name):
        if self._virtual is not None:
            return self._virtual.has_function(name)
        return not self._closed and callable(getattr(self.driver, name, None))

    def call(self, name, data=None, *, budget=None):
        if not self.has_function(name):
            raise DriverError(f"Python function '{name}' is not available")
        if budget is None:
            budget = Budget(timeout=30) if name == "destroy" else Budget(self.stop_event, 30)
        virtual_driver = getattr(self.module, "LUA_VIRTUAL_DRIVER", None)
        if name == "build" and self._virtual is None and virtual_driver and data and (
                data.get("proto") == "virt" or re.fullmatch(r"virt-\w[\w_./-]*", str(data.get("path", "")))):
            from .runtime import LuaState
            self._virtual = LuaState(self.module_paths, self.hal, self.stop_event, allow_hardware=False)
            self._virtual.load(self._resolve(virtual_driver))
        if self._virtual is not None:
            return self._virtual.call(name, data, budget=budget)
        previous = self.budget
        self.budget = budget
        try:
            self._check()
            value = getattr(self.driver, name)(_primitive(dict(data or {}, mode=name)))
            self._check()
            if not isinstance(value, dict) or not value:
                raise DriverError(f"Python {name} must return a non-empty dictionary")
            return _primitive(value)
        except (BudgetExceeded, ScriptError, DriverError):
            raise
        except Exception as exc:
            raise DriverError(f"Python {name} failed: {exc}") from exc
        finally:
            self.budget = previous

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._virtual is not None:
            self._virtual.close()
            self._virtual = None
        self.driver = None
        if self.module is not None:
            sys.modules.pop(self.module.__name__, None)
            self.module = None
        self.hal.release_owner(self._owner)
