"""Retro entry screen shown while the window and its serve child initialise."""
from __future__ import annotations

from PySide6.QtCore import (QEasingCurve, QPropertyAnimation, QRectF, QTimer, Qt, Signal)
from PySide6.QtGui import (QColor, QFont, QFontDatabase, QKeySequence, QLinearGradient,
                           QPainter, QPen, QShortcut)
from PySide6.QtWidgets import (QHBoxLayout, QLabel, QProgressBar, QPushButton,
                               QVBoxLayout, QWidget)

from .. import __version__
from .branding import logo_pixmap

SPLASH_STYLE = """
QWidget { color: #334155; }
QLabel { background: transparent; }
QLabel#splashTitle {
    color: #0f172a; font-weight: 700; letter-spacing: 4px;
}
QLabel#splashSubtitle { color: #2563eb; letter-spacing: 1px; }
QLabel#splashStatus { color: #334155; }
QLabel#splashDetail { color: #64748b; }
QProgressBar {
    background: #e2e8f0; border: none; border-radius: 4px;
    max-height: 8px; min-height: 8px;
}
QProgressBar::chunk { background: #2563eb; border-radius: 4px; }
QPushButton#enterButton {
    background: #2563eb; color: #ffffff; border: 1px solid #2563eb;
    border-radius: 6px; padding: 9px 26px; font-weight: 600;
}
QPushButton#enterButton:hover { background: #1d4ed8; border-color: #1d4ed8; }
QPushButton#enterButton:pressed { background: #1e40af; border-color: #1e40af; }
"""


class SplashScreen(QWidget):
    """Frameless scan-line entry screen with a real, operator-pressed entry."""

    entered = Signal()
    cancelled = Signal()

    def __init__(self, status_provider=None, parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.WindowType.SplashScreen | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setFixedSize(760, 470)
        self.setStyleSheet(SPLASH_STYLE)
        self.status_provider = status_provider
        self._phase = 0.0
        self._entered = False
        self._fade = None
        self._build()
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)
        self._timer.start(33)
        self._poll = QTimer(self)
        self._poll.timeout.connect(self.refresh_status)
        self._poll.start(150)
        shortcut = QShortcut(QKeySequence("Return"), self)
        shortcut.activated.connect(self.enter)
        escape = QShortcut(QKeySequence("Escape"), self)
        escape.activated.connect(self.cancel)
        self.refresh_status()

    def _build(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(46, 40, 46, 34)
        top = QHBoxLayout()
        self.logo = QLabel()
        self.logo.setPixmap(logo_pixmap(116))
        self.logo.setFixedSize(116, 116)
        top.addWidget(self.logo)
        text = QVBoxLayout()
        text.setSpacing(2)
        self.title = QLabel("MYBOT")
        self.title.setObjectName("splashTitle")
        mono = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        mono.setPointSizeF(30)
        mono.setBold(True)
        self.title.setFont(mono)
        self.subtitle = QLabel(f"ROBOT CONTROL STATION // v{__version__}")
        self.subtitle.setObjectName("splashSubtitle")
        subtitle_font = QFont(mono)
        subtitle_font.setPointSizeF(10)
        self.subtitle.setFont(subtitle_font)
        self.detail = QLabel("结构 SQL  ·  Lua 驱动  ·  MT 动作  ·  Agent  ·  MCP")
        self.detail.setObjectName("splashDetail")
        self.detail.setFont(subtitle_font)
        text.addStretch()
        text.addWidget(self.title)
        text.addWidget(self.subtitle)
        text.addWidget(self.detail)
        text.addStretch()
        top.addLayout(text, 1)
        layout.addLayout(top)
        layout.addStretch()

        self.status = QLabel("正在加载设置与资源…")
        self.status.setObjectName("splashStatus")
        status_font = QFont(mono)
        status_font.setPointSizeF(10)
        self.status.setFont(status_font)
        layout.addWidget(self.status)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        layout.addWidget(self.progress)
        bottom = QHBoxLayout()
        self.hint = QLabel("初始化在后台进行；可随时进入控制台")
        self.hint.setObjectName("splashDetail")
        self.hint.setFont(subtitle_font)
        bottom.addWidget(self.hint, 1)
        self.enter_button = QPushButton("进入控制台  ↵")
        self.enter_button.setObjectName("enterButton")
        self.enter_button.clicked.connect(self.enter)
        bottom.addWidget(self.enter_button)
        layout.addLayout(bottom)

    def _tick(self):
        self._phase = (self._phase + 0.012) % 1.0
        self.update()

    def refresh_status(self):
        if self.status_provider is None or self._entered:
            return
        try:
            text = self.status_provider()
        except Exception as exc:
            text = f"状态不可用：{type(exc).__name__}"
        if isinstance(text, tuple):
            text, hint = text
            self.hint.setText(str(hint))
        self.status.setText(str(text))

    def enter(self):
        if self._entered:
            return
        self._entered = True
        self._timer.stop()
        self._poll.stop()
        self.entered.emit()

    def cancel(self):
        if self._entered:
            return
        self._entered = True
        self._timer.stop()
        self._poll.stop()
        self.cancelled.emit()

    def closeEvent(self, event):
        if not self._entered:
            self._entered = True
            self._timer.stop()
            self._poll.stop()
            self.cancelled.emit()
        super().closeEvent(event)

    def fade_out(self, finished=None):
        self._fade = QPropertyAnimation(self, b"windowOpacity", self)
        self._fade.setDuration(220)
        self._fade.setStartValue(float(self.windowOpacity()))
        self._fade.setEndValue(0.0)
        self._fade.setEasingCurve(QEasingCurve.Type.InCubic)

        def done():
            self.close()
            if finished is not None:
                finished()

        self._fade.finished.connect(done)
        self._fade.start()

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        rect = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        painter.setBrush(QColor("#ffffff"))
        painter.setPen(QPen(QColor("#dbe3ec"), 1))
        painter.drawRoundedRect(rect, 16, 16)
        painter.setClipRect(rect)
        scan_y = int(self._phase * self.height())
        gradient = QLinearGradient(0, scan_y - 32, 0, scan_y + 32)
        gradient.setColorAt(0.0, QColor(37, 99, 235, 0))
        gradient.setColorAt(0.5, QColor(37, 99, 235, 14))
        gradient.setColorAt(1.0, QColor(37, 99, 235, 0))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(gradient)
        painter.drawRect(0, scan_y - 32, self.width(), 64)
        accent = QPen(QColor("#2563eb"))
        accent.setWidth(3)
        accent.setCapStyle(Qt.PenCapStyle.RoundCap)
        painter.setPen(accent)
        painter.drawLine(46, self.height() - 22, 46 + 120, self.height() - 22)
        painter.end()
