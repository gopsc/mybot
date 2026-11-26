"""Shared light palette and stylesheet for every GUI window and dialog."""
from __future__ import annotations

from PySide6.QtGui import QColor, QPalette

PALETTE = {
    "user": "#1d4ed8", "assistant": "#1e293b", "tool": "#526177",
    "toolerr": "#b42318", "error": "#b42318", "system": "#5b6675",
}
STYLESHEET = """
QWidget { color: #1e293b; }
QMainWindow, QDialog, QScrollArea, QScrollArea > QWidget > QWidget { background: #f6f8fb; }
QGroupBox {
    background: #ffffff; border: 1px solid #e0e7ef; border-radius: 10px;
    margin-top: 12px; padding: 14px 10px 10px; font-weight: 600;
}
QGroupBox::title {
    subcontrol-origin: margin; left: 12px; padding: 0 5px;
    color: #334155; background: #f6f8fb;
}
QLabel#secondaryText { color: #5b6675; }
QScrollArea { border: none; }
QLineEdit, QPlainTextEdit, QTextBrowser, QTableWidget, QTreeWidget {
    background: #ffffff; color: #1e293b; border: 1px solid #cbd5e1;
    border-radius: 6px; padding: 5px 8px; placeholder-text-color: #64748b;
    selection-background-color: #2563eb; selection-color: #ffffff;
}
QLineEdit { min-height: 28px; }
QComboBox, QAbstractSpinBox {
    background: #ffffff; color: #1e293b; border: 1px solid #cbd5e1;
    border-radius: 6px; padding: 3px 8px; min-height: 28px;
    selection-background-color: #2563eb; selection-color: #ffffff;
}
QComboBox::drop-down { border: none; width: 26px; }
QComboBox QAbstractItemView {
    background: #ffffff; color: #1e293b; border: 1px solid #cbd5e1;
    padding: 4px; selection-background-color: #dbeafe; selection-color: #1e3a8a;
}
QLineEdit:hover, QPlainTextEdit:hover, QTextBrowser:hover,
QComboBox:hover, QAbstractSpinBox:hover { border-color: #94a3b8; }
QLineEdit:focus, QPlainTextEdit:focus, QTextBrowser:focus, QTableWidget:focus,
QTreeWidget:focus, QComboBox:focus, QAbstractSpinBox:focus { border: 1px solid #2563eb; }
QLineEdit:disabled, QPlainTextEdit:disabled, QTextBrowser:disabled,
QComboBox:disabled, QAbstractSpinBox:disabled {
    color: #5f6b7a; background: #edf2f7; border-color: #dbe3ec;
}
QPlainTextEdit#chatTranscript, QTextBrowser#chatTranscript {
    background: #ffffff; padding: 16px; border: none;
}
QPlainTextEdit#eventLog { background: #f8fafc; padding: 14px; border: none; }
QPushButton, QToolButton {
    background: #ffffff; color: #334155; border: 1px solid #cbd5e1;
    border-radius: 6px; padding: 5px 12px; min-height: 28px; font-weight: 500;
}
QPushButton:hover, QToolButton:hover { background: #f1f5f9; border-color: #94a3b8; }
QPushButton:pressed, QToolButton:pressed { background: #e2e8f0; }
QPushButton:default, QPushButton:focus, QToolButton:focus { border-color: #2563eb; }
QPushButton[role="primary"] { background: #2563eb; color: #ffffff; border-color: #2563eb; }
QPushButton[role="primary"]:hover { background: #1d4ed8; border-color: #1d4ed8; }
QPushButton[role="primary"]:pressed { background: #1e40af; border-color: #1e40af; }
QPushButton[role="danger"] { color: #b42318; }
QPushButton[role="danger"]:hover { background: #fff1f2; border-color: #fda4af; }
QPushButton:disabled, QToolButton:disabled,
QPushButton[role="primary"]:disabled, QPushButton[role="danger"]:disabled {
    background: #edf2f7; color: #5f6b7a; border: 1px solid #dbe3ec;
}
QCheckBox { color: #334155; spacing: 8px; padding: 4px 0; }
QCheckBox:disabled { color: #5f6b7a; }
QTabWidget::pane { background: #ffffff; border: 1px solid #e0e7ef; border-radius: 8px; }
QTabBar::tab {
    background: transparent; color: #5b6675; padding: 8px 18px;
    border-bottom: 2px solid transparent; margin-right: 4px;
}
QTabBar::tab:selected { background: #eff6ff; color: #1d4ed8; border-bottom-color: #2563eb; }
QTabBar::tab:hover:!selected { background: #f1f5f9; color: #334155; }
QTreeWidget, QTableWidget { alternate-background-color: #f8fafc; gridline-color: #edf2f7; }
QTreeWidget::item, QTableWidget::item { padding: 5px 2px; border: none; }
QTreeWidget::item:selected, QTableWidget::item:selected { background: #dbeafe; color: #1e3a8a; }
QHeaderView::section {
    background: #f1f5f9; color: #334155; border: none;
    border-bottom: 1px solid #dbe3ec; padding: 7px 6px; font-weight: 600;
}
QSplitter::handle { background: transparent; }
QSplitter::handle:hover { background: #dbe7f5; }
QScrollBar:vertical { background: transparent; width: 12px; margin: 2px; }
QScrollBar:horizontal { background: transparent; height: 12px; margin: 2px; }
QScrollBar::handle { background: #cbd5e1; border-radius: 4px; min-height: 28px; min-width: 28px; }
QScrollBar::handle:hover { background: #94a3b8; }
QScrollBar::add-line, QScrollBar::sub-line { width: 0; height: 0; }
QScrollBar::add-page, QScrollBar::sub-page { background: none; }
QStatusBar { background: #f1f5f9; color: #475569; border-top: 1px solid #e0e7ef; }
QStatusBar::item { border: none; }
QStatusBar QLabel { padding: 4px 7px; }
QProgressBar {
    border: none; border-radius: 4px; background: #e2e8f0;
    text-align: center; color: #334155; max-height: 10px;
}
QProgressBar::chunk { background: #2563eb; border-radius: 4px; }
QToolTip {
    background: #1e293b; color: #ffffff; border: none;
    border-radius: 4px; padding: 6px 8px;
}
QMenuBar { background: #f6f8fb; border-bottom: 1px solid #e8edf3; }
QMenuBar::item { padding: 6px 11px; background: transparent; border-radius: 4px; }
QMenuBar::item:selected { background: #e8eff8; color: #1d4ed8; }
QMenu { background: #ffffff; border: 1px solid #dbe3ec; padding: 4px; }
QMenu::item { padding: 7px 26px 7px 20px; border-radius: 4px; }
QMenu::item:selected { background: #eff6ff; color: #1d4ed8; }
QMenu::separator { height: 1px; background: #e2e8f0; margin: 5px 8px; }
QDialogButtonBox QPushButton { min-width: 72px; }
"""


def apply_theme(window):
    palette = QPalette()
    for role, color in {
        "Window": "#f6f8fb", "WindowText": "#1e293b", "Base": "#ffffff",
        "AlternateBase": "#f8fafc", "Text": "#1e293b", "Button": "#ffffff",
        "ButtonText": "#334155", "BrightText": "#ffffff", "Highlight": "#2563eb",
        "Accent": "#2563eb", "HighlightedText": "#ffffff", "PlaceholderText": "#64748b",
        "ToolTipBase": "#1e293b", "ToolTipText": "#ffffff",
        "Link": "#2563eb", "LinkVisited": "#6d28d9",
        "Light": "#ffffff", "Midlight": "#f1f5f9", "Mid": "#cbd5e1",
        "Dark": "#64748b", "Shadow": "#334155",
    }.items():
        palette.setColor(getattr(QPalette.ColorRole, role), QColor(color))
    for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
        palette.setColor(QPalette.ColorGroup.Disabled, role, QColor("#5f6b7a"))
    palette.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.PlaceholderText, QColor("#64748b"))
    window.setPalette(palette)
    window.setStyleSheet(STYLESHEET)
    font = window.font()
    font.setPointSizeF(max(font.pointSizeF(), 10))
    window.setFont(font)
