"""Strict SQL4cj grammar over sqlparse tokens; all table changes are in memory."""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from sqlparse import keywords, tokens as T
from sqlparse.lexer import Lexer

from .errors import ScriptError
from .expr import Expression, expr_body, parse_number
from .matrix import Matrix

__all__ = ["Statement", "Table", "parse_sql", "load_structure", "apply_statement"]

_KEYWORDS = frozenset("CREATE TABLE STRING NUMBER INSERT INTO VALUES SELECT FROM "
                      "WHERE AND SHOW TABLES DELETE DROP UPDATE SET".split())
_KINDS = frozenset("CREATE INSERT SELECT SHOW DELETE DROP UPDATE".split())
_IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
# Only Action columns use device.param names (including hyphenated devices).
# Table names and ordinary columns must retain the stricter identifier grammar.
_ACTION_COLUMN = re.compile(r"[A-Za-z_][A-Za-z_0-9-]*\.[A-Za-z_][A-Za-z_0-9-]*")
_BARE = re.compile(r"(?:[$]?[A-Za-z_][A-Za-z_0-9.-]*|-)")
_DECIMAL = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_HEX = re.compile(r"[+-]?0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)"
                  r"(?:[pP][+-]?[0-9]+)?")
_MAX_SCRIPT_BYTES = 8 * 1024 * 1024


@dataclass
class Statement:
    kind: str
    table: str = ""
    columns: list[tuple[str, str]] = field(default_factory=list)
    names: list[str] = field(default_factory=list)
    values: list[str] = field(default_factory=list)
    where: list[tuple[str, str]] = field(default_factory=list)
    assignments: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class Table(Matrix):
    column_types: dict[str, str] = field(default_factory=dict)


@dataclass
class _Token:
    text: str
    line: int
    column: int
    quoted: bool = False

    def error(self, message: str) -> ScriptError:
        return ScriptError(f"{message}: token {self.text[:120]!r} "
                           f"(line {self.line}, column {self.column})")


def _tokens(text: str) -> list[_Token]:
    # Use a private sqlparse lexer, not its shared singleton. SQL4cj has doubled
    # quote escapes only: backslashes (including Windows paths) are literal.
    lexer = Lexer()
    lexer.default_initialization()
    quote_rules = {T.String.Single: r"'(?:[^']|'')*'",
                   T.String.Symbol: r'"(?:[^"]|"")*"'}
    lexer.set_SQL_REGEX([(quote_rules.get(kind, pattern), kind)
                         for pattern, kind in keywords.SQL_REGEX])
    result: list[_Token] = []
    fragments: list[str] = []
    start_line = start_column = 1
    line = column = 1
    offset = 0

    def flush() -> None:
        if fragments:
            result.append(_Token("".join(fragments), start_line, start_column))
            fragments.clear()

    for kind, raw in lexer.get_tokens(text):
        token = _Token(raw, line, column)
        if kind in T.Error:
            message = "Unterminated string" if raw in {"'", '"'} else "Invalid SQL character"
            raise token.error(message)
        if text.startswith("/*", offset) and kind not in T.Comment:
            raise token.error("Unterminated block comment")
        if kind in T.Whitespace or kind in T.Comment:
            flush()
            if kind in T.Comment and not raw.startswith(("--", "/*")):
                raise token.error("Only -- and /* */ SQL comments are supported")
        elif kind in (T.String.Single, T.String.Symbol):
            flush()
            quote = raw[0]
            token.text = raw[1:-1].replace(quote * 2, quote)
            token.quoted = True
            result.append(token)
        elif raw in {";", ",", "(", ")", "=", "*"} or kind in T.Operator.Comparison:
            flush()
            result.append(token)
        else:
            # sqlparse splits +2e3, 1e+3, timer-0 and hex floats into pieces.
            # Rejoin only adjacent bare pieces, never across comments/whitespace
            # or structural tokens. The value/name grammar still validates them.
            if not fragments:
                start_line, start_column = line, column
            fragments.append(raw)
        offset += len(raw)
        newlines = raw.count("\n")
        if newlines:
            line += newlines
            column = len(raw.rsplit("\n", 1)[1]) + 1
        else:
            column += len(raw)
    flush()
    return result


class _Parser:
    def __init__(self, tokens: list[_Token]):
        self.tokens = tokens
        self.pos = 0

    def take(self) -> _Token:
        if self.pos == len(self.tokens):
            raise ScriptError("SQL: unexpected end of script (statements must end with ';')")
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def accept(self, text: str) -> bool:
        if self.pos < len(self.tokens):
            token = self.tokens[self.pos]
            if not token.quoted and token.text.upper() == text:
                self.pos += 1
                return True
        return False

    def expect(self, text: str) -> None:
        token = self.take()
        if token.quoted or token.text.upper() != text:
            raise token.error(f"Expected {text}")

    def name(self, *, table: str = "") -> str:
        token = self.take()
        pattern = _ACTION_COLUMN if table == "Action" else _IDENT
        if not pattern.fullmatch(token.text):
            raise token.error("Unsafe or invalid table/column name")
        if not token.quoted and token.text.upper() in _KEYWORDS:
            raise token.error("Reserved name must be quoted")
        return token.text

    def value(self) -> str:
        token = self.take()
        if token.quoted:
            return token.text
        if (token.text.upper() in _KEYWORDS or not
                (_BARE.fullmatch(token.text) or _DECIMAL.fullmatch(token.text)
                 or _HEX.fullmatch(token.text))):
            raise token.error("Expected a literal value (quote text containing punctuation)")
        return token.text

    def paren_list(self, *, names: bool, table: str = "") -> list[str]:
        self.expect("(")
        out = [self.name(table=table) if names else self.value()]
        while self.accept(","):
            out.append(self.name(table=table) if names else self.value())
        self.expect(")")
        return out

    def pairs(self, separator: str, *, table: str) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        while True:
            name = self.name(table=table)
            self.expect("=")
            out.append((name, self.value()))
            if not self.accept(separator):
                return out

    def statement(self) -> Statement:
        token = self.take()
        kind = token.text.upper()
        if token.quoted or kind not in _KINDS:
            raise token.error("Unsupported SQL statement")
        out = Statement(kind)
        if kind == "SHOW":
            self.expect("TABLES")
        elif kind == "CREATE":
            self.expect("TABLE")
            out.table = self.name()
            self.expect("(")
            while True:
                name = self.name(table=out.table)
                type_token = self.take()
                if type_token.quoted or type_token.text.upper() not in {"STRING", "NUMBER"}:
                    raise type_token.error("Column type must be String or Number")
                out.columns.append((name, type_token.text.title()))
                if not self.accept(","):
                    break
            self.expect(")")
        elif kind == "INSERT":
            self.expect("INTO")
            out.table = self.name()
            out.names = self.paren_list(names=True, table=out.table)
            self.expect("VALUES")
            out.values = self.paren_list(names=False)
        elif kind == "DROP":
            self.expect("TABLE")
            out.table = self.name()
        else:
            if kind == "SELECT":
                self.expect("*")
            if kind in {"SELECT", "DELETE"}:
                self.expect("FROM")
            out.table = self.name()
            if kind == "UPDATE":
                self.expect("SET")
                out.assignments = self.pairs(",", table=out.table)
            if self.accept("WHERE"):
                out.where = self.pairs("AND", table=out.table)
        self.expect(";")
        _validate_statement(out)
        return out


def _names(names: list[str], context: str, *, table: str = "") -> None:
    pattern = _ACTION_COLUMN if table == "Action" else _IDENT
    seen: set[str] = set()
    for name in names:
        if not isinstance(name, str) or not pattern.fullmatch(name):
            raise ScriptError(f"{context}: unsafe or invalid name {name!r}")
        if name in seen:
            raise ScriptError(f"{context}: duplicate column {name!r}")
        seen.add(name)


def _validate_statement(statement: Statement) -> None:
    kind = statement.kind
    if kind not in _KINDS:
        raise ScriptError(f"Unsupported SQL statement {kind!r}")
    if kind == "SHOW":
        if statement.table:
            raise ScriptError("SHOW TABLES takes no table name")
    else:
        _names([statement.table], kind)
    allowed = {"CREATE": {"columns"}, "INSERT": {"names", "values"},
               "SELECT": {"where"}, "DELETE": {"where"},
               "UPDATE": {"assignments", "where"}, "SHOW": set(), "DROP": set()}
    for name in ("columns", "names", "values", "where", "assignments"):
        if getattr(statement, name) and name not in allowed[kind]:
            raise ScriptError(f"{kind} does not support {name}")
    _names([name for name, _ in statement.columns], "CREATE", table=statement.table)
    _names(statement.names, "INSERT", table=statement.table)
    _names([name for name, _ in statement.where], "WHERE", table=statement.table)
    _names([name for name, _ in statement.assignments], "SET", table=statement.table)
    if kind == "CREATE" and (not statement.columns or any(
            type_name not in {"String", "Number"} for _, type_name in statement.columns)):
        raise ScriptError("CREATE requires columns of type String or Number")
    if kind == "INSERT" and (not statement.names or len(statement.names) != len(statement.values)):
        raise ScriptError(f"INSERT into {statement.table!r}: column/value count mismatch")
    if kind == "UPDATE" and not statement.assignments:
        raise ScriptError("UPDATE requires at least one SET assignment")
    for value in (statement.values + [v for _, v in statement.where]
                  + [v for _, v in statement.assignments]):
        if not isinstance(value, str) or "\0" in value:
            raise ScriptError("SQL values must be strings without NUL characters")
    if kind == "DROP" and statement.table == "Action":
        raise ScriptError("DROP TABLE Action is forbidden: Action is a transient table")


def _validate_schema(statement: Statement, schema: dict[str, str]) -> None:
    values = (list(zip(statement.names, statement.values))
              if statement.kind == "INSERT" else statement.assignments)
    for name, _ in values + statement.where:
        if name not in schema:
            raise ScriptError(f"Table {statement.table!r}: no such column {name!r}")
    if statement.kind == "INSERT":
        missing = schema.keys() - set(statement.names)
        if missing:
            raise ScriptError(f"INSERT into {statement.table!r}: missing columns {sorted(missing)!r}; "
                              "every declared column must be given exactly once")
    for name, value in values:
        if schema[name] == "Number":
            body = expr_body(value)
            try:
                if body is not None:
                    Expression(body)  # Syntax only; variable resolution happens later.
                else:
                    parse_number(value.strip(" \t\r\n\v\f"))
            except ScriptError as error:
                raise ScriptError(f"Column {name!r} of table {statement.table!r} is declared Number: "
                                  f"invalid value {value[:120]!r}: {error}") from error


def _validate_batch(statements: list[Statement]) -> None:
    schemas: dict[str, dict[str, str]] = {}
    touched: set[str] = set()
    updated: set[str] = set()
    dropped: set[str] = set()
    for statement in statements:
        kind, table = statement.kind, statement.table
        if kind not in {"SELECT", "SHOW"} and table in dropped:
            raise ScriptError(f"{kind} {table!r}: table was dropped earlier in this batch")
        if kind == "CREATE":
            if table in schemas:
                raise ScriptError(f"Duplicate CREATE TABLE {table!r}")
            schemas[table] = dict(statement.columns)
        elif kind == "UPDATE":
            if table in schemas:
                raise ScriptError(f"UPDATE {table!r}: table was created earlier in this batch; "
                                  "run UPDATE in a separate statement batch")
            if table in touched:
                raise ScriptError(f"UPDATE {table!r}: run UPDATE in a separate statement batch")
            updated.add(table)
            touched.add(table)
        elif kind in {"INSERT", "DELETE"}:
            if table in updated:
                raise ScriptError(f"{kind} {table!r}: rewritten by UPDATE earlier in this batch; "
                                  f"run {kind} in a separate statement batch")
            if table not in schemas:
                touched.add(table)
        elif kind == "DROP":
            if table in touched:
                raise ScriptError(f"DROP {table!r}: table already modified; "
                                  "run DROP in a separate statement batch")
            dropped.add(table)
        if table in schemas:
            _validate_schema(statement, schemas[table])


def parse_sql(text: str) -> list[Statement]:
    """Parse a complete, semicolon-terminated batch and enforce batch isolation."""
    if not isinstance(text, str):
        raise ScriptError("SQL input must be text")
    if "\0" in text:
        raise ScriptError("SQL input contains a NUL character")
    if len(text.encode("utf-8")) > _MAX_SCRIPT_BYTES:
        raise ScriptError(f"SQL script exceeds the {_MAX_SCRIPT_BYTES} byte limit")
    parser = _Parser(_tokens(text))
    statements: list[Statement] = []
    while parser.pos < len(parser.tokens):
        statements.append(parser.statement())
    _validate_batch(statements)
    return statements


def load_structure(text: str) -> dict[str, Matrix]:
    """Build insertion-ordered tables from CREATE/INSERT statements only."""
    tables: dict[str, Matrix] = {}
    for statement in parse_sql(text):
        apply_statement(tables, statement)
    return tables


def apply_statement(tables: dict[str, Matrix], statement: Statement, *,
                    allow_mutations: bool = False) -> None:
    """Apply one statement without hardware effects.

    For batch rollback, parse the whole batch, deepcopy the tables, apply to the
    copy, and publish it only after all statements succeed. This function has no
    hidden batch state; parse_sql enforces the cross-statement isolation rules.
    """
    _validate_statement(statement)
    kind, name = statement.kind, statement.table
    if kind in {"SELECT", "SHOW"}:
        raise ScriptError(f"{kind} is a query; the caller must handle queries")
    if kind in {"DELETE", "DROP", "UPDATE"} and not allow_mutations:
        raise ScriptError(f"{kind} cannot appear in a structure script; allow_mutations is required")
    if kind == "CREATE":
        if name in tables:
            raise ScriptError(f"Table {name!r} already exists")
        tables[name] = Table(name=name, rows=[[column for column, _ in statement.columns]],
                             column_types=dict(statement.columns))
        return
    if name not in tables:
        raise ScriptError(f"Table {name!r} is not defined")
    table = tables[name]
    if kind == "DROP":
        del tables[name]
        return
    # Plain .mt matrices carry no SQL schema. Do not infer types from their data.
    schema = {column: (table.column_types.get(column, "String")
                       if isinstance(table, Table) else "String") for column in table.header}
    _validate_schema(statement, schema)
    if kind == "INSERT":
        values = dict(zip(statement.names, statement.values))
        table.rows.append([values[column] for column in table.header])
        return
    conditions = [(table.header.index(column), value) for column, value in statement.where]
    hits = {row for row in range(1, len(table.rows))
            if all(table.inherited(row, column) == value for column, value in conditions)}
    if not hits:
        raise ScriptError(f"{kind} {name!r}: no row matches")
    modified: list[list[str]] = []
    if kind == "UPDATE":
        assignments = [(table.header.index(column), value)
                       for column, value in statement.assignments]
        # UPDATE removes the old rows and appends the rewritten rows. Materialize
        # inherited cells before removing anything; SET '-' itself stays literal.
        for row in sorted(hits):
            values = [table.inherited(row, column) for column in range(len(table.header))]
            for column, value in assignments:
                values[column] = value
            modified.append(values)
    # DELETE and UPDATE can remove a survivor's inheritance source. Snapshot
    # survivors before publishing any change, separately from explicit SET '-'.
    survivors = [table.header] + [
        [table.inherited(row, column) for column in range(len(table.header))]
        for row in range(1, len(table.rows)) if row not in hits]
    table.rows[:] = survivors + modified
