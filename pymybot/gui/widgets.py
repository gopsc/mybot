"""Small shared widgets and formatting helpers for the operator window.

Every GUI module builds the same label/button/monospace idioms; keeping one
implementation here avoids drift between the window, the dialogs and the
settings pages (they used to carry byte-identical copies).
"""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtGui import QFontDatabase
from PySide6.QtWidgets import QDoubleSpinBox, QLabel, QPushButton, QSpinBox, QTextBrowser, QWidget


def label(text="", *, secondary=False):
    """Plain-text, word-wrapped label; ``secondary`` uses the muted style."""
    widget = QLabel(text)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(True)
    if secondary:
        widget.setObjectName("secondaryText")
    return widget


def button(text, callback, *, role=None):
    """Push button with an optional theme role (``primary`` / ``danger``)."""
    widget = QPushButton(text)
    if role:
        widget.setProperty("role", role)
    widget.clicked.connect(callback)
    return widget


def mono(widget: QWidget) -> QWidget:
    """Switch one widget to the system fixed-width font."""
    widget.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
    return widget


def size_text(value):
    """Human-readable byte size (B/KiB/MiB/GiB); missing values render as 0 B."""
    size = int(value or 0)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} GiB"  # pragma: no cover - loop returns first


def spin(value, maximum, fractional=False):
    """Numeric field with the operator-friendly lower bound used across settings."""
    box = QDoubleSpinBox() if fractional else QSpinBox()
    box.setRange(0.01 if fractional else 1, maximum)
    box.setValue(value)
    return box


class SafeTextBrowser(QTextBrowser):
    """Preview/transcript widget that never loads local or remote resources."""

    def loadResource(self, _resource_type, _url):
        return None
