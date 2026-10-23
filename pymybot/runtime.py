from __future__ import annotations

import math
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

from lupa.luajit21 import LuaRuntime, lua_type

from .errors import BudgetExceeded, DriverError, ScriptError
from .hardware import Budget


def _loopback_base(base):
    """True when base is an http(s) URL whose host is a loopback address."""
    if not isinstance(base, str):
        return False
    try:
        parts = urlsplit(base)
        parts.port  # property access raises ValueError on malformed ports
    except ValueError:
        return False
    return parts.scheme in {"http", "https"} and parts.hostname in {"127.0.0.1", "localhost", "::1"}


_BOOTSTRAP = r'''
function(loader, resolve, roots, output, getenv, hal, daemon, check)
    local raw_tostring, raw_type = tostring, type
    local sethook, jit_off, jit_on = debug.sethook, jit.off, jit.on
    local function hook() check() end
    python = nil
    package.loaded.python = nil
    package.preload.python = nil
    debug = nil
    package.loaded.debug = nil
    package.preload.debug = nil
    package.loadlib = nil
    package.path, package.cpath = '', ''
    local function blocked() return '\nFile/native module loading is restricted to module roots' end
    package.loaders = {package.loaders[1], blocked}
    os.execute, os.exit, os.remove, os.rename, os.tmpname = nil, nil, nil, nil, nil
    os.getenv = function(name) return getenv(name) end
    print = function(...)
        local values = {}
        for i=1,select('#', ...) do values[i] = raw_tostring(select(i, ...)) end
        output(table.concat(values, '\t'))
    end
    io = {stderr={write=function(_, ...) output(table.concat({...}, '')); return true end,
                  flush=function() return true end}}
    loadfile = function(path) return loader(path) end
    dofile = function(path)
        local f, err = loader(path)
        if not f then error(err, 2) end
        return f()
    end
    __mpath = {
        paths=function() return roots end,
        resolve=function(relative) return resolve(relative) end,
        dofile=function(relative) return dofile(resolve(relative)) end
    }
    package.preload.mpath = function() return __mpath end
    __hal_call = function(operation, ...) return hal(operation, ...) end
    __daemon_call = function(operation, ...) return daemon(operation, ...) end
    return function(enabled)
        if enabled then jit_off(); sethook(hook, '', 500)
        else sethook(); jit_on() end
    end
end
'''


class LuaState:
    def __init__(self, module_paths, hal, stop_event, *, daemon=None, allow_hardware=False):
        self.module_paths = [Path(p).resolve() for p in module_paths]
        self.hal = hal
        self.stop_event = stop_event
        self.daemon = daemon
        self.allow_hardware = allow_hardware
        self.budget = None
        self._closed = False
        self.lua = LuaRuntime(
            register_eval=False,
            register_builtins=False,
            attribute_filter=self._deny_attribute,
            unpack_returned_tuples=True,
            max_memory=128 * 1024 * 1024,
        )
        self.globals = self.lua.globals()
        bootstrap = self.lua.eval(_BOOTSTRAP)
        self._set_hook = bootstrap(self._loader, self._resolve, self.to_lua([str(p) for p in self.module_paths]), self._output, self._getenv, self._hal_call, self._daemon_call, self._check)
        if daemon is not None:
            for name, value in daemon.globals().items():
                self.globals[name] = self.to_lua(value)

    @staticmethod
    def _deny_attribute(obj, name, setting):
        raise AttributeError("Python attribute access is disabled in Lua drivers")

    @staticmethod
    def _output(text):
        print(str(text), file=sys.stderr)

    def _getenv(self, name):
        if not isinstance(name, str) or re.search(r"KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL", name, re.I):
            return None
        if name == "BOT4CJ_MODULE_PATH":
            return os.pathsep.join(str(p) for p in self.module_paths)
        return os.environ.get(name)

    def _check(self):
        if self.budget is not None:
            self.budget.check()
        if self.daemon is not None:
            if self.daemon.quiesced or (self.daemon.stopping and not self.daemon.cleaning_up):
                raise BudgetExceeded("Daemon stopped or quiesced")

    def _hal_call(self, operation, *args):
        self._check()
        values = [self.from_lua(v) for v in args]
        if not self.allow_hardware:
            physical = operation in {"i2c_open", "spi_open"}
            physical |= operation == "uart_open" and (not values or values[0] != "loop://")
            if operation == "camera_capture":
                options = values[1] if len(values) > 1 and isinstance(values[1], dict) else {}
                physical |= not bool(options.get("src"))
            if physical:
                raise DriverError("Physical hardware access requires explicit --allow-hardware confirmation")
            if operation == "http_open" and not _loopback_base(values[0] if values else None):
                raise DriverError("HTTP access beyond loopback requires explicit --allow-hardware confirmation")
            if operation == "shell_open":
                raise DriverError("Host command execution requires explicit --allow-hardware confirmation")
        if operation == "sleep_ms" and values:
            milliseconds = float(values[0])
            if math.isfinite(milliseconds) and milliseconds > 0:
                remaining = min(milliseconds, 4294967)
                while remaining > 0:
                    self._check()
                    duration = min(remaining, 50)
                    self.hal.call(operation, duration)
                    remaining -= duration
                self._check()
                return 0
        result = self.hal.call(operation, *values)
        self._check()
        return self.to_lua(result)

    def _daemon_call(self, operation, *args):
        if self.daemon is None:
            raise DriverError("No daemon attached to this Lua runtime")
        return self.to_lua(self.daemon.bridge(operation, *(self.from_lua(v) for v in args)))

    def _resolve(self, relative):
        if not isinstance(relative, str):
            raise ScriptError("Module path must be a string")
        part = Path(relative)
        if part.is_absolute() or ".." in part.parts or "\\" in relative or ":" in relative:
            raise ScriptError("Module path escapes allowed roots")
        for root in self.module_paths:
            candidate = root / part
            if candidate.is_file():
                return str(self._allowed_path(candidate))
        return str(self._allowed_path(self.module_paths[-1] / part))

    def _allowed_path(self, path):
        path = Path(path)
        if ".." in path.parts:
            raise ScriptError("Module path traversal rejected")
        absolute = path.absolute()
        for root in self.module_paths:
            if absolute.is_relative_to(root):
                current = root
                for part in absolute.relative_to(root).parts:
                    current = current / part
                    if current.is_symlink():
                        raise ScriptError(f"Symlink module rejected: {path}")
                if absolute.resolve().is_relative_to(root):
                    return absolute
        raise ScriptError(f"Module is outside allowed roots: {path}")

    def _loader(self, path):
        try:
            allowed = self._allowed_path(path)
            with allowed.open("rb") as stream:
                source = stream.read(8 * 1024 * 1024 + 1)
            if len(source) > 8 * 1024 * 1024 or source.startswith(b"\x1b"):
                raise ScriptError("Lua source exceeds size limit or contains bytecode")
            return self.lua.compile(source.decode("utf-8"), name="@" + str(allowed), mode="t")
        except Exception as exc:
            return None, str(exc)

    def load(self, path):
        loaded = self._loader(path)
        if isinstance(loaded, tuple):
            raise DriverError(loaded[1])
        previous = self.budget
        self.budget = Budget(self.stop_event, 30) if self.daemon is None else None
        self._set_hook(True)
        try:
            return loaded()
        except BudgetExceeded:
            raise
        except Exception as exc:
            raise DriverError(f"Cannot load Lua driver {path}: {exc}") from exc
        finally:
            self._set_hook(False)
            self.budget = previous

    def has_function(self, name):
        return not self._closed and lua_type(self.globals[name]) == "function"

    def call(self, name, data=None, *, budget=None):
        if self._closed or not self.has_function(name):
            raise DriverError(f"Lua function '{name}' is not available")
        previous = self.budget
        self.budget = budget if budget is not None else Budget(timeout=30)
        self._set_hook(True)
        try:
            self._check()
            if data is None:
                value = self.globals[name]()
            else:
                value = self.globals[name](self.to_lua(dict(data, mode=name)))
            if isinstance(value, tuple):
                value = value[0] if value else None
            if name in {"daemon_tick", "daemon_cleanup"}:
                return self.from_lua(value)
            if lua_type(value) != "table":
                raise DriverError(f"{name} must return a table")
            return self.from_lua(value, outer=True)
        except (BudgetExceeded, ScriptError, DriverError):
            raise
        except Exception as exc:
            raise DriverError(f"Lua {name} failed: {exc}") from exc
        finally:
            self._set_hook(False)
            self.budget = previous

    def to_lua(self, value, depth=0):
        if depth > 32:
            raise ScriptError("Python/Lua value exceeds maximum nesting depth")
        if isinstance(value, str):
            if "\x00" in value:
                raise ScriptError("NUL is not allowed in Lua input")
            return value
        if value is None or isinstance(value, (bool, int, float)):
            return value
        if isinstance(value, (dict, list, tuple)):
            table = self.lua.table()
            entries = value.items() if isinstance(value, dict) else enumerate(value, 1)
            for key, item in entries:
                table[self.to_lua(key, depth + 1)] = self.to_lua(item, depth + 1)
            return table
        raise ScriptError(f"Unsupported Python/Lua value type: {type(value).__name__}")

    def from_lua(self, value, depth=0, *, outer=False):
        if depth > 9:
            raise DriverError("Lua result exceeds maximum nesting depth")
        if lua_type(value) == "table":
            entries = list(value.items())
            if not outer and all(isinstance(k, (int, float)) and not isinstance(k, bool) and math.isfinite(k) and int(k) == k for k, _ in entries):
                return [self.from_lua(v, depth + 1) for k, v in sorted(entries)]
            result = {}
            for key, item in entries:
                if isinstance(key, str):
                    result[key] = self.from_lua(item, depth + 1)
                elif not outer and isinstance(key, (int, float)) and not isinstance(key, bool):
                    result[str(int(key)) if math.isfinite(key) and int(key) == key else str(key)] = self.from_lua(item, depth + 1)
            return result
        if isinstance(value, float) and not math.isfinite(value):
            return None
        if value is None or isinstance(value, (str, bool, int, float)):
            return value
        return None

    def close(self):
        if not self._closed:
            self._set_hook(False)
            self._closed = True
            self.globals = None
            self._set_hook = None
            self.lua = None
