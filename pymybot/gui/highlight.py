"""Small Qt syntax highlighters for previews and the MCP JSON editor.

Qt ships no general syntax engine; QSyntaxHighlighter is the intended extension
point. The rules here are deliberately shallow: they colour keys, strings,
numbers and keywords without parsing, and never modify the document.
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
    "mt": ("action", "include", "merge", "alias", "vars", "struct", "if", "else", "end",
           "while", "loop", "break", "controller", "trigger"),
}


def _format(color, *, bold=False, mono=False):
    fmt = QTextCharFormat()
    fmt.setForeground(QColor(color))
    if bold:
        fmt.setFontWeight(QFont.Weight.DemiBold)
    if mono:
        fmt.setFontFixedPitch(True)
    return fmt


class JsonHighlighter(QSyntaxHighlighter):
    """JSON keys, strings, numbers and literals."""

    def __init__(self, document):
        super().__init__(document)
        self._rules = [
            (QRegularExpression(r'"(?:[^"\\]|\\.)*"(?=\s*:)'), _format(COLORS["key"], bold=True)),
            (QRegularExpression(r'"(?:[^"\\]|\\.)*"'), _format(COLORS["string"])),
            (QRegularExpression(r"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b"),
             _format(COLORS["number"])),
            (QRegularExpression(r"\b(?:true|false|null)\b"), _format(COLORS["keyword"], bold=True)),
        ]

    def highlightBlock(self, text):
        for pattern, fmt in self._rules:
            iterator = pattern.globalMatch(text)
            while iterator.hasNext():
                match = iterator.next()
                self.setFormat(match.capturedStart(), match.capturedLength(), fmt)


class CodeHighlighter(QSyntaxHighlighter):
    """Shallow keyword/comment/string colouring for MT, Lua and SQL previews."""

    def __init__(self, document, language="mt"):
        super().__init__(document)
        self._rules = []
        self.set_language(language)

    def set_language(self, language):
        words = "|".join(LANGUAGES.get(language, LANGUAGES["mt"]))
        case = "" if language == "python" else "(?i)"
        comment = r"#[^\n]*" if language == "python" else r"--[^\n]*|#[^\n]*"
        self._rules = [
            (QRegularExpression(comment), _format(COLORS["comment"])),
            (QRegularExpression(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\''), _format(COLORS["string"])),
            (QRegularExpression(rf"{case}\b(?:{words})\b"), _format(COLORS["keyword"], bold=True)),
            (QRegularExpression(r"\b\d+(?:\.\d+)?\b"), _format(COLORS["number"])),
        ]
        self.rehighlight()

    def highlightBlock(self, text):
        for pattern, fmt in self._rules:
            iterator = pattern.globalMatch(text)
            while iterator.hasNext():
                match = iterator.next()
                self.setFormat(match.capturedStart(), match.capturedLength(), fmt)
