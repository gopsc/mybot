"""Small Qt syntax highlighters for previews and the MCP JSON editor.

Qt ships no general syntax engine; QSyntaxHighlighter is the intended extension
point. The rules here are deliberately shallow: they colour keys, strings,
numbers and keywords without parsing, and never modify the document.

Each language uses one alternation so a match is coloured exactly once. Applying
separate rules in sequence would let a later string/comment rule repaint part of
an earlier match (for example a quoted value inside a comment).
"""
from __future__ import annotations

import keyword

from PySide6.QtCore import QRegularExpression
from PySide6.QtGui import QColor, QFont, QSyntaxHighlighter, QTextCharFormat

COLORS = {
    "key": "#245cc5",
    "string": "#1d6b45",
    "number": "#9a4a00",
    "keyword": "#6547a3",
    "comment": "#59677a",
}

LANGUAGES = {
    "python": tuple(keyword.kwlist),
    "lua": ("lua", "local", "function", "end", "if", "then", "else", "elseif", "for", "while",
            "do", "return", "nil", "true", "false", "and", "or", "not", "break", "repeat", "until"),
    "sql": ("select", "from", "where", "insert", "into", "values", "create", "table", "drop",
            "delete", "update", "set", "show", "tables", "and", "or", "not", "null", "string",
            "number", "alias", "vars"),
    "mt": ("action", "reflex", "include", "merge", "alias", "vars", "struct", "if", "else", "end",
           "while", "loop", "break", "controller"),
}


def _format(color, *, bold=False):
    fmt = QTextCharFormat()
    fmt.setForeground(QColor(color))
    if bold:
        fmt.setFontWeight(QFont.Weight.DemiBold)
    return fmt


def _rule(patterns, formats):
    """Compile one alternation and map each capture group to its format."""
    regex = QRegularExpression("|".join(f"({pattern})" for pattern in patterns))
    return regex, tuple(formats)


class _AlternationHighlighter(QSyntaxHighlighter):
    def __init__(self, document):
        super().__init__(document)
        self._rule = None

    def _set_rule(self, patterns, formats):
        self._rule = _rule(patterns, formats)
        self.rehighlight()

    def highlightBlock(self, text):
        if self._rule is None:
            return
        regex, formats = self._rule
        iterator = regex.globalMatch(text)
        while iterator.hasNext():
            match = iterator.next()
            for index, fmt in enumerate(formats, 1):
                if match.capturedLength(index):
                    self.setFormat(match.capturedStart(index), match.capturedLength(index), fmt)
                    break


class JsonHighlighter(_AlternationHighlighter):
    """JSON keys, strings, numbers and literals."""

    def __init__(self, document):
        super().__init__(document)
        string = r'"(?:[^"\\]|\\.)*"'
        self._set_rule(
            [f'{string}(?=\\s*:)', string,
             r"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b",
             r"\b(?:true|false|null)\b"],
            [_format(COLORS["key"], bold=True), _format(COLORS["string"]),
             _format(COLORS["number"]), _format(COLORS["keyword"], bold=True)],
        )


class CodeHighlighter(_AlternationHighlighter):
    """Shallow keyword/comment/string colouring for MT, Lua and SQL previews."""

    def __init__(self, document, language="mt"):
        super().__init__(document)
        self.set_language(language)

    def set_language(self, language):
        words = "|".join(LANGUAGES.get(language, LANGUAGES["mt"]))
        case = "" if language == "python" else "(?i)"
        comment = r"#[^\n]*" if language == "python" else r"--[^\n]*|#[^\n]*"
        self._set_rule(
            [comment,
             r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'',
             rf"{case}\b(?:{words})\b",
             r"\b\d+(?:\.\d+)?\b"],
            [_format(COLORS["comment"]), _format(COLORS["string"]),
             _format(COLORS["keyword"], bold=True), _format(COLORS["number"])],
        )
