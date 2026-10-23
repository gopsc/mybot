"""Ordered action dispatch, captures, conditions, and Trigger/Reflex calls."""
from __future__ import annotations

import re

from .errors import ScriptError
from .expr import Expression, Reference, expr_body, parse_number, render
from .matrix import MAX_BLOCK_DEPTH, Matrix, is_control, split_action_column, struct_name

_SAFE_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_SCALARS = {"alias", "vars", "struct"}


class ActionRunner:
    def __init__(self, registry, budget):
        self.registry = registry
        self.budget = budget
        self._capture_writes: dict | None = None

    def _value(self, expression: Expression):
        self.budget.check()
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
            raise ScriptError(f"@Action device alias '{name}' targets undefined hardware '{target}'")
        if resolved.kind in _SCALARS:
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
        return reference.name, reference.resolve_path(self.registry.resolve), path

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
                variable = Number(var, float(value))
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
        if self._capture_writes is not None:
            self._capture_writes[var] = variable

    @staticmethod
    def _ensure_result(value, device: str) -> dict:
        if not isinstance(value, dict) or not value:
            raise ScriptError(f"Hardware '{device}' returned a non-table or empty table")
        if "result" in value:
            result = value["result"]
            if not isinstance(result, str) or result.strip() != "OK":
                raise ScriptError(f"Hardware '{device}' failed: {value.get('message', result)!r}")
        return value

    def dispatch(self, matrix: Matrix) -> list[dict]:
        """Dispatch a plain action matrix, also used by hot SQL and Reflex."""
        self.budget.check()
        if matrix.children or is_control(matrix.name):
            raise ScriptError("dispatch expects a plain action matrix, not a control block")
        columns: list[tuple[str, str]] = []
        seen: set[tuple[str, str]] = set()
        order: list[str] = []
        phase_devices: set[str] = set()
        for col, head in enumerate(matrix.header):
            self.budget.check()
            raw_device, raw_param = split_action_column(head)
            device, param = self._device(raw_device), self._param(raw_param)
            if (device, param) in seen:
                raise ScriptError(f"Action column {head!r} duplicates target {device}.{param}")
            seen.add((device, param))
            columns.append((device, param))
            if device not in order:
                order.append(device)
            if any(row[col] not in {"-", ""} for row in matrix.data):
                phase_devices.add(device)
        outputs: list[dict] = []
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
                elif capture := self._capture(raw):
                    captures.setdefault(device, []).append(capture)
                    continue
                else:
                    value = 0.0 if raw == "-" else parse_number(raw)
                parameters.setdefault(device, {})[param] = value
            for device in order:
                self.budget.check()
                variable = self.registry.require(device)
                if variable.kind in _SCALARS:
                    raise ScriptError(f"@Action target '{device}' must be a driver or daemon")
                if device not in parameters and device not in captures:
                    continue
                result = self._ensure_result(variable.play(parameters.get(device, {})), device)
                outputs.append(result)
                for var, keys, path in captures.get(device, []):
                    self._apply_capture(result, var, keys, path)
                self.budget.check()
        return outputs

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

    def _sequence(self, matrices: list[Matrix], outputs: list[dict], depth: int = 0) -> bool:
        if depth > MAX_BLOCK_DEPTH:
            raise ScriptError("Execution block nesting exceeds depth limit")
        actionable = False
        for matrix in matrices:
            self.budget.check()
            name = matrix.name.strip()
            if name == "Action":
                actionable = True
                outputs.extend(self.dispatch(matrix))
            elif is_control(name):
                actionable = True
                condition = self._condition(matrix)
                if name.startswith("if("):
                    if self._test_condition(condition):
                        self._sequence(matrix.children, outputs, depth + 1)
                else:
                    while True:
                        self.budget.check()  # Includes empty-body, forever-true loops.
                        if not self._test_condition(condition):
                            break
                        self._sequence(matrix.children, outputs, depth + 1)
            elif name in {"Alias", "Vars", "Trigger", "Reflex"} or struct_name(name) is not None:
                if depth:
                    raise ScriptError(f"@{name} may only be used at top level, not inside a control block")
            else:
                raise ScriptError(f"Unsupported action block @{name[:160]}; Include/Merge must be expanded first")
        return actionable

    @staticmethod
    def _trigger(text: str) -> tuple[str, dict[str, str]]:
        args: dict[str, str] = {}
        if "(" not in text:
            name = text.strip()
        else:
            name, rest = text.split("(", 1)
            name = name.strip()
            if not rest.endswith(")"):
                raise ScriptError("Trigger call must end with a closing ')'")
            for segment in rest[:-1].split(","):
                segment = segment.strip()
                if not segment:
                    continue
                key, eq, value = segment.partition("=")
                key, value = key.strip(), value.strip()
                if not eq or not value or not _SAFE_IDENT.fullmatch(key):
                    raise ScriptError("Trigger arguments must be safe_identifier=value")
                if key in args:
                    raise ScriptError(f"Trigger binds duplicate argument '{key}'")
                args[key] = value
        if not name:
            raise ScriptError("Trigger call is missing a reflex name")
        return name, args

    def _reflex(self, matrices: list[Matrix], outputs: list[dict]) -> None:
        from .hardware import Alias

        triggers = [m for m in matrices if m.name.strip() == "Trigger"]
        if not triggers:
            return  # Untriggered definitions are deliberately lazy.
        reflexes = [m for m in matrices if m.name.strip() == "Reflex"]
        if len(triggers) != 1 or len(reflexes) != 1:
            raise ScriptError("@Trigger requires exactly one @Trigger and one @Reflex definition table")
        definitions = reflexes[0]
        if definitions.require_col("name") != 0:
            raise ScriptError("@Reflex requires 'name' as its first column")
        groups: dict[str, list[list[str]]] = {}
        for row in definitions.data:
            if row[0].strip():
                groups.setdefault(row[0].strip(), []).append(row[1:])
        if not groups:
            raise ScriptError("@Reflex has no definition rows")
        trigger = triggers[0]
        column = trigger.require_col("trigger")
        for row in range(1, len(trigger.rows)):
            self.budget.check()
            line = trigger.inherited(row, column).strip()
            if not line:
                continue
            name, args = self._trigger(line)
            if name not in groups:
                raise ScriptError(f"Trigger references undefined reflex '{name}'")
            action = Matrix("Action", [definitions.header[1:]] + groups[name])
            writes: dict = {}
            self._capture_writes = writes
            try:
                with self.registry.session():
                    for key, value in args.items():
                        self.registry.override(key, Alias(key, value))
                    outputs.extend(self.dispatch(action))
            finally:
                self._capture_writes = None
                # Only argument bindings are trigger-local. Captures into other
                # names survive for later triggers, like ordinary action captures.
                for key, variable in writes.items():
                    if key not in args:
                        self.registry.override(key, variable)

    def run(self, matrices: list[Matrix]) -> list[dict]:
        """Execute registered matrices; caller owns the enclosing run session."""
        outputs: list[dict] = []
        actionable = self._sequence(matrices, outputs)
        if not actionable and not any(m.name.strip() == "Trigger" for m in matrices):
            raise ScriptError("No @Action matrix found in the script")
        self._reflex(matrices, outputs)
        return outputs
