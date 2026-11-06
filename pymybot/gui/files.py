"""Workspace file browser and camera snapshot preview.

Both are read-only operator views: the browser never writes or executes a
workspace file, and its preview stack refuses every resource load (no local
images, remote URLs or JavaScript). Saving a snapshot stays an explicit
operator action bound to the workspace ``snapshots/`` directory.
"""
from __future__ import annotations

import time
from pathlib import Path

from PySide6.QtCore import Qt, QFileSystemWatcher, QTimer, QUrl
from PySide6.QtGui import QDesktopServices, QPixmap
from PySide6.QtWidgets import (QApplication, QDialog, QHBoxLayout, QLabel, QLineEdit,
                               QPlainTextEdit, QPushButton, QSplitter, QStackedWidget,
                               QTextEdit, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

from .highlight import CodeHighlighter
from .theme import apply_theme
from .widgets import (SafeTextBrowser, button as _button, label as _label, mono as _mono,
                      size_text as _size_text)


class FilesPanel(QWidget):
    """Workspace file manager with safe inline previews.

    Operator-local and read-only: the tree scans the workspace (bounded depth
    and entry count, dot-directories, venvs and symlinks skipped) and the
    preview stack renders code with keyword highlighting, Markdown, HTML (no
    JavaScript, no resource loads — SafeTextBrowser) and images. Nothing is
    written or executed; "open" hands the file to the operating system.
    """

    MAX_ENTRIES = 4000
    MAX_DEPTH = 4
    MAX_PREVIEW_BYTES = 256 * 1024
    SKIP_DIRS = frozenset({".git", ".venv", "venv", "node_modules", "__pycache__",
                           ".mybot", ".pytest_cache", ".ruff_cache", "build", "dist"})
    CODE_LANGUAGES = {".py": "python", ".lua": "lua", ".sql": "sql", ".mt": "mt",
                      ".sh": "plain", ".js": "plain", ".css": "plain", ".json": "plain",
                      ".yaml": "plain", ".yml": "plain", ".toml": "plain", ".txt": "plain"}
    MARKDOWN_SUFFIXES = {".md", ".markdown"}
    HTML_SUFFIXES = {".html", ".htm"}
    IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".bmp", ".webp", ".ico"}

    def __init__(self, parent=None):
        super().__init__(parent)
        self.root = None
        self._count = 0
        self._files = 0
        self._truncated = False
        self._build()

    def _build(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        row = QHBoxLayout()
        self.filter = QLineEdit()
        self.filter.setPlaceholderText("过滤文件名…")
        self.filter.textChanged.connect(self._apply_filter)
        row.addWidget(self.filter, 1)
        row.addWidget(_button("刷新", self.refresh))
        row.addWidget(_button("预览", self.preview_selected))
        row.addWidget(_button("复制路径", self.copy_path))
        row.addWidget(_button("在系统中打开", self.open_selected))
        row.addWidget(_button("打开目录", self.open_folder))
        layout.addLayout(row)
        split = QSplitter(Qt.Orientation.Horizontal)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["工作区文件", "大小"])
        self.tree.setColumnWidth(0, 280)
        self.tree.setAlternatingRowColors(True)
        self.tree.itemSelectionChanged.connect(self._on_select)
        self.tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected())
        split.addWidget(self.tree)
        self.preview = QStackedWidget()
        self.placeholder = _label("选择一个文件预览；HTML 预览不执行脚本、不加载外部资源", secondary=True)
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder.setWordWrap(True)
        self.markdown = SafeTextBrowser()
        self.markdown.setOpenExternalLinks(False)
        self.markdown.setLineWrapMode(QTextEdit.LineWrapMode.WidgetWidth)
        self.html = SafeTextBrowser()
        self.html.setOpenExternalLinks(False)
        self.html.setLineWrapMode(QTextEdit.LineWrapMode.WidgetWidth)
        self.code = QPlainTextEdit()
        self.code.setReadOnly(True)
        self.code.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        _mono(self.code)
        self.highlighter = CodeHighlighter(self.code.document(), "python")
        self.image = QLabel()
        self.image.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview.addWidget(self.placeholder)
        self.preview.addWidget(self.markdown)
        self.preview.addWidget(self.html)
        self.preview.addWidget(self.code)
        self.preview.addWidget(self.image)
        split.addWidget(self.preview)
        split.setSizes([320, 600])
        layout.addWidget(split, 1)
        self.status = _label("工作区未设置", secondary=True)
        layout.addWidget(self.status)
        self.watcher = QFileSystemWatcher(self)
        self.watcher.directoryChanged.connect(self._schedule_refresh)
        self._refresh_timer = QTimer(self)
        self._refresh_timer.setSingleShot(True)
        self._refresh_timer.timeout.connect(lambda: self.root and self.refresh())

    # -- workspace scanning ------------------------------------------------
    def set_root(self, path):
        """Point the browser at a workspace root and scan it (bounded)."""
        self.root = Path(path).absolute() if path else None
        self.refresh()

    def refresh(self):
        self.tree.clear()
        self._count = 0
        self._files = 0
        self._truncated = False
        if self.root is None or not self.root.is_dir():
            self.status.setText("工作区不存在；在「打开工作区」中选择一个目录")
            self._show(self.placeholder)
            return
        self._walk(self.root, self.tree.invisibleRootItem(), 0)
        if self._truncated:
            note = QTreeWidgetItem(self.tree, [f"…（已截断，仅显示前 {self.MAX_ENTRIES} 项）", ""])
            note.setFirstColumnSpanned(True)
            note.setDisabled(True)
        self.tree.expandAll()
        self.status.setText(f"{self._files} 个文件 · {self._count - self._files} 个目录 · {self.root}")
        existing = self.watcher.directories()
        if existing:
            self.watcher.removePaths(existing)
        if self.root.is_dir():
            self.watcher.addPath(str(self.root))
        self._apply_filter()

    def _walk(self, directory, parent, depth):
        try:
            entries = sorted(directory.iterdir(),
                             key=lambda p: (p.is_file(), p.name.lower()))
        except OSError:
            return
        for entry in entries:
            if self._count >= self.MAX_ENTRIES:
                self._truncated = True
                return
            try:
                if entry.is_symlink():
                    continue
                is_dir = entry.is_dir()
            except OSError:
                continue
            if is_dir:
                if entry.name in self.SKIP_DIRS or entry.name.startswith("."):
                    continue
                node = QTreeWidgetItem(parent, [entry.name + "/", ""])
                node.setFirstColumnSpanned(True)
                self._count += 1
                if depth < self.MAX_DEPTH:
                    self._walk(entry, node, depth + 1)
            else:
                try:
                    size = entry.stat().st_size
                except OSError:
                    size = 0
                node = QTreeWidgetItem(parent, [entry.name, _size_text(size)])
                node.setData(0, Qt.ItemDataRole.UserRole, (str(entry), size))
                node.setToolTip(0, str(entry))
                self._files += 1
                self._count += 1

    def _apply_filter(self):
        needle = self.filter.text().strip().lower()
        for index in range(self.tree.topLevelItemCount()):
            self._match_item(self.tree.topLevelItem(index), needle)
        self.tree.expandAll()

    def _match_item(self, item, needle):
        visible = False
        for index in range(item.childCount()):
            if self._match_item(item.child(index), needle):
                visible = True
        if not item.data(0, Qt.ItemDataRole.UserRole):  # directory or note row
            matched = bool(needle) and needle in item.text(0).lower()
            item.setHidden(bool(needle) and not (visible or matched))
            return visible or matched
        name = item.text(0).lower()
        matched = not needle or needle in name
        item.setHidden(not matched)
        return matched or visible

    # -- previews -----------------------------------------------------------
    def _show(self, widget):
        self.preview.setCurrentWidget(widget)

    def _selected_path(self):
        item = self.tree.currentItem()
        if item is None:
            return None
        data = item.data(0, Qt.ItemDataRole.UserRole)
        return data[0] if data else None

    def _on_select(self):
        path = self._selected_path()
        if path:
            self.preview_file(path)
        else:
            self._show(self.placeholder)

    def preview_selected(self):
        path = self._selected_path()
        if path:
            self.preview_file(path)

    def preview_file(self, path):
        """Render one file in the preview stack; never writes or executes."""
        suffix = Path(path).suffix.lower()
        if suffix in self.IMAGE_SUFFIXES:
            pixmap = QPixmap(path)
            if pixmap.isNull():
                self._show(self.placeholder)
                return
            scaled = pixmap.scaled(520, 520, Qt.AspectRatioMode.KeepAspectRatio,
                                   Qt.TransformationMode.SmoothTransformation)
            self.image.setPixmap(scaled)
            self._show(self.image)
            return
        try:
            with open(path, "rb") as handle:
                data = handle.read(self.MAX_PREVIEW_BYTES + 1)
        except OSError as exc:
            self.placeholder.setText(f"无法读取：{exc}")
            self._show(self.placeholder)
            return
        truncated = len(data) > self.MAX_PREVIEW_BYTES
        text = data[:self.MAX_PREVIEW_BYTES].decode("utf-8", errors="replace")
        note = f"（预览截断到 {self.MAX_PREVIEW_BYTES // 1024} KiB）" if truncated else ""
        if suffix in self.MARKDOWN_SUFFIXES:
            # Rendered Markdown, not raw source; SafeTextBrowser still refuses
            # every image/link resource so previews never touch disk or network.
            self.markdown.setMarkdown(text)
            self._show(self.markdown)
        elif suffix in self.HTML_SUFFIXES:
            # SafeTextBrowser never loads resources; QTextBrowser never runs JS.
            self.html.setHtml(text)
            self._show(self.html)
        elif suffix in self.CODE_LANGUAGES:
            self.highlighter.set_language(self.CODE_LANGUAGES[suffix])
            self.code.setPlainText(text)
            self._show(self.code)
        else:
            if _likely_text(data[:4096]):
                self.highlighter.set_language("plain")
                self.code.setPlainText(text)
                self._show(self.code)
            else:
                self.placeholder.setText("二进制文件；使用「在系统中打开」查看。" + note)
                self._show(self.placeholder)
        if note:
            self.status.setText(self.status.text().split(" · 预览")[0] + f" · 预览{note}")

    # -- operator actions ---------------------------------------------------
    def open_selected(self):
        path = self._selected_path()
        if path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(path))

    def open_folder(self):
        if self.root is not None and self.root.is_dir():
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.root)))

    def copy_path(self):
        path = self._selected_path()
        if path:
            QApplication.clipboard().setText(path)
            self.status.setText(f"已复制路径：{path}")

    def _schedule_refresh(self, *_args):
        self._refresh_timer.start(400)


def _likely_text(sample):
    """Heuristic: UTF-8 decodable with few control characters means previewable."""
    if not sample:
        return False
    try:
        sample.decode("utf-8")
    except UnicodeDecodeError:
        return False
    control = sum(1 for byte in sample if byte < 9 or 11 <= byte <= 12 or 14 <= byte <= 31)
    return control / len(sample) < 0.05


class SnapshotDialog(QDialog):
    """Preview one camera snapshot; saving is an explicit operator action."""

    def __init__(self, parent, pixmap, *, workspace="", width=None, height=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("摄像头抓拍")
        self.setModal(True)
        self.resize(720, 560)
        self.pixmap = pixmap
        self.workspace = Path(workspace).absolute() if workspace else None
        layout = QVBoxLayout(self)
        info = (f"{pixmap.width()}×{pixmap.height()}" if pixmap.width() else "")
        if width and height:
            info += f"（传感器 {width}×{height}）"
        label = QLabel(f"抓拍成功 {info}".strip())
        label.setObjectName("secondaryText")
        layout.addWidget(label)
        view = QLabel()
        view.setPixmap(pixmap.scaled(680, 420, Qt.AspectRatioMode.KeepAspectRatio,
                                     Qt.TransformationMode.SmoothTransformation))
        view.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(view, 1)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        save = QPushButton("保存到工作区")
        save.setProperty("role", "primary")
        save.clicked.connect(self.save_snapshot)
        buttons.addWidget(save)
        copy = QPushButton("复制到剪贴板")
        copy.clicked.connect(self.copy_snapshot)
        buttons.addWidget(copy)
        close = QPushButton("关闭")
        close.clicked.connect(self.accept)
        buttons.addWidget(close)
        layout.addLayout(buttons)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)

    def save_snapshot(self):
        if self.workspace is None:
            self.status.setText("未设置工作区，无法保存")
            return
        target = self.workspace / "snapshots"
        try:
            target.mkdir(parents=True, exist_ok=True)
            path = target / time.strftime("snapshot-%Y%m%d-%H%M%S.jpg")
            if not self.pixmap.save(str(path), "JPG", 92):
                raise OSError("Qt 无法写入 JPEG 文件")
        except OSError as exc:
            self.status.setText(f"保存失败：{exc}")
            return
        self.status.setText(f"已保存：{path}")

    def copy_snapshot(self):
        QApplication.clipboard().setPixmap(self.pixmap)
        self.status.setText("已复制到剪贴板")
