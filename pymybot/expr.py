"""Bounded .mt expression parser, with no Python code evaluation."""
from __future__ import annotations

from contextlib import contextmanager
import math
import re
import threading
from collections.abc import Callable

from .errors import ScriptError

Value = float | str | bool
ResolvedValue = Value | int | dict[str, "ResolvedValue"] | list["ResolvedValue"] | None
MAX_EVAL_STEPS = 100_000
_eval_state = threading.local()


@contextmanager
def evaluation_guard(check, steps=None):
    """Bound nested expression work and run the caller's budget check per step."""
    previous = getattr(_eval_state, "state", None)
    _eval_state.state = [MAX_EVAL_STEPS if steps is None else steps, check]
    try:
        yield
    finally:
        _eval_state.state = previous


def _evaluation_step():
    state = getattr(_eval_state, "state", None)
    if state is None:
        return
    if state[0] <= 0:
        raise ScriptError("Expression evaluation exceeded the step budget")
    state[0] -= 1
    if state[1] is not None:
        state[1]()
_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_DECIMAL = re.compile(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_HEX = re.compile(r"[+-]?0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?")
_PRECEDENCE = {"||": 1, "&&": 2, "<": 3, ">": 3, "<=": 3, ">=": 3,
               "==": 3, "!=": 3, "+": 4, "-": 4, "*": 5, "/": 5, "%": 5}


def expr_body(text: str) -> str | None:
    return text[2:-1] if text.startswith("$(") and text.endswith(")") else None


def render(value: Value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if not isinstance(value, (float, int)):
        raise ScriptError("Only string/number/bool values can be rendered")
    try:
        number = float(value)
    except OverflowError:
        raise ScriptError("expression evaluates to a non-finite value") from None
    if not math.isfinite(number):
        raise ScriptError("expression evaluates to a non-finite value")
    return format(number, ".15g")


def parse_number(text: str) -> float:
    """Strict finite strtod-like literals for matrix cells (not expressions)."""
    raw = text.lstrip(" \t\r\n\v\f")
    decimal = raw[1:] if raw.startswith(("+", "-")) else raw
    try:
        if _DECIMAL.fullmatch(decimal):
            value = float(raw)
        elif _HEX.fullmatch(raw):
            value = float.fromhex(raw)
        else:
            raise ScriptError(f"Cannot parse matrix cell {text[:160]!r} as Float64")
    except (ValueError, OverflowError):
        raise ScriptError(f"Invalid or non-finite numeric literal {text[:160]!r}") from None
    if not math.isfinite(value):
        raise ScriptError("Numeric literal is non-finite")
    return value


def _kind(value: ResolvedValue) -> str:
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "text"
    if isinstance(value, (float, int)):
        return "number"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return "null" if value is None else "non-JSON value"


def _finite_number(value: float | int) -> float:
    render(value)  # Check finiteness and catch overflowing JSON integers.
    return float(value)


def _checked_value(value: ResolvedValue) -> ResolvedValue:
    if isinstance(value, bool):
        return value
    if isinstance(value, (float, int)):
        return _finite_number(value)
    if value is None or isinstance(value, (str, dict, list)):
        return value
    raise ScriptError("expression identifier or member did not resolve to a JSON value")


def _scalar(value: ResolvedValue) -> Value:
    if isinstance(value, (str, bool)):
        return value
    if isinstance(value, (float, int)):
        return _finite_number(value)
    raise ScriptError(f"expression must evaluate to a scalar string/number/bool, not {_kind(value)}")


def _array_index(value: ResolvedValue) -> int:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ScriptError("array index must be a finite nonnegative integral number (not bool or text)")
    number = _finite_number(value)
    if number < 0 or not number.is_integer():
        raise ScriptError("array index must be a finite nonnegative integral number")
    return int(number)


def select_member(value: ResolvedValue, key: str | int) -> ResolvedValue:
    """Read only JSON dict fields or zero-based list elements, never attributes."""
    if isinstance(key, str):
        if not isinstance(value, dict):
            raise ScriptError(f"field selection requires an object, not {_kind(value)}")
        if key not in value:
            raise ScriptError(f"object has no field {key[:120]!r}")
        return value[key]
    if type(key) is not int:
        raise ScriptError("array index must be an integer (not bool)")
    if not isinstance(value, list):
        raise ScriptError(f"array index requires an array, not {_kind(value)}")
    if key < 0 or key >= len(value):
        raise ScriptError("array index out of bounds")
    return value[key]


def _numeric(value: ResolvedValue, op: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ScriptError(f"expression operator '{op}' cannot be applied to a {_kind(value)} operand")
    return _finite_number(value)


def _logical(value: ResolvedValue, op: str) -> bool:
    if not isinstance(value, bool):
        raise ScriptError(f"expression operator '{op}' requires logical operands; "
                          "no implicit true/false conversion")
    return value


def _binary(op: str, a: ResolvedValue, b: ResolvedValue) -> Value:
    a, b = _scalar(a), _scalar(b)
    if op == "+" and (isinstance(a, str) or isinstance(b, str)):
        if isinstance(a, bool) or isinstance(b, bool):
            raise ScriptError("expression '+' cannot be applied to a boolean operand")
        return render(a) + render(b)
    if op in {"==", "!="}:
        if _kind(a) != _kind(b):
            raise ScriptError(f"expression '{op}' cannot compare a {_kind(a)} with a {_kind(b)}")
        if _kind(a) == "number":
            render(a)
            render(b)
        equal = a == b
        return equal if op == "==" else not equal
    x, y = _numeric(a, op), _numeric(b, op)
    if op in {"<", ">", "<=", ">="}:
        render(x)
        render(y)
        if op == "<":
            return x < y
        if op == ">":
            return x > y
        if op == "<=":
            return x <= y
        return x >= y
    if op == "+":
        return x + y
    if op == "-":
        return x - y
    if op == "*":
        return x * y
    if y == 0:
        raise ScriptError("expression division by zero" if op == "/" else "expression modulo by zero")
    if op == "/":
        return x / y
    try:
        return math.fmod(x, y)  # fmod remainder, not Python's floor modulo.
    except ValueError:
        raise ScriptError("expression evaluates to a non-finite value") from None


class _Parser:
    def __init__(self, text: str):
        self.text, self.pos, self.depth, self.ops = text, 0, 0, 0
        self.identifiers: set[str] = set()

    def fail(self, message: str) -> None:
        excerpt = repr(self.text[:120]) + ("..." if len(self.text) > 120 else "")
        raise ScriptError(f"invalid expression {excerpt}: {message} at position {self.pos}")

    def whitespace(self) -> None:
        while self.pos < len(self.text) and self.text[self.pos] in " \t\r\n":
            self.pos += 1

    def peek(self) -> str:
        return self.text[self.pos:self.pos + 1]

    def operator(self) -> None:
        # Selectors share the arithmetic operator budget.
        self.ops += 1
        if self.ops > 512:
            self.fail("too many operators in one expression")

    def open_group(self) -> None:
        self.depth += 1
        if self.depth > 128:
            self.fail("expression nesting too deep")
        self.pos += 1

    def selector(self, op, node, key):
        # Parenthesizing part of a chain must not bypass its access limit.
        depth, base = 1, node
        while base[0] in {"field", "index"}:
            depth += 1
            if depth > 128:
                self.fail("expression access depth too deep")
            base = base[1]
        return (op, node, key)

    def parse(self, reference: bool = False):
        # Explicit Pratt-parser frames avoid Python recursion for both groups
        # and nested index expressions, even when combined with binary trees.
        todo = [("primary", True)] if reference else [("expression", 1)]
        nodes = []
        while todo:
            frame = todo.pop()
            stage = frame[0]
            self.whitespace()
            if stage == "expression":
                todo.extend([("binary", frame[1]), ("primary", False)])
            elif stage == "binary":
                op = self.text[self.pos:self.pos + 2]
                if op not in _PRECEDENCE:
                    op = self.peek()
                if op == "=":
                    self.fail("single '=' is not an operator; equality is '=='")
                priority = _PRECEDENCE.get(op, 0)
                if priority >= frame[1]:
                    self.pos += len(op)
                    self.operator()
                    todo.extend([("combine", op, nodes.pop(), frame[1]),
                                 ("expression", priority + 1)])
            elif stage == "combine":
                nodes.append((frame[1], frame[2], nodes.pop()))
                todo.append(("binary", frame[3]))
            elif stage == "close":
                if self.peek() != frame[1]:
                    self.fail(f"expected {frame[1]!r}")
                self.pos += 1
                self.depth -= 1
            elif stage == "index":
                nodes.append(self.selector("index", frame[1], nodes.pop()))
            elif stage == "postfix":
                c = self.peek()
                if c == ".":
                    self.pos += 1
                    self.operator()
                    self.whitespace()
                    match = _IDENT.match(self.text, self.pos)
                    if not match:
                        self.fail("expected field identifier after '.'")
                    self.pos = match.end()
                    nodes.append(self.selector("field", nodes.pop(), match.group()))
                    todo.append(frame)
                elif c == "[":
                    self.operator()
                    self.open_group()
                    todo.extend([frame, ("index", nodes.pop()), ("close", "]"),
                                 ("expression", 1)])
                else:
                    node = nodes.pop()
                    if frame[1]:
                        node = ("negate", node)
                    if frame[2]:
                        node = ("not", node)
                    nodes.append(node)
            else:  # primary
                # Keep the source grammar's unary-run parity and ordering.
                # Reference roots deliberately do not accept any unary signs.
                negative, nots = False, False
                if not frame[1]:
                    while True:
                        self.whitespace()
                        c = self.peek()
                        if c == "+":
                            self.pos += 1
                        elif c == "-":
                            negative = not negative
                            self.pos += 1
                        elif c == "!" and self.text[self.pos:self.pos + 2] != "!=":
                            nots = not nots
                            self.pos += 1
                        else:
                            break
                c = self.peek()
                if frame[1]:
                    match = _IDENT.match(self.text, self.pos)
                    if not match:
                        self.fail("reference must start with an identifier")
                    self.pos = match.end()
                    self.identifiers.add(match.group())
                    nodes.append(("variable", match.group()))
                elif not c:
                    self.fail("unexpected end of expression")
                elif c == "(":
                    self.open_group()
                    todo.extend([("postfix", negative, nots), ("close", ")"),
                                 ("expression", 1)])
                    continue
                elif c == '"':
                    nodes.append(("literal", self.string()))
                elif match := _DECIMAL.match(self.text, self.pos):
                    self.pos = match.end()
                    value = float(match.group())
                    if not math.isfinite(value):
                        self.fail("invalid numeric literal (non-finite)")
                    nodes.append(("literal", value))
                elif match := _IDENT.match(self.text, self.pos):
                    # A hyphen is subtraction, never part of an identifier.
                    self.pos = match.end()
                    self.identifiers.add(match.group())
                    nodes.append(("variable", match.group()))
                else:
                    self.fail(f"unexpected character {c!r}")
                todo.append(("postfix", negative, nots))
        return nodes.pop()

    def string(self) -> str:
        self.pos += 1
        chars: list[str] = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}
        while self.pos < len(self.text):
            c = self.text[self.pos]
            self.pos += 1
            if c == '"':
                return "".join(chars)
            if c == "\\":
                if self.pos >= len(self.text):
                    break
                c = self.text[self.pos]
                self.pos += 1
                if c not in escapes:
                    self.fail(f"unknown escape sequence {chr(92) + c!r}")
                c = escapes[c]
            chars.append(c)
        self.fail("unterminated string literal")
        return ""  # fail always raises


class Expression:
    def __init__(self, body: str):
        self.body = body
        parser = _Parser(body)
        parser.whitespace()
        if parser.pos == len(body):
            parser.fail("empty expression")
        self._root = parser.parse()
        parser.whitespace()
        if parser.pos != len(body):
            parser.fail("unexpected trailing input")
        self.identifiers = parser.identifiers

    def evaluate(self, resolve: Callable[[str], ResolvedValue]) -> Value:
        return _scalar(_evaluate(self._root, resolve))


class Reference:
    """An identifier and selectors, suitable for a capture assignment target."""

    def __init__(self, text: str):
        parser = _Parser(text)
        node = parser.parse(reference=True)
        parser.whitespace()
        if parser.pos != len(text):
            parser.fail("unexpected trailing input in reference")
        selectors = []
        while node[0] in {"field", "index"}:
            selectors.append((node[0], node[2]))
            node = node[1]
        self.name = node[1]
        self._selectors = tuple(reversed(selectors))

    def resolve_path(self, resolve: Callable[[str], ResolvedValue]) -> tuple[str | int, ...]:
        """Freeze indices before device I/O; target existence is checked on assignment."""
        return tuple(key if op == "field" else _array_index(_evaluate(key, resolve))
                     for op, key in self._selectors)


def _evaluate(root, resolve: Callable[[str], ResolvedValue]) -> ResolvedValue:
    # Explicit evaluation frames also cover selectors and their index trees.
    # Containers/null are traversal values, never arithmetic/logical operands.
    todo = [(root, 0)]
    values: list[ResolvedValue] = []
    while todo:
        _evaluation_step()
        node, phase = todo.pop()
        op = node[0]
        if op == "literal":
            values.append(node[1])
        elif op == "variable":
            values.append(_checked_value(resolve(node[1])))
        elif phase == 0:
            todo.extend([(node, 1), (node[1], 0)])
        elif op == "field":
            values.append(_checked_value(select_member(values.pop(), node[2])))
        elif op in {"negate", "not"}:
            value = values.pop()
            values.append(-_numeric(value, "-") if op == "negate" else not _logical(value, "!"))
        elif phase == 1:
            if op in {"&&", "||"}:
                left = _logical(values[-1], op)
                if (op == "&&" and not left) or (op == "||" and left):
                    continue
            todo.extend([(node, 2), (node[2], 0)])
        else:
            right, left = values.pop(), values.pop()
            if op == "index":
                value = select_member(left, _array_index(right))
            elif op in {"&&", "||"}:
                value = _logical(right, op)
            else:
                value = _binary(op, left, right)
            values.append(_checked_value(value))
    return values.pop()
