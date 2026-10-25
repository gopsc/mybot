from __future__ import annotations

import copy
import json
import os
import re
import sys
import threading
import time
from pathlib import Path

from .actions import ActionRunner
from .errors import ControllerError, DriverError, ScriptError
from .expr import Expression, expr_body
from .hardware import Alias, Budget, FLOW, LuaVariable, Metadata, Number, Registry, Struct, safe_ident
from .include import expand_includes
from .matrix import Matrix, parse_matrices, struct_name
from .paths import asset_path
from .sql import apply_statement, load_structure, parse_sql

MAX_SCRIPT_BYTES = 8 * 1024 * 1024


def check_script(text):
    if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_SCRIPT_BYTES or "\x00" in text:
        raise ScriptError("Script must be UTF-8 text without NUL and at most 8 MiB")
    return text


def module_roots(paths=None):
    if paths is None:
        configured = os.environ.get("BOT4CJ_MODULE_PATH", "")
        paths = [p for p in configured.split(os.pathsep) if p]
        if not paths:
            paths = [asset_path("modules")]
    if isinstance(paths, (str, Path)):
        paths = [paths]
    roots = list(dict.fromkeys(Path(p).resolve() for p in paths))
    if not roots or any(not p.is_dir() for p in roots):
        raise ScriptError("Module roots must be existing directories")
    return roots


class Robot:
    def __init__(self, sql_text, *, module_paths=None, camera_src_root=None, stop_event=None, allow_hardware=False):
        from .hal import HALManager
        self.tables = load_structure(check_script(sql_text))
        self.module_paths = module_roots(module_paths)
        self.registry = Registry()
        self.stop_event = stop_event if stop_event is not None else threading.Event()
        self.camera_src_root = camera_src_root
        self.allow_hardware = allow_hardware
        self.hal = HALManager(camera_src_root=camera_src_root)
        self.state = "Loaded"
        self.structure_path = ""
        self.deactivate_grace_ms = 30000
        self._lock = threading.RLock()
        self._metas = {}

    @classmethod
    def from_file(cls, path, **kwargs):
        path = Path(path)
        with path.open("rb") as stream:
            data = stream.read(MAX_SCRIPT_BYTES + 1)
        if len(data) > MAX_SCRIPT_BYTES:
            raise ScriptError("Structure script exceeds 8 MiB")
        robot = cls(data.decode("utf-8"), **kwargs)
        robot.structure_path = str(path)
        return robot

    def _module(self, relative):
        part = Path(relative)
        if part.is_absolute() or ".." in part.parts or "\\" in relative or ":" in relative:
            raise ScriptError(f"Module path escapes root: {relative}")
        for root in self.module_paths:
            candidate = root / part
            if candidate.is_file():
                current = root
                for segment in part.parts:
                    current = current / segment
                    if current.is_symlink():
                        raise ScriptError(f"Symlink module rejected: {candidate}")
                return candidate
        raise ScriptError(f"Lua module not found: {relative}")

    @staticmethod
    def _rows(tables):
        result = {}
        for table in tables.values():
            if table.name == "Action":
                continue
            if "name" not in table.header:
                raise ScriptError(f"Table '{table.name}' has no 'name' column")
            index = table.header.index("name")
            for row in range(1, len(table.rows)):
                name = safe_ident(table.rows[row][index])
                if name in result:
                    raise ScriptError(f"Duplicate hardware variable name '{name}'")
                result[name] = (table, row)
        return result

    def _validate(self, tables):
        rows = self._rows(tables)
        earlier = set()
        uart_paths = {}
        claims = {}
        paths = {}
        for name, (table, row) in rows.items():
            values = {col: table.inherited(row, j) for j, col in enumerate(table.header)}
            if table.name in {"I2C", "SPI", "UART"}:
                paths[name] = values.get("path", "")
            elif table.name == "HTTP":
                paths[name] = values.get("base", "")
            if table.name not in {"Alias", "Vars", "Daemon"}:
                safe_ident(table.name)
                self._module(table.name + ".lua")
            if table.name == "Daemon":
                from .daemon import validate_config
                config = validate_config({k: v for k, v in values.items() if v != "-"})
                self._module(config["chunk"])
                if "driver" in config:
                    self._module(config["driver"] + ".lua")
                for device in config.get("devices", "").split("|"):
                    if device:
                        self._module(device.split("@", 1)[0] + ".lua")
            if table.name == "Alias" and "alias" not in values:
                raise ScriptError("Alias matrix has no 'alias' column")
            if table.name == "Vars":
                if "value" not in values:
                    raise ScriptError("Vars matrix has no 'value' column")
                Number(name, values["value"], self.registry.resolve_number,
                       precision=self._precision(table, row, name))
            seen = {"controller": set(), "trigger": set()}
            for col, value in values.items():
                flow = FLOW.fullmatch(col)
                if flow and value != "-":
                    kind = flow.group(1)
                    if value in seen[kind]:
                        raise ScriptError(f"'{name}' declares {kind} '{value}' more than once")
                    if value not in earlier:
                        raise ScriptError(f"{kind} '{value}' must be defined before '{name}'")
                    if rows[value][0].name in {"Alias", "Vars"}:
                        raise ScriptError(f"Scalar '{value}' cannot be a {kind} target")
                    if kind == "trigger" and (value in {"mode", "result", "message"} or value in values):
                        raise ScriptError(f"Trigger name '{value}' collides with metadata")
                    seen[kind].add(value)
                elif col != "name" and not flow and table.name not in {"Alias", "Vars"}:
                    body = expr_body(value)
                    refs = Expression(body).identifiers if body is not None else ({value[1:]} if value.startswith("$") else set())
                    for target in refs:
                        if target not in rows:
                            raise ScriptError(f"'{name}' references undefined variable '{target}'")
            if table.name == "Daemon" and values.get("sources", "-") != "-":
                for source in re.split(r"[,|]", values["sources"]):
                    source = source.strip()
                    if source not in earlier or rows[source][0].name != "Daemon":
                        raise ScriptError(f"Daemon source '{source}' must name a previously declared daemon")
            proto = values.get("proto", "")
            path = values.get("path", "")
            if proto != "virt" and path and (table.name == "UART" or (table.name == "Daemon" and proto == "uart")):
                if path in uart_paths:
                    raise ScriptError(f"UART path '{path}' has multiple independent consumers: {uart_paths[path]}, {name}")
                uart_paths[path] = name
            consumers = []
            if table.name not in {"Alias", "Vars", "Daemon"}:
                bus = next((values[c][1:] for c in ("I2C", "SPI", "UART", "HTTP") if values.get(c, "").startswith("$")), None)
                if bus:
                    consumers.append((table.name, paths.get(bus, bus), values.get("address", ""), name))
            elif table.name == "Daemon" and proto != "virt" and values.get("sources", "-") == "-":
                if values.get("driver", "-") != "-":
                    consumers.append((values["driver"], path, values.get("addr", ""), name))
                for index, device in enumerate(config.get("devices", "").split("|")):
                    if device:
                        driver, address, *_ = device.split("@")
                        consumers.append((driver, path, address, f"{name}[{index}]"))
            for driver, bus_path, address, consumer in consumers:
                source = self._module(driver + ".lua").read_text(encoding="utf-8")
                if not re.search(r"^[ \t]*SINGLE_CONSUMER\b", source, re.MULTILINE):
                    continue
                try:
                    address = str(int(address, 16 if address.lower().startswith("0x") else 10))
                except ValueError:
                    pass
                key = (bus_path, address)
                if key in claims:
                    raise ScriptError(f"Single-consumer conflict: '{consumer}' and '{claims[key]}'")
                claims[key] = consumer
            earlier.add(name)
        return rows

    @staticmethod
    def _precision(table, row, name):
        if "precision" not in table.header:
            return None
        raw = table.inherited(row, table.header.index("precision"))
        if raw.strip() in {"-", ""}:
            return None
        try:
            value = int(raw)
        except ValueError:
            raise ScriptError(f"@Vars '{name}' precision must be an integer from 0 to 15") from None
        if not 0 <= value <= 15:
            raise ScriptError(f"@Vars '{name}' precision must be an integer from 0 to 15")
        return value

    def _new_runtime(self, **kwargs):
        from .runtime import LuaState
        return LuaState(self.module_paths, self.hal, self.stop_event, allow_hardware=self.allow_hardware, **kwargs)

    def _assemble(self, rows, names):
        created = []
        for name, (table, row) in rows.items():
            if name not in names:
                continue
            values = {col: table.inherited(row, j) for j, col in enumerate(table.header)}
            if table.name == "Alias":
                var = Alias(name, values["alias"])
            elif table.name == "Vars":
                var = Number(name, values["value"], self.registry.resolve_number,
                             precision=self._precision(table, row, name))
            elif table.name == "Daemon":
                from .daemon import DaemonVariable
                var = DaemonVariable(name, {k: v for k, v in values.items() if v != "-"}, self.registry, self._new_runtime, self.stop_event)
            else:
                meta = Metadata(table, row, self.registry)
                controllers, triggers = [], []
                for col, value in values.items():
                    flow = FLOW.fullmatch(col)
                    if flow and value != "-":
                        (controllers if flow.group(1) == "controller" else triggers).append(self.registry.require(value))
                        self.registry.flow_refs.add(value)
                var = LuaVariable(name, self._module(table.name + ".lua"), meta, controllers, triggers, self._new_runtime)
                self._metas[name] = meta
            self.registry.add(var)
            created.append(name)
        for name in created:
            if name in self._metas:
                self._metas[name].seed()
        return created

    def active(self):
        with self._lock:
            if self.state in {"Active", "Deactivating"}:
                raise ScriptError(f"Cannot activate robot in state {self.state}")
            rows = self._validate(self.tables)
            if self.state == "Inactive":
                if any(var.kind == "daemon" and not var._done.is_set() for var in self.registry.values()):
                    raise DriverError("Cannot reactivate while a daemon worker is still exiting")
                from .hal import HALManager
                self.hal = HALManager(camera_src_root=self.camera_src_root)
            self.registry = Registry()
            self._metas = {}
            self.state = "Active"
            try:
                self._assemble(rows, set(rows))
                for var in self.registry.values():
                    Budget(self.stop_event).check()
                    var.build()
            except BaseException:
                self.deactivate()
                raise
        return self

    def deactivate(self):
        with self._lock:
            if self.state in {"Loaded", "Inactive"}:
                return
            self.state = "Deactivating"
            variables = list(self.registry.values())
            daemons = [var for var in reversed(variables) if var.kind == "daemon"]
            deadline = time.monotonic() + self.deactivate_grace_ms / 1000
            for var in daemons:
                var.request_stop(deadline)
            failures = []
            for var in daemons + [var for var in reversed(variables) if var.kind != "daemon"]:
                try:
                    var.destroy()
                except Exception as exc:
                    failures.append(str(exc))
            self.hal.close()
            self.state = "Inactive"
            if failures:
                print("Deactivate warnings: " + "; ".join(failures), file=sys.stderr)

    def __enter__(self):
        return self.active()

    def __exit__(self, *exc):
        self.deactivate()

    def inject_driver(self, table, name):
        if self.state != "Loaded":
            raise ScriptError("Drivers must be injected before activation")
        safe_ident(table)
        safe_ident(name)
        if name in self._rows(self.tables):
            return
        if table in self.tables:
            target = self.tables[table]
            target.rows.append([name if col == "name" else "-" for col in target.header])
        else:
            self.tables[table] = Matrix(table, [["name"], [name]])

    def run(self, script_text, *, base_dir=".", vars=None, timeout=180, cancel=None):
        with self._lock:
            if self.state != "Active":
                raise ScriptError("Robot is not active")
            matrices = expand_includes(parse_matrices(check_script(script_text)), Path(base_dir))
            budget = Budget(self.stop_event, timeout, cancel)
            with self.registry.session():
                declared = set()
                for matrix in matrices:
                    name = struct_name(matrix.name)
                    if name is not None:
                        if name in declared or name in self.registry:
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
                        name = matrix.rows[i][matrix.header.index("name")]
                        if name in declared:
                            raise ScriptError(f"Duplicate session variable '{name}'")
                        declared.add(name)
                        if matrix.name == "Vars" and name in self.registry:
                            raise ScriptError(f"@Vars '{name}' cannot override a structure variable")
                        value = matrix.inherited(i, matrix.header.index(field))
                        if matrix.name == "Alias":
                            var = Alias(name, value)
                        else:
                            precision = None
                            if "precision" in matrix.header:
                                raw = matrix.inherited(i, matrix.header.index("precision"))
                                if raw.strip() not in {"-", ""}:
                                    try:
                                        precision = int(raw)
                                    except ValueError:
                                        raise ScriptError(
                                            f"@Vars '{name}' precision must be an integer from 0 to 15") from None
                                    if not 0 <= precision <= 15:
                                        raise ScriptError(
                                            f"@Vars '{name}' precision must be an integer from 0 to 15")
                            var = Number(name, value, self.registry.resolve_number, precision=precision)
                        self.registry.override(name, var)
                for name, value in (vars or {}).items():
                    self.registry.override(name, Alias(name, value))
                lua_vars = [var for var in self.registry.values() if var.kind == "lua"]
                for var in lua_vars:
                    var.budget = budget
                try:
                    return ActionRunner(self.registry, budget).run(matrices)
                finally:
                    for var in lua_vars:
                        var.budget = None

    def query_sql(self, sql):
        statements = parse_sql(check_script(sql))
        if any(stmt.kind not in {"SELECT", "SHOW"} for stmt in statements):
            raise ScriptError("query_sql accepts only SELECT * and SHOW TABLES")
        output = []
        for stmt in statements:
            if stmt.kind == "SHOW":
                output.append(f"SHOW TABLES ({len(self.tables)}):")
                output.extend(f"  {name} ({len(table.rows) - 1} 行)" for name, table in self.tables.items())
                continue
            if stmt.table not in self.tables:
                raise ScriptError(f"Table '{stmt.table}' is not defined")
            table = self.tables[stmt.table]
            for column, value in stmt.where:
                if column not in table.header:
                    raise ScriptError(f"Table '{stmt.table}' has no '{column}' column")
            output.append("\t".join(table.header))
            count = 0
            for i in range(1, len(table.rows)):
                if all(table.inherited(i, table.header.index(c)) == v for c, v in stmt.where):
                    output.append("\t".join(table.inherited(i, j) for j in range(len(table.header))))
                    count += 1
            if not count:
                output.append("（0 行匹配）")
        return "\n".join(output)

    @staticmethod
    def _references(table, row):
        refs = set()
        for j, col in enumerate(table.header):
            if col == "name":
                continue
            value = table.inherited(row, j)
            if FLOW.fullmatch(col) and value != "-":
                refs.add(value)
            elif table.name == "Daemon" and col == "sources" and value != "-":
                refs.update(s.strip() for s in re.split(r"[,|]", value))
            elif value.startswith("$"):
                body = expr_body(value)
                refs.update(Expression(body).identifiers if body is not None else [value[1:]])
        return refs

    def _remove_variables(self, names, budget):
        removed = []
        rows = self._rows(self.tables)
        dependents = {name: set() for name in names}
        for name in names:
            for target in self._references(*rows[name]) & names:
                dependents[target].add(name)
        deadline = time.monotonic() + self.deactivate_grace_ms / 1000
        for name in names:
            budget.check()
            var = self.registry.require(name)
            if var.kind == "daemon":
                var.request_stop(deadline)
        order = [name for name in reversed(list(self.registry)) if name in names]
        pending = set(names)
        while pending:
            budget.check()
            ready = next((name for name in order if name in pending and not dependents[name] & pending), None)
            # Cyclic dependencies must finish teardown together before cancellation.
            batch = [ready] if ready is not None else [name for name in order if name in pending]
            for name in batch:
                var = self.registry.require(name)
                failure = None
                try:
                    var.destroy()
                except Exception as exc:
                    failure = exc
                self.registry.remove(name)
                self._metas.pop(name, None)
                removed.append(name)
                pending.remove(name)
                for table in self.tables.values():
                    if "name" in table.header:
                        index = table.header.index("name")
                        table.rows[1:] = [[table.inherited(i, j) for j in range(len(table.header))]
                                          for i in range(1, len(table.rows)) if table.rows[i][index] != name]
                self._refresh_flow_refs()
                if failure is not None:
                    raise DriverError(f"Hot deletion failed at '{name}'; removed {removed}: {failure}") from failure
        return removed

    def _refresh_flow_refs(self):
        self.registry.flow_refs = {target.name for var in self.registry.values() if var.kind == "lua" for target in var.controllers + var.triggers}

    def apply_sql(self, sql, *, cancel=None):
        with self._lock:
            if self.state != "Active":
                raise ScriptError("Hot SQL requires an active robot")
            budget = Budget(self.stop_event, cancel=cancel)
            budget.check()
            statements = parse_sql(check_script(sql))
            candidate = copy.deepcopy(self.tables)
            old_rows = self._rows(self.tables)
            old_config = {name: (table.name, {col: table.inherited(row, j) for j, col in enumerate(table.header)})
                          for name, (table, row) in old_rows.items()}
            updates, deleted = set(), set()
            for stmt in statements:
                if stmt.kind in {"SELECT", "SHOW"}:
                    raise ScriptError("apply_sql does not accept read-only statements")
                previous = []
                if stmt.kind in {"UPDATE", "DELETE", "DROP"} and stmt.table in candidate and stmt.table != "Action":
                    table = candidate[stmt.table]
                    if "name" in table.header:
                        previous = [{col: table.inherited(row, j) for j, col in enumerate(table.header)}
                                    for row in range(1, len(table.rows))]
                apply_statement(candidate, stmt, allow_mutations=True)
                for values in previous:
                    if all(values[c] == v for c, v in stmt.where):
                        name = values["name"]
                        if stmt.kind == "UPDATE":
                            updates.add(name)
                        elif old_config.get(name) == (stmt.table, values):
                            deleted.add(name)
            new_rows = self._validate(candidate)
            updates |= deleted & new_rows.keys()
            updates &= old_rows.keys()
            for name in old_rows.keys() & new_rows.keys():
                table, row = new_rows[name]
                values = {col: table.inherited(row, j) for j, col in enumerate(table.header)}
                if old_config[name] != (table.name, values):
                    updates.add(name)
            removed = (old_rows.keys() - new_rows.keys()) | updates
            added = (new_rows.keys() - old_rows.keys()) | (updates & new_rows.keys())
            for name, (table, row) in new_rows.items():
                overlap = self._references(table, row) & removed
                if overlap:
                    raise ScriptError(f"Cannot delete/update {sorted(overlap)}: still referenced by '{name}'")
            budget.check()
            delete_first = bool(updates)
            if delete_first:
                self._remove_variables(removed, budget)
            before = set(self.registry)
            try:
                budget.check()
                self._assemble(new_rows, added)
                for name in self.registry:
                    if name not in before:
                        budget.check()
                        self.registry.require(name).build()
                budget.check()
                action = candidate.get("Action")
                if action and len(action.rows) > 1:
                    action_budget = Budget(self.stop_event, 180, cancel)
                    lua_vars = [var for var in self.registry.values() if var.kind == "lua"]
                    for var in lua_vars:
                        var.budget = action_budget
                    try:
                        with self.registry.session():
                            ActionRunner(self.registry, action_budget).dispatch(action)
                    finally:
                        for var in lua_vars:
                            var.budget = None
                if not delete_first:
                    self._remove_variables(removed, budget)
                budget.check()
            except BaseException as exc:
                for name in reversed(list(self.registry)):
                    if name not in before:
                        try:
                            self.registry.require(name).destroy()
                        except Exception as cleanup_error:
                            print(f"Rollback warning: {cleanup_error}", file=sys.stderr)
                        self.registry.remove(name)
                        self._metas.pop(name, None)
                self._refresh_flow_refs()
                if delete_first:
                    raise DriverError(f"Hot update failed; old variables {sorted(removed)} remain deactivated: {exc}") from exc
                raise
            if "Action" in candidate:
                candidate["Action"].rows[1:] = []
            self.tables = candidate
            self._refresh_flow_refs()
            return f"已生效：新增 {len(added)} 个变量，删除 {len(removed)} 个变量，热更新 {len(updates)} 行（断电重建）"
