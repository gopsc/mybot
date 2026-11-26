"""The single SVG logo used by the splash screen, window icon and About box."""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QIcon, QPainter, QPixmap

LOGO_PATH = Path(__file__).resolve().parent / "assets" / "logo.svg"


def logo_pixmap(size):
    """Render the SVG at ``size``; fall back to a drawn mark without QtSvg."""
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.GlobalColor.transparent)
    try:
        from PySide6.QtSvg import QSvgRenderer
        renderer = QSvgRenderer(str(LOGO_PATH))
    except Exception:  # pragma: no cover - QtSvg ships with PySide6
        renderer = None
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    if renderer is not None and renderer.isValid():
        renderer.render(painter, QRectF(0, 0, size, size))
    else:  # pragma: no cover - defensive fallback
        painter.setBrush(QColor("#101b24"))
        painter.setPen(QColor("#3c7d8c"))
        painter.drawRoundedRect(QRectF(2, 2, size - 4, size - 4), size * 0.15, size * 0.15)
        painter.setPen(QColor("#e8a33d"))
        painter.drawRect(QRectF(size * 0.3, size * 0.35, size * 0.14, size * 0.1))
        painter.drawRect(QRectF(size * 0.56, size * 0.35, size * 0.14, size * 0.1))
        painter.setPen(QColor("#63d7c4"))
        painter.drawLine(int(size * 0.32), int(size * 0.62), int(size * 0.68), int(size * 0.62))
    painter.end()
    return pixmap


def logo_icon():
    return QIcon(logo_pixmap(256))
