from __future__ import annotations

import copy
import json
import math
import re
import threading
import time
from contextlib import contextmanager
from typing import Callable

from .errors import BudgetExceeded, DriverError, DriverNotReady, ScriptError
from .expr import Expression, expr_body, parse_number, render, select_member
from .matrix import struct_json


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*\Z")
FLOW = re.compile(r"(controller|trigger)[0-9]*\Z")
_local = threading.local()


def safe_ident(name: str) -> str:
    if not isinstance(name, str) or not IDENT.fullmatch(name):
        raise ScriptError(f"Unsafe identifier: {name!r}")
    return name


class Budget:
    def __init__(self, stop_event=None, timeout=None, cancel=None):
        self.stop_event = stop_event if stop_event is not None else threading.Event()
        # Per-request cancellation; unlike stop_event it does not stop daemons.
        self.cancel = cancel
        self.deadline = time.monotonic() + timeout if timeout and timeout > 0 else None

    def check(self):
        if self.stop_event.is_set() or (self.cancel is not None and self.cancel.is_set()):
            raise BudgetExceeded("Stop requested; halting hardware dispatch")
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise BudgetExceeded("Action script execution timed out")


@contextmanager
def depth_guard(label):
    depth = getattr(_local, label, 0)
    if depth >= 32:
        raise ScriptError(f"Circular {label} reference or nesting exceeds 32 levels")
    setattr(_local, label, depth + 1)
    try:
        yield depth
    finally:
        setattr(_local, label, depth)


def ensure_ok(result, context="driver"):
    if not isinstance(result, dict) or not result:
        raise DriverError(f"{context}: expected a non-empty result table")
    status = result.get("result")
    if "result" in result and not isinstance(status, str):
        raise DriverError(f"{context}: result must be a string")
    if isinstance(status, str) and status.strip() == "ERR":
        error = DriverNotReady if result.get("code") == "NOT_READY" else DriverError
        raise error(f"{context}: {result.get('message', 'driver returned ERR')}")
    if status is not None and status.strip() != "OK":
        raise DriverError(f"{context}: unknown result status {status!r}")
    return result


class Variable:
    kind = "variable"

    def __init__(self, name):
        self.name = safe_ident(name)

    def build(self):
        pass

    def destroy(self):
        pass

    def read(self):
        return self.play({})


class Alias(Variable):
    kind = "alias"

    def __init__(self, name, value):
        super().__init__(name)
        self.value = str(value)

    def play(self, params):
        return self.value


class Number(Variable):
    kind = "vars"

    def __init__(self, name, value, resolver: Callable | None = None):
        super().__init__(name)
        self.value = str(value)
        body = expr_body(self.value)
        self.expression = Expression(body) if body is not None else None
        self.resolver = resolver
        if self.expression is None:
            self.numeric()

    def numeric(self):
        with depth_guard("numeric"):
            try:
                value = self.expression.evaluate(self.resolver) if self.expression else parse_number(self.value)
            except (TypeError, ValueError) as exc:
                raise ScriptError(f"@Vars '{self.name}' is not numeric: {self.value}") from exc
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ScriptError(f"@Vars '{self.name}' must be a finite number")
            return float(value)

    def play(self, params):
        return render(self.numeric())


class Struct(Variable):
    kind = "struct"

    def __init__(self, name, value):
        super().__init__(name)
        self.value = json.loads(struct_json(value))

    def play(self, params):
        return self.value

    def updated(self, keys, value):
        candidate = copy.deepcopy(self.value)
        if keys:
            parent = candidate
            for key in keys[:-1]:
                parent = select_member(parent, key)
            select_member(parent, keys[-1])
            parent[keys[-1]] = value
        else:
            candidate = value
        return Struct(self.name, candidate)


class Registry:
    def __init__(self):
        self._base = {}
        self._overrides = {}
        self.flow_refs = set()

    def get(self, name, default=None):
        return self._overrides.get(name, self._base.get(name, default))

    def require(self, name):
        value = self.get(name)
        if value is None:
            raise ScriptError(f"Hardware variable '{name}' is not defined")
        return value

    def __contains__(self, name):
        return self.get(name) is not None

    def __len__(self):
        return len(dict(self.items()))

    def __iter__(self):
        return iter(dict(self.items()))

    def __getitem__(self, name):
        return self.require(name)

    def items(self):
        return (self._base | self._overrides).items()

    def values(self):
        return (self._base | self._overrides).values()

    def add(self, variable):
        if variable.name in self:
            raise ScriptError(f"Duplicate hardware variable name '{variable.name}'")
        self._base[variable.name] = variable

    def remove(self, name):
        self._overrides.pop(name, None)
        return self._base.pop(name)

    def override(self, name, variable):
        safe_ident(name)
        if name in self.flow_refs:
            raise ScriptError(f"Cannot override '{name}': referenced by controller/trigger")
        existing = self.get(name)
        if existing is not None and existing.kind == "struct" and variable.kind != "struct":
            raise ScriptError(f"Cannot replace Struct '{name}' with another variable type")
        self._overrides[name] = variable

    @contextmanager
    def session(self):
        previous = self._overrides.copy()
        try:
            yield self
        finally:
            self._overrides = previous

    def resolve(self, name):
        var = self.require(name)
        if var.kind == "vars":
            return var.numeric()
        if var.kind in {"alias", "struct"}:
            return var.read()
        raise ScriptError(f"Expression identifier '{name}' is not an @Vars/@Alias/@Struct variable")

    def resolve_number(self, name):
        var = self.require(name)
        if var.kind == "struct":
            return var.read()
        if var.kind != "vars":
            raise ScriptError(f"Expression identifier '{name}' must be an @Vars number or @Struct value")
        return var.numeric()


class Metadata:
    def __init__(self, table, row, registry):
        self.table = table
        self.row = row
        self.registry = registry
        self.static = {}
        self.references = []
        self.expressions = []

    def seed(self):
        for j, column in enumerate(self.table.header):
            value = self.table.inherited(self.row, j)
            if column == "name" or FLOW.fullmatch(column) or value == "-":
                continue
            body = expr_body(value)
            if body is not None:
                expression = Expression(body)
                for name in expression.identifiers:
                    self.registry.require(name)
                self.expressions.append((column, expression))
            elif value.startswith("$"):
                self.references.append((column, self.registry.require(value[1:])))
            else:
                self.static[column] = value

    def collect(self, for_destroy=False, *, for_build=False):
        with depth_guard("metadata"):
            result = self.static.copy()
            for column, expression in self.expressions:
                try:
                    value = expression.evaluate(self.registry.resolve_number)
                    if isinstance(value, bool) or not isinstance(value, (int, float)):
                        raise ScriptError("Metadata expression must produce a number")
                    result[column] = render(value)
                except Exception:
                    if not for_destroy:
                        raise
            for column, target in self.references:
                try:
                    value = target.read()
                    if target.kind == "vars":
                        result[column] = value
                    elif isinstance(value, dict):
                        result.update(ensure_ok(value, f"read {target.name}"))
                    else:
                        raise ScriptError(f"'${target.name}' returned a scalar; only @Vars can fill a column")
                except DriverNotReady:
                    # Snapshot consumers can initialize before the first sample exists.
                    if not for_build and not for_destroy:
                        raise
                except Exception:
                    if not for_destroy:
                        raise
            return result


class LuaVariable(Variable):
    kind = "lua"

    def __init__(self, name, path, metadata, controllers, triggers, runtime_factory):
        super().__init__(name)
        self.path = path
        self.metadata = metadata
        self.controllers = controllers
        self.triggers = triggers
        self.runtime_factory = runtime_factory
        self.runtime = None
        self.budget = None

    def build(self):
        self.runtime = self.runtime_factory()
        self.runtime.load(self.path)
        ensure_ok(self.runtime.call("build", self.metadata.collect(for_build=True)), f"build {self.name}")

    def play(self, params):
        if self.runtime is None:
            raise DriverError(f"'{self.name}' not built or already destroyed")
        if self.budget:
            self.budget.check()
        with depth_guard("call") as depth:
            metadata = self.metadata.collect()
            if depth == 0:
                reserved = set(metadata) | {"mode", "result", "message"} | {t.name for t in self.triggers}
                overlap = reserved & params.keys()
                if overlap:
                    raise ScriptError(f"Action parameters overwrite reserved metadata: {', '.join(sorted(overlap))}")
            data = metadata | params
            for target in self.triggers:
                data[target.name] = ensure_ok(target.play({}), f"trigger {target.name}")
            result = ensure_ok(self.runtime.call("call", data, budget=self.budget), f"call {self.name}")
            if self.controllers:
                payload = metadata | result
                for target in self.controllers:
                    if self.budget:
                        self.budget.check()
                    result = ensure_ok(target.play(payload.copy()), f"controller {target.name}")
            return result

    def read(self):
        if self.runtime is None:
            raise DriverError(f"'{self.name}' not built or already destroyed")
        return self.runtime.call("read" if self.runtime.has_function("read") else "call", self.metadata.collect(), budget=self.budget)

    def destroy(self):
        if self.runtime is None:
            return
        runtime, self.runtime = self.runtime, None
        try:
            if runtime.has_function("destroy"):
                ensure_ok(runtime.call("destroy", self.metadata.collect(True)), f"destroy {self.name}")
        finally:
            runtime.close()
