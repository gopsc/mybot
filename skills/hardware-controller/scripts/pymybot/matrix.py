"""The .mt character grammar and its ordered matrix/block representation."""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import math
import re

from .errors import ScriptError

MAX_BLOCK_DEPTH = 32
MAX_SCRIPT_BYTES = 8 * 1024 * 1024
_STRUCT = re.compile(r"Struct\(([A-Za-z_][A-Za-z_0-9]*)\)\Z")
_REFLEX = re.compile(r"Reflex\(([A-Za-z_][A-Za-z_0-9-]*)\)\Z")
_STRUCT_END = re.compile(r"@[ \t]*(?:#[^\n]*)?(?=\n|$)")


def reflex_name(name: str) -> str | None:
    if name == "Reflex" or name.startswith("Reflex("):
        match = _REFLEX.fullmatch(name)
        if match is None:
            raise ScriptError("Expected @Reflex(identifier) without whitespace")
        return match[1]
    return None


def struct_name(name: str) -> str | None:
    if name == "Struct" or name.startswith("Struct("):
        match = _STRUCT.fullmatch(name)
        if match is None:
            raise ScriptError("Expected @Struct(identifier) without whitespace")
        return match[1]
    return None


def struct_json(value) -> str:
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if depth > MAX_BLOCK_DEPTH:
            raise ScriptError("Struct JSON exceeds maximum nesting depth")
        if isinstance(item, dict):
            if not all(isinstance(key, str) for key in item):
                raise ScriptError("Struct JSON object keys must be strings")
            pending.extend((key, depth + 1) for key in item)
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
        elif isinstance(item, str):
            try:
                item.encode("utf-8")
            except UnicodeError:
                raise ScriptError("Struct JSON strings must be valid UTF-8") from None
        elif type(item) in {int, float}:
            try:
                finite = math.isfinite(item)
            except OverflowError:
                finite = False
            if not finite:
                raise ScriptError("Struct JSON numbers must be finite")
        elif item is not None and type(item) is not bool:
            raise ScriptError("Struct values must be JSON-compatible")
    encoded = json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
    if len(encoded) > MAX_SCRIPT_BYTES:
        raise ScriptError("Struct JSON exceeds the byte limit")
    return encoded


def parse_struct_json(text: str) -> str:
    def constant(_):
        raise ScriptError("Struct JSON does not accept NaN or Infinity")

    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ScriptError("Struct JSON has duplicate object keys")
            result[key] = value
        return result

    try:
        value = json.loads(text, parse_constant=constant, object_pairs_hook=object_pairs)
    except (ValueError, RecursionError) as exc:
        raise ScriptError("Invalid Struct JSON") from exc
    return struct_json(value)


def is_control(name: str) -> bool:
    name = name.strip()
    return name in {"if", "while"} or name.startswith(("if(", "while("))


@dataclass
class Matrix:
    name: str
    rows: list[list[str]] = field(default_factory=list)
    children: list[Matrix] = field(default_factory=list)
    json_text: str | None = None

    def __post_init__(self) -> None:
        if self.rows and any(len(row) != len(self.rows[0]) for row in self.rows):
            raise ScriptError(f"@{self.name}: every row must match the header column count")

    @property
    def header(self) -> list[str]:
        return self.rows[0] if self.rows else []

    @property
    def data(self) -> list[list[str]]:
        return self.rows[1:]

    def inherited(self, row: int, col: int) -> str:
        if row < 0 or col < 0 or row >= len(self.rows) or col >= len(self.rows[row]):
            raise ScriptError(f"Matrix access out of bounds: row={row} col={col}")
        # Rows are public and may be edited by hot SQL; do not cache stale values.
        while row > 1 and self.rows[row][col] == "-":
            row -= 1
        return self.rows[row][col]

    def require_col(self, name: str) -> int:
        try:
            return self.header.index(name)
        except ValueError:
            raise ScriptError(f"@{self.name} has no '{name}' column") from None


def split_action_column(text: str) -> tuple[str, str]:
    depth, quoted, escaped = 0, False, False
    separators = []
    for index, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"' and depth:
            quoted = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "." and depth == 0:
            separators.append(index)
    if depth or quoted or len(separators) != 1:
        raise ScriptError(f"Action column {text[:160]!r}: expected <device>.<param>")
    index = separators[0]
    device, param = text[:index], text[index + 1:]
    if not device or not param:
        raise ScriptError("Action column requires a nonempty device and parameter")
    return device, param


@dataclass
class _Frame:
    matrix: Matrix
    pending: list[list[str]] = field(default_factory=list)
    cells: list[str] = field(default_factory=list)
    token: list[str] = field(default_factory=list)
    json_chars: list[str] = field(default_factory=list)
    json_header_line: int = 0

    def item(self) -> None:
        if self.token:
            self.cells.append("".join(self.token))
            self.token.clear()

    def line(self, line: int) -> None:
        self.item()
        if not self.cells:
            return
        compound = is_control(self.matrix.name) or reflex_name(self.matrix.name) is not None or self.matrix.children
        rows = self.pending if compound else self.matrix.rows
        if rows and len(rows[0]) != len(self.cells):
            raise ScriptError(f"Matrix line {line}: got {len(self.cells)} cells, expected "
                              f"{len(rows[0])} (header column count)")
        rows.append(self.cells)
        self.cells = []

    def flush(self) -> None:
        if self.cells or self.token:
            raise ScriptError("Data row must end with ';' before an @ block boundary")
        if self.pending:
            self.matrix.children.append(Matrix("Action", self.pending))
            self.pending = []


def parse_matrices(text: str) -> list[Matrix]:
    """Parse all top-level blocks; whitespace never quotes an expression cell."""
    if len(text.encode("utf-8")) > MAX_SCRIPT_BYTES:
        raise ScriptError(f"Script exceeds the {MAX_SCRIPT_BYTES} byte limit")
    # CRLF and LF have identical semantics on every host.
    text = text.replace("\r\n", "\n")
    stack: list[_Frame] = []
    out: list[Matrix] = []
    scratch = _Frame(Matrix(""))
    header: list[str] = []
    line = 1
    at_start, comment, naming = True, False, False

    def builder() -> _Frame:
        return stack[-1] if stack else scratch

    def commit_header() -> None:
        name = "".join(header)
        header.clear()
        if not name:
            if not stack:
                raise ScriptError(f"Line {line}: extra '@', no block to close")
            frame = stack.pop()
            frame.flush()
            (stack[-1].matrix.children if stack else out).append(frame.matrix)
        else:
            if name == "Trigger" or name.startswith("Trigger("):
                raise ScriptError("@Trigger is not supported; call @Reflex(name) from @Action")
            if reflex_name(name) is not None and stack:
                raise ScriptError("@Reflex definitions may only appear at the top level")
            if struct_name(name) is not None:
                if stack:
                    raise ScriptError("@Struct declarations may only appear at the top level")
                stack.append(_Frame(Matrix(name, json_text=""), json_header_line=line))
                return
            if stack:
                parent = stack[-1]
                if not (parent.matrix.name == "Action" or is_control(parent.matrix.name)
                        or reflex_name(parent.matrix.name) is not None):
                    raise ScriptError(f"Line {line}: leaf @{parent.matrix.name} "
                                      f"cannot contain nested @{name[:160]}")
                if name in {"Alias", "Vars"} and reflex_name(parent.matrix.name) is None:
                    raise ScriptError(f"@{name} declarations require the top level or a Reflex body")
                if parent.matrix.name == "Action" and parent.matrix.rows:
                    parent.pending, parent.matrix.rows = parent.matrix.rows, []
                parent.flush()
            if len(stack) >= MAX_BLOCK_DEPTH:
                raise ScriptError(f"Block nesting depth exceeds {MAX_BLOCK_DEPTH}")
            stack.append(_Frame(Matrix(name)))

    line_prefix = True
    for index, char in enumerate(text):
        at_line_prefix = line_prefix
        if char == "\n":
            line_prefix = True
        elif char not in " \t\r":
            line_prefix = False
        if stack and stack[-1].matrix.json_text is not None and not naming and not comment:
            frame = stack[-1]
            if line == frame.json_header_line:
                if char == "#":
                    comment = True
                elif char == "\n":
                    line += 1
                elif char not in " \t\r":
                    raise ScriptError("Struct JSON must start on the line after its declaration")
                continue
            if char == "@" and at_line_prefix and _STRUCT_END.match(text, index):
                frame.matrix.json_text = parse_struct_json("".join(frame.json_chars))
                out.append(stack.pop().matrix)
                at_start = True
            else:
                frame.json_chars.append(char)
                if char == "\n":
                    line += 1
            continue
        if not comment and char == "#":
            comment = True
            if naming:
                commit_header()
                naming = False
            else:
                builder().item()
        elif comment:
            if char == "\n":
                at_start, comment = True, False
                line += 1
        elif at_start and char in " \t\r":
            continue
        elif at_start and char == "\n":
            line += 1
        elif at_start and char == "@":
            at_start, naming = False, True
            header.clear()
        elif at_start:
            at_start = False
            if char == ";":
                builder().line(line)
                at_start = True
            else:
                builder().token.append(char)
        elif naming and char in " \t\r\n":
            commit_header()
            naming, at_start = False, True
            if char == "\n":
                line += 1
        elif naming:
            header.append(char)
        elif char in " \t\r\n":
            builder().item()
            if char == "\n":
                line += 1
        elif char == ";":
            builder().line(line)
            at_start = True
        else:
            builder().token.append(char)
    if naming:
        commit_header()
    if stack:
        raise ScriptError(f"EOF at line {line}: unclosed block @{stack[-1].matrix.name[:160]}")
    return out
