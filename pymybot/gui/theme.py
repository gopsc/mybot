"""Shared light palette and stylesheet for every GUI window and dialog."""
from __future__ import annotations

from PySide6.QtGui import QColor, QPalette

PALETTE = {
    "user": "#245cc5", "assistant": "#243247", "tool": "#536277",
    "toolerr": "#b42332", "error": "#b42332", "system": "#59677a",
}
STYLESHEET = """
QWidget { color: #243247; }
QMainWindow, QDialog, QScrollArea > QWidget > QWidget { background: #f3f5f8; }
QGroupBox {
    background: #ffffff; border: 1px solid #d4dbe5; border-radius: 8px;
    margin-top: 10px; padding: 12px 8px 8px; font-weight: 600;
}
QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 4px; color: #34445a; }
QLabel#secondaryText { color: #59677a; }
QScrollArea { border: none; }
QLineEdit, QPlainTextEdit, QTextBrowser, QTableWidget, QTreeWidget {
    background: #ffffff; color: #243247; border: 1px solid #b8c3d2;
    border-radius: 5px; padding: 4px 6px; placeholder-text-color: #59677a;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QComboBox, QAbstractSpinBox {
    background: #ffffff; color: #243247; min-height: 1.8em;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QLineEdit:focus, QPlainTextEdit:focus, QTextBrowser:focus, QTableWidget:focus, QTreeWidget:focus {
    border: 1px solid #245cc5;
}
QLineEdit:disabled, QPlainTextEdit:disabled, QComboBox:disabled, QAbstractSpinBox:disabled {
    color: #606d7e; background: #edf0f4; border-color: #d4dbe5;
}
QComboBox QAbstractItemView {
    background: #ffffff; color: #243247;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QPlainTextEdit#chatTranscript, QTextBrowser#chatTranscript { padding: 10px; border: none; }
QPlainTextEdit#eventLog { background: #f8fafc; padding: 10px; border: none; }
QPushButton {
    background: #ffffff; color: #34445a; border: 1px solid #b8c3d2;
    border-radius: 5px; padding: 5px 10px;
}
QPushButton:hover { background: #edf3fc; border-color: #829ac0; }
QPushButton:pressed { background: #dfe9f8; }
QPushButton:default, QPushButton:focus { border: 2px solid #245cc5; padding: 4px 9px; }
QPushButton[role="primary"] { background: #245cc5; color: #ffffff; border-color: #245cc5; }
QPushButton[role="primary"]:hover { background: #1d4fae; border-color: #1d4fae; }
QPushButton[role="primary"]:pressed { background: #193f8a; border-color: #193f8a; }
QPushButton[role="primary"]:focus { border-color: #142e60; }
QPushButton[role="danger"] { color: #b42332; }
QPushButton[role="danger"]:hover { background: #fff1f2; border-color: #b42332; }
QPushButton:disabled, QPushButton[role="primary"]:disabled, QPushButton[role="danger"]:disabled {
    background: #edf0f4; color: #606d7e; border: 1px solid #d4dbe5; padding: 5px 10px;
}
QCheckBox { color: #34445a; spacing: 6px; padding: 3px 0; }
QCheckBox:disabled { color: #606d7e; }
QTabWidget::pane { background: #ffffff; border: 1px solid #d4dbe5; border-radius: 5px; }
QTabBar::tab {
    background: #edf0f4; color: #59677a; padding: 7px 18px;
    border-bottom: 2px solid transparent; margin-right: 3px;
}
QTabBar::tab:selected { background: #ffffff; color: #245cc5; border-bottom-color: #245cc5; }
QTabBar::tab:hover:!selected { background: #e5ebf4; color: #34445a; }
QTreeWidget, QTableWidget { alternate-background-color: #f3f6fa; }
QTreeWidget::item, QTableWidget::item { padding: 3px 0; }
QHeaderView::section {
    background: #edf2f8; color: #34445a; border: none;
    border-bottom: 1px solid #d4dbe5; padding: 5px; font-weight: 600;
}
QSplitter::handle { background: #e3e8ef; }
QSplitter::handle:hover { background: #b8c9e4; }
QScrollBar:vertical { background: #edf2f8; width: 14px; margin: 0; }
QScrollBar:horizontal { background: #edf2f8; height: 14px; margin: 0; }
QScrollBar::handle { background: #b8c3d2; border: 3px solid #edf2f8; border-radius: 6px; }
QScrollBar::handle:vertical { min-height: 28px; }
QScrollBar::handle:horizontal { min-width: 28px; }
QScrollBar::handle:hover { background: #829ac0; }
QScrollBar::add-line, QScrollBar::sub-line { width: 0; height: 0; }
QScrollBar::add-page, QScrollBar::sub-page { background: none; }
QStatusBar { background: #edf2f8; color: #34445a; border-top: 1px solid #d4dbe5; }
QStatusBar::item { border: none; }
QStatusBar QLabel { padding: 3px 6px; }
QProgressBar {
    border: 1px solid #b8c3d2; border-radius: 4px; background: #ffffff;
    text-align: center; color: #34445a; max-height: 14px;
}
QProgressBar::chunk { background: #245cc5; border-radius: 3px; }
QToolTip { background: #243247; color: #ffffff; border: none; padding: 5px 8px; }
QMenuBar { background: #f3f5f8; }
QMenuBar::item { padding: 4px 10px; background: transparent; }
QMenuBar::item:selected { background: #dfe9f8; }
QMenu { background: #ffffff; border: 1px solid #d4dbe5; }
QMenu::item { padding: 5px 24px 5px 20px; }
QMenu::item:selected { background: #edf3fc; color: #245cc5; }
"""


def apply_theme(window):
    palette = QPalette()
    for role, color in {
        "Window": "#f3f5f8", "WindowText": "#243247", "Base": "#ffffff",
        "AlternateBase": "#f3f6fa", "Text": "#243247", "Button": "#ffffff",
        "ButtonText": "#34445a", "BrightText": "#ffffff", "Highlight": "#245cc5",
        "Accent": "#245cc5", "HighlightedText": "#ffffff", "PlaceholderText": "#59677a",
        "ToolTipBase": "#243247", "ToolTipText": "#ffffff",
        "Link": "#245cc5", "LinkVisited": "#6547a3",
        "Light": "#ffffff", "Midlight": "#edf0f4", "Mid": "#b8c3d2",
        "Dark": "#606d7e", "Shadow": "#34445a",
    }.items():
        palette.setColor(getattr(QPalette.ColorRole, role), QColor(color))
    for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
        palette.setColor(QPalette.ColorGroup.Disabled, role, QColor("#606d7e"))
    window.setPalette(palette)
    window.setStyleSheet(STYLESHEET)
    font = window.font()
    font.setPointSizeF(max(font.pointSizeF(), 10))
    window.setFont(font)
