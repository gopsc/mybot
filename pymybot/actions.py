"""Ordered action dispatch, captures, conditions, and scoped Reflex calls."""
from __future__ import annotations

import json
import re

from .errors import ScriptError
from .expr import Expression, Reference, evaluation_guard, expr_body, parse_number, render
from .hardware import Alias, Number, Struct, depth_guard
from .matrix import MAX_BLOCK_DEPTH, Matrix, is_control, reflex_name, split_action_column, struct_name
from .security import MAX_BODY, dumps

_SAFE_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_SCALARS = {"alias", "vars", "struct"}
MAX_OUTPUT_BYTES = MAX_BODY
MAX_OUTPUTS = 10_000


class _OutputCollector:
    def __init__(self, limit=None, max_items=None):
        self.limit = MAX_OUTPUT_BYTES if limit is None else limit
        self.max_items = MAX_OUTPUTS if max_items is None else max_items
        self.items: list[dict] = []
        self.size = 0

    def add(self, value):
        size = len(dumps(value).encode("utf-8"))
        if len(self.items) >= self.max_items:
            raise ScriptError(f"Action output budget exceeded: more than {self.max_items} "
                              "results; remaining actions were not run")
        if self.size + size > self.limit:
            raise ScriptError(f"Action output budget exceeded: {self.size + size} bytes "
                              f"> {self.limit}; remaining actions were not run")
        self.size += size
        self.items.append(value)


class ActionRunner:
    def __init__(self, registry, budget):
        self.registry = registry
        self.budget = budget
        self._reflex_actions: dict[str, Matrix] = {}
        self._execution_depth = 0

    def declare_scalars(self, matrices: list[Matrix], *, local=False):
        declared = set()
        for matrix in matrices:
            self.budget.check()
            name = struct_name(matrix.name)
            if name is not None:
                if name in declared or self.registry.get(name) is not None:
                    raise ScriptError(f"Duplicate Struct variable '{name}'")
                declared.add(name)
                self.registry.override(name, Struct(name, json.loads(matrix.json_text)))
                continue
            if matrix.name not in {"Alias", "Vars"}:
                continue
            field = "alias" if matrix.name == "Alias" else "value"
            if "name" not in matrix.header or field not in matrix.header:
                raise ScriptError(f"{matrix.name} requires name/{field} columns")
            for i in range(1, len(matrix.rows)):
                self.budget.check()
                name = matrix.rows[i][matrix.header.index("name")]
                if name in declared:
                    raise ScriptError(f"Duplicate session variable '{name}'")
                declared.add(name)
                existing = self.registry.get(name)
                if local and existing is not None and existing.kind not in {"alias", "vars"}:
                    raise ScriptError(f"Reflex local '{name}' cannot replace a driver, daemon or Struct")
                if not local and matrix.name == "Vars" and existing is not None:
                    raise ScriptError(f"@Vars '{name}' cannot override a structure variable")
                value = matrix.inherited(i, matrix.header.index(field))
                if matrix.name == "Alias":
                    variable = Alias(name, value)
                else:
                    precision = None
                    if "precision" in matrix.header:
                        raw = matrix.inherited(i, matrix.header.index("precision"))
                        if raw.strip() not in {"-", ""}:
                            try:
                                precision = int(raw)
                            except ValueError:
                                raise ScriptError(f"@Vars '{name}' precision must be an integer from 0 to 15") from None
                    variable = Number(name, value, self.registry.resolve_number, precision=precision)
                self.registry.override(name, variable)

    def _value(self, expression: Expression):
        self.budget.check()
        with evaluation_guard(self.budget.check):
            return expression.evaluate(self.registry.resolve)

    def _parameter_value(self, text: str):
        value = self._value(Expression(expr_body(text)))
        if isinstance(value, bool):
            raise ScriptError("@Action $(...) cannot produce a boolean result; use an @if condition")
        return value

    def _device(self, text: str) -> str:
        name = render(self._parameter_value(text)) if expr_body(text) is not None else text
        variable = self.registry.get(name)
        if variable is None or variable.kind not in _SCALARS:
            return name
        if variable.kind in {"vars", "struct"}:
            raise ScriptError(f"Variable '{name}' cannot name an @Action device directly; use an expression or @Alias")
        target = variable.read()
        if not isinstance(target, str):
            raise ScriptError(f"@Alias '{name}' must contain text")
        resolved = self.registry.get(target)
        if resolved is None:
            if self._reflex_action(target) is None:
                raise ScriptError(f"@Action device alias '{name}' targets undefined hardware or reflex '{target}'")
        elif resolved.kind in _SCALARS:
            raise ScriptError("@Action device aliases support only one level of indirection, not scalar targets")
        return target

    def _param(self, text: str) -> str:
        if expr_body(text) is not None:
            return render(self._parameter_value(text))
        variable = self.registry.get(text)
        return render(variable.read()) if variable is not None and variable.kind in _SCALARS else text

    def _capture(self, text: str) -> tuple[str, tuple, str] | None:
        if not text.startswith("$") or text.startswith("$("):
            return None
        target, equals, path = text[1:].partition("=")
        if not equals:
            raise ScriptError("Invalid @Action capture: expected $target=field.path")
        reference = Reference(target)
        if not path or any(not part for part in path.split(".")):
            raise ScriptError("Capture field path must have nonempty dot-separated segments")
        with evaluation_guard(self.budget.check):
            keys = reference.resolve_path(self.registry.resolve)
        return reference.name, keys, path

    def _apply_capture(self, result: dict, var: str, keys: tuple, path: str) -> None:
        from .hardware import Alias, Number

        value = result
        for segment in path.split("."):
            if not isinstance(value, dict) or segment not in value:
                raise ScriptError(f"Capture ${var}={path}: field '{segment}' absent or parent is not an object")
            value = value[segment]
        existing = self.registry.get(var)
        numeric = isinstance(value, (float, int)) and not isinstance(value, bool)
        if keys and (existing is None or existing.kind != "struct"):
            raise ScriptError("Capture member assignment requires a declared @Struct")
        if existing is not None:
            if existing.kind == "struct":
                variable = existing.updated(keys, value)
            elif existing.kind == "vars":
                if not numeric:
                    raise ScriptError(f"Capture target @Vars '{var}' requires a numeric field")
                render(value)
                variable = Number(var, float(value), precision=getattr(existing, "precision", None))
            elif existing.kind == "alias":
                variable = Alias(var, render(value))
            else:
                raise ScriptError(f"Cannot capture into driver/daemon '{var}'; target must be @Vars/@Alias")
        elif numeric:
            render(value)
            variable = Number(var, float(value))
        elif isinstance(value, str):
            variable = Alias(var, value)
        else:
            raise ScriptError(f"Cannot infer capture type for '{var}'; declare @Alias for bool fields")
        self.registry.override(var, variable)

    @staticmethod
    def _ensure_result(value, device: str) -> dict:
        if not isinstance(value, dict) or not value:
            raise ScriptError(f"Hardware '{device}' returned a non-table or empty table")
        if "result" in value:
            result = value["result"]
            if not isinstance(result, str) or result.strip() != "OK":
                raise ScriptError(f"Hardware '{device}' failed: {value.get('message', result)!r}")
        return value

    def dispatch(self, matrix: Matrix, outputs=None) -> list[dict]:
        """Dispatch a plain action matrix, also used by hot SQL and Reflex."""
        self.budget.check()
        sink = outputs if outputs is not None else _OutputCollector()
        if matrix.children or is_control(matrix.name):
            raise ScriptError("dispatch expects a plain action matrix, not a control block")
        columns: list[tuple[str, str]] = []
        seen: set[tuple[str, str]] = set()
        order: list[str] = []
        phase_devices: set[str] = set()
        reflex_targets: dict[str, Matrix] = {}
        for col, head in enumerate(matrix.header):
            self.budget.check()
            raw_device, raw_param = split_action_column(head)
            device = self._device(raw_device)
            action = self._reflex_action(device) if self.registry.get(device) is None else None
            if action is not None:
                reflex_targets[device] = action
            param = raw_param if action is not None and expr_body(raw_param) is None else self._param(raw_param)
            if action is not None and not _SAFE_IDENT.fullmatch(param):
                raise ScriptError("Reflex parameter names must be safe identifiers")
            if (device, param) in seen:
                raise ScriptError(f"Action column {head!r} duplicates target {device}.{param}")
            seen.add((device, param))
            columns.append((device, param))
            if device not in order:
                order.append(device)
            if any(row[col] not in {"-", ""} for row in matrix.data):
                phase_devices.add(device)
        previous = ["-"] * len(columns)
        cache: list[tuple[str, Expression] | None] = [None] * len(columns)
        for row_index, row in enumerate(matrix.data, 1):
            self.budget.check()
            if len(row) != len(columns):
                raise ScriptError(f"Action row {row_index} does not match header column count")
            parameters: dict[str, dict] = {}
            captures: dict[str, list[tuple[str, tuple, str]]] = {}
            # Entire row is evaluated before ANY device plays. Captured values
            # become visible to subsequent rows/blocks, never same-row cells.
            for col, raw in enumerate(row):
                self.budget.check()
                device, param = columns[col]
                raw = previous[col] if raw == "-" else raw
                previous[col] = raw
                if raw == "-" and device in phase_devices:
                    continue
                body = expr_body(raw)
                if body is not None:
                    if cache[col] is None or cache[col][0] != body:
                        cache[col] = (body, Expression(body))
                    value = self._value(cache[col][1])
                    if isinstance(value, bool):
                        raise ScriptError("@Action cell $(...) cannot produce a boolean result")
                    # Display precision must not turn numeric Reflex arguments into text.
                    variable = self.registry.get(body.strip())
                    if (device not in reflex_targets and isinstance(value, float)
                            and isinstance(variable, Number) and variable.precision is not None):
                        value = variable.format(value)
                elif capture := self._capture(raw):
                    captures.setdefault(device, []).append(capture)
                    continue
                else:
                    value = 0.0 if raw == "-" else parse_number(raw)
                parameters.setdefault(device, {})[param] = value
            for device in order:
                self.budget.check()
                action = reflex_targets.get(device)
                if action is None:
                    variable = self.registry.require(device)
                    if variable.kind in _SCALARS:
                        raise ScriptError(f"@Action target '{device}' must be a driver, daemon or reflex")
                if device not in parameters and device not in captures:
                    continue
                if action is not None:
                    result = self._call_reflex(action, parameters.get(device, {}), sink)
                else:
                    result = self._ensure_result(variable.play(parameters.get(device, {})), device)
                for var, keys, path in captures.get(device, []):
                    self._apply_capture(result, var, keys, path)
                if action is None:
                    sink.add(result)
                self.budget.check()
        return sink.items

    @staticmethod
    def _condition(matrix: Matrix) -> Expression:
        name = matrix.name.strip()
        keyword = "while" if name == "while" or name.startswith("while(") else "if"
        if not name.startswith(keyword + "(") or not name.endswith(")"):
            raise ScriptError(f"@{keyword} requires a closed condition without spaces: @{keyword}(x>0)")
        if not name[len(keyword) + 1:-1].strip():
            raise ScriptError(f"@{keyword}() has an empty condition")
        if matrix.rows:
            raise ScriptError("Control block body must be represented by children, not matrix rows")
        return Expression(name[len(keyword) + 1:-1])

    def _test_condition(self, expression: Expression) -> bool:
        value = self._value(expression)
        if not isinstance(value, bool):
            raise ScriptError("@if/@while condition must be logical; no implicit truth conversion")
        return value

    def _sequence(self, matrices: list[Matrix], outputs: _OutputCollector, depth: int = 0) -> bool:
        if self._execution_depth > MAX_BLOCK_DEPTH:
            raise ScriptError("Execution block nesting exceeds depth limit")
        self._execution_depth += 1
        try:
            actionable = False
            for matrix in matrices:
                self.budget.check()
                name = matrix.name.strip()
                if name == "Action":
                    actionable = True
                    if matrix.children:
                        self._sequence(matrix.children, outputs, depth + 1)
                    else:
                        self.dispatch(matrix, outputs)
                elif is_control(name):
                    actionable = True
                    condition = self._condition(matrix)
                    if name.startswith("if("):
                        if self._test_condition(condition):
                            self._sequence(matrix.children, outputs, depth + 1)
                    else:
                        while True:
                            self.budget.check()
                            if not self._test_condition(condition):
                                break
                            self._sequence(matrix.children, outputs, depth + 1)
                elif name in {"Alias", "Vars"} or struct_name(name) is not None or reflex_name(name) is not None:
                    if depth:
                        raise ScriptError(f"@{name} declarations require the top level or a Reflex body")
                else:
                    raise ScriptError(f"Unsupported action block @{name[:160]}; Include/Merge must be expanded first")
            return actionable
        finally:
            self._execution_depth -= 1

    def _reflex_action(self, name: str) -> Matrix | None:
        return self._reflex_actions.get(name)

    def _call_reflex(self, action: Matrix, args: dict, outputs: _OutputCollector) -> dict:
        self.budget.check()
        with depth_guard("reflex"):
            bindings = {}
            for key, value in args.items():
                self.budget.check()
                if not _SAFE_IDENT.fullmatch(key):
                    raise ScriptError("Reflex parameter names must be safe identifiers")
                existing = self.registry.get(key)
                if existing is not None and existing.kind not in {"alias", "vars"}:
                    raise ScriptError(f"Reflex argument '{key}' cannot replace a driver, daemon or Struct")
                bindings[key] = Alias(key, value) if isinstance(value, str) else Number(key, value)
            start = len(outputs.items)
            with self.registry.session():
                self.declare_scalars(action.children, local=True)
                for key, variable in bindings.items():
                    self.registry.override(key, variable)
                self._sequence(action.children, outputs)
            return outputs.items[-1] if len(outputs.items) > start else {"result": "OK"}

    def run(self, matrices: list[Matrix]) -> list[dict]:
        """Execute registered matrices; caller owns the enclosing run session."""
        self._reflex_actions = {}
        for matrix in matrices:
            self.budget.check()
            name = reflex_name(matrix.name)
            if name is not None:
                if name in self._reflex_actions:
                    raise ScriptError(f"Duplicate Reflex definition '{name}'")
                self._reflex_actions[name] = matrix
        outputs = _OutputCollector()
        if not self._sequence(matrices, outputs):
            raise ScriptError("No @Action matrix found in the script")
        return outputs.items
