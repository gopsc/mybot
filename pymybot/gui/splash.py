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
QWidget { color: #d7e6ea; }
QLabel#splashTitle {
    color: #f2f6f7; font-weight: 700; letter-spacing: 6px;
}
QLabel#splashSubtitle { color: #63d7c4; letter-spacing: 2px; }
QLabel#splashStatus { color: #c6d6dc; }
QLabel#splashDetail { color: #7e97a1; }
QProgressBar {
    background: #0d1a22; border: 1px solid #284a57; border-radius: 3px;
    max-height: 8px; min-height: 8px;
}
QProgressBar::chunk { background: #63d7c4; border-radius: 2px; }
QPushButton#enterButton {
    background: #e8a33d; color: #141c22; border: 1px solid #f0b766;
    border-radius: 5px; padding: 9px 26px; font-weight: 700;
}
QPushButton#enterButton:hover { background: #f0b766; }
QPushButton#enterButton:pressed { background: #cf8c2c; }
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
        painter.setBrush(QColor("#0b1118"))
        painter.setPen(QPen(QColor("#2a5563"), 1))
        painter.drawRoundedRect(rect, 16, 16)
        painter.setClipRect(rect)
        grid = QPen(QColor("#17303a"))
        grid.setWidth(1)
        painter.setPen(grid)
        for x in range(0, self.width(), 34):
            painter.drawLine(x, 0, x, self.height())
        for y in range(0, self.height(), 34):
            painter.drawLine(0, y, self.width(), y)
        scan_y = int(self._phase * self.height())
        gradient = QLinearGradient(0, scan_y - 26, 0, scan_y + 26)
        gradient.setColorAt(0.0, QColor(99, 215, 196, 0))
        gradient.setColorAt(0.5, QColor(99, 215, 196, 42))
        gradient.setColorAt(1.0, QColor(99, 215, 196, 0))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(gradient)
        painter.drawRect(0, scan_y - 26, self.width(), 52)
        accent = QPen(QColor("#63d7c4"))
        accent.setWidth(2)
        painter.setPen(accent)
        painter.drawLine(46, self.height() - 22, 46 + 120, self.height() - 22)
        painter.end()
