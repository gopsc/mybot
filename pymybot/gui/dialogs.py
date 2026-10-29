"""Operator dialogs: MCP editor, sessions, diagnostics, previews and resources."""
from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import sys
import tempfile

from PySide6.QtCore import (QEasingCurve, QFileSystemWatcher, QPropertyAnimation, QRunnable,
                            QThreadPool, QTimer, QUrl, Signal)
from PySide6.QtGui import QColor, QDesktopServices, QFontDatabase
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDoubleSpinBox, QFileDialog,
    QFormLayout, QGraphicsOpacityEffect, QGroupBox, QHBoxLayout,
    QHeaderView, QLabel, QLineEdit, QMessageBox, QPlainTextEdit, QProgressBar,
    QPushButton, QSpinBox, QSplitter, QStackedWidget, QTableWidget, QTableWidgetItem,
    QTextBrowser, QTextEdit, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
)
from PySide6.QtCore import Qt

from .protocol import CliCall, cli_args

from .. import __version__
from ..agent_skills import default_skills_root
from ..mcp_client import MAX_CONFIG_BYTES, McpConfigError, parse_servers
from ..paths import source_root
from ..security import SecurityError, read_file
from ..session_log import delete_sessions, list_sessions, prune_sessions, session_root
from .branding import logo_pixmap
from .highlight import CodeHighlighter, JsonHighlighter
from .resources import ResourceIndex
from .theme import apply_theme

MAX_TRANSCRIPT = 4 * 1024 * 1024
MCP_TEMPLATE = """{
  "mcpServers": {
    "example": {
      "command": "python",
      "args": ["-m", "your_mcp_server"],
      "env": {},
      "cwd": "."
    }
  }
}
"""


def _label(text="", *, secondary=False):
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    if secondary:
        label.setObjectName("secondaryText")
    return label


def _button(text, callback, *, role=None):
    button = QPushButton(text)
    if role:
        button.setProperty("role", role)
    button.clicked.connect(callback)
    return button


def _size_text(value):
    size = int(value or 0)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} GiB"  # pragma: no cover - loop returns first


def _started_text(value):
    try:
        return datetime.fromisoformat(str(value)).astimezone().strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return str(value).replace("T", " ")[:16]


def _mono(widget):
    widget.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))


class PreviewDialog(QDialog):
    """Read-only preview for transcripts, scripts and Markdown documents."""

    def __init__(self, parent, title, text, *, language="text", path=""):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle(title)
        self.setModal(True)
        self.resize(820, 620)
        layout = QVBoxLayout(self)
        self.path = str(path or "")
        if language == "markdown":
            self.view = QTextBrowser()
            self.view.setOpenExternalLinks(False)
            self.view.setMarkdown(text)
        else:
            self.view = QPlainTextEdit()
            self.view.setReadOnly(True)
            self.view.setLineWrapMode(
                QPlainTextEdit.LineWrapMode.WidgetWidth if language == "text"
                else QPlainTextEdit.LineWrapMode.NoWrap)
            _mono(self.view)
            self.view.setPlainText(text)
            self.highlighter = CodeHighlighter(self.view.document(), language)
        layout.addWidget(self.view, 1)
        row = QHBoxLayout()
        row.addWidget(_button("复制", self.copy))
        if self.path:
            row.addWidget(_button("打开文件", self.open_file))
        row.addStretch()
        row.addWidget(_button("关闭", self.accept))
        layout.addLayout(row)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)

    def copy(self):
        QApplication.clipboard().setText(self.view.toPlainText())
        self.status.setText("已复制到剪贴板")

    def open_file(self):
        QDesktopServices.openUrl(QUrl.fromLocalFile(self.path))
        self.status.setText(self.path)


class McpConfigDialog(QDialog):
    """Edit and validate one operator ``mcpServers`` file.

    Validation uses the same loader as the agent, so the UI cannot accept a
    configuration that the backend would reject. Server command lines and
    environment *values* are never copied into the table or status line.
    """

    def __init__(self, parent, path="", *, base_dir="", parse=parse_servers,
                 confirm=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("MCP 服务配置")
        self.setModal(True)
        self.resize(860, 680)
        self.parser = parse
        self.base_dir = Path(base_dir).absolute() if base_dir else Path.cwd()
        self.confirm = confirm or self._confirm
        self.servers = ()
        self.saved_path = str(path or "")
        self._build()
        if path and Path(path).is_file():
            self._load(Path(path))

    def _build(self):
        layout = QVBoxLayout(self)
        row = QHBoxLayout()
        row.addWidget(_label("配置文件"))
        self.path_edit = QLineEdit(self.saved_path)
        row.addWidget(self.path_edit, 1)
        row.addWidget(_button("选择…", self._pick_existing))
        row.addWidget(_button("新建…", self._pick_new))
        layout.addLayout(row)
        split = QSplitter(Qt.Orientation.Vertical)
        self.editor = QPlainTextEdit()
        self.editor.setPlaceholderText("mcpServers JSON…")
        _mono(self.editor)
        self.highlighter = JsonHighlighter(self.editor.document())
        split.addWidget(self.editor)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["服务器", "命令", "参数", "环境变量"])
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.table.setMaximumHeight(170)
        split.addWidget(self.table)
        split.setSizes([380, 170])
        layout.addWidget(split, 1)
        self.status = _label("配置只在本机加载；外部服务拥有宿主用户权限，不是沙箱。", secondary=True)
        layout.addWidget(self.status)
        actions = QHBoxLayout()
        actions.addWidget(_button("校验配置", self.validate_and_show))
        actions.addWidget(_button("格式化", self.format_text))
        actions.addWidget(_button("插入模板", self.insert_template))
        actions.addStretch()
        actions.addWidget(_button("保存", self.save, role="primary"))
        actions.addWidget(_button("取消", self.reject))
        layout.addLayout(actions)

    def _confirm(self, title, text):
        return QMessageBox.question(
            self, title, text, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes

    def _pick_existing(self):
        chosen, _ = QFileDialog.getOpenFileName(self, "选择 MCP 配置", str(self._base()), "JSON (*.json)")
        if chosen:
            self.path_edit.setText(chosen)
            self._load(Path(chosen))

    def _pick_new(self):
        chosen, _ = QFileDialog.getSaveFileName(self, "新建 MCP 配置", str(self._base()), "JSON (*.json)")
        if chosen:
            self.path_edit.setText(chosen)
            if not self.editor.toPlainText().strip():
                self.editor.setPlainText(MCP_TEMPLATE)

    def _base(self):
        return Path(self.path_edit.text().strip() or self.base_dir).parent

    def _load(self, path):
        try:
            text = read_file(path, MAX_CONFIG_BYTES)
        except (OSError, SecurityError) as exc:
            self.status.setText(f"读取失败：{exc}")
            return
        self.editor.setPlainText(text)
        self.saved_path = str(path)
        self.validate(show=True)

    def validate(self, *, show=True):
        text = self.editor.toPlainText()
        if not text.strip():
            self.servers = ()
            self.table.setRowCount(0)
            if show:
                self.status.setText("配置为空")
            return None
        try:
            servers = self.parser(text, self._base())
        except (McpConfigError, SecurityError, ValueError) as exc:
            self.servers = ()
            self.table.setRowCount(0)
            if show:
                self.status.setText(f"校验失败：{exc}")
            return None
        self.servers = servers
        self.table.setRowCount(len(servers))
        for row, server in enumerate(servers):
            values = [server.name, server.command, " ".join(server.args),
                      ", ".join(sorted(server.env or {}))]
            for column, value in enumerate(values):
                item = QTableWidgetItem(value)
                item.setToolTip(value)
                self.table.setItem(row, column, item)
        if show:
            self.status.setText(f"校验通过：{len(servers)} 个 stdio 服务")
        return servers

    def validate_and_show(self):
        self.validate(show=True)

    def format_text(self):
        try:
            document = json.loads(self.editor.toPlainText())
        except ValueError as exc:
            self.status.setText(f"无法格式化：{exc}")
            return
        self.editor.setPlainText(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
        self.status.setText("已格式化")

    def insert_template(self):
        if self.editor.toPlainText().strip() and not self.confirm(
                "插入模板", "当前内容将被模板替换，继续？"):
            return
        self.editor.setPlainText(MCP_TEMPLATE)

    def save(self):
        servers = self.validate(show=True)
        if servers is None:
            return
        path = self.path_edit.text().strip()
        if not path:
            path, _ = QFileDialog.getSaveFileName(self, "保存 MCP 配置", str(self._base()), "JSON (*.json)")
            if not path:
                return
            self.path_edit.setText(path)
        target = Path(path).expanduser()
        if not target.is_absolute():
            target = self.base_dir / target
        target = target.absolute()
        target.parent.mkdir(parents=True, exist_ok=True)
        text = self.editor.toPlainText()
        if not text.endswith("\n"):
            text += "\n"
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent,
                                             prefix=".mcp-", suffix=".tmp", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(text)
            os.chmod(temporary, 0o600)
            os.replace(temporary, target)
        except OSError as exc:
            if temporary is not None:
                try:
                    temporary.unlink()
                except OSError:
                    pass
            self.status.setText(f"保存失败：{exc}")
            return
        self.saved_path = str(target)
        self.status.setText(f"已保存：{target}")
        self.accept()


class SessionsDialog(QDialog):
    """List, inspect, delete and prune local transcripts."""

    COLUMNS = ("会话", "模式", "机器人", "模型", "大小", "图片", "状态", "更新时间")

    def __init__(self, parent, *, root=None, confirm=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("会话管理")
        self.setModal(True)
        self.resize(900, 620)
        self.root = Path(root).expanduser() if root is not None else None
        self.confirm = confirm or self._confirm
        self.sessions = {}
        self._build()
        self.refresh()

    def _build(self):
        layout = QVBoxLayout(self)
        row = QHBoxLayout()
        self.filter = QLineEdit()
        self.filter.setPlaceholderText("按会话、机器人或模型过滤…")
        self.filter.textChanged.connect(self._apply_filter)
        row.addWidget(self.filter, 1)
        row.addWidget(_button("刷新", self.refresh))
        row.addWidget(_button("查看", self.view))
        row.addWidget(_button("删除", self.delete, role="danger"))
        row.addWidget(_button("打开目录", self.open_folder))
        layout.addLayout(row)
        self.table = QTableWidget(0, len(self.COLUMNS))
        self.table.setHorizontalHeaderLabels(list(self.COLUMNS))
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)
        self.table.setColumnWidth(0, 210)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        for column in (4, 5, 6):
            self.table.horizontalHeader().setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        self.table.setColumnWidth(7, 150)
        self.table.verticalHeader().setVisible(False)
        self.table.doubleClicked.connect(lambda _index: self.view())
        layout.addWidget(self.table, 1)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)
        prune = QGroupBox("清理旧会话（最新 N 个始终保留）")
        form = QFormLayout(prune)
        self.keep = QSpinBox()
        self.keep.setRange(1, 10_000)
        self.keep.setValue(20)
        self.days = QSpinBox()
        self.days.setRange(0, 3650)
        self.days.setSpecialValueText("不限")
        form.addRow("保留最近", self.keep)
        form.addRow("至少早于（天）", self.days)
        buttons = QHBoxLayout()
        buttons.addWidget(_button("预览", lambda: self.prune(True)))
        buttons.addWidget(_button("执行清理", lambda: self.prune(False), role="danger"))
        buttons.addStretch()
        form.addRow(buttons)
        layout.addWidget(prune)
        bottom = QHBoxLayout()
        bottom.addStretch()
        bottom.addWidget(_button("关闭", self.accept))
        layout.addLayout(bottom)

    def _confirm(self, title, text):
        return QMessageBox.question(
            self, title, text, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes

    def _rows(self):
        return list_sessions(self.root)

    def refresh(self):
        sessions = self._rows()
        self.sessions = {item["id"]: item for item in sessions}
        self.table.setRowCount(len(sessions))
        for row, item in enumerate(sessions):
            started = _started_text(item.get("started_at", ""))
            values = (
                item["id"], item.get("mode", ""), item.get("robot", ""), item.get("model", ""),
                _size_text(item.get("bytes", 0)), str(item.get("images", 0)),
                "运行中" if item.get("active") else "已结束", started,
            )
            for column, value in enumerate(values):
                cell = QTableWidgetItem(str(value))
                cell.setToolTip(str(value))
                self.table.setItem(row, column, cell)
        self.status.setText(f"{len(sessions)} 个会话 · {self.root or session_root()}")
        self._apply_filter()

    def _apply_filter(self):
        needle = self.filter.text().strip().lower()
        visible = 0
        for row in range(self.table.rowCount()):
            text = " ".join(self.table.item(row, column).text().lower()
                            for column in range(len(self.COLUMNS))
                            if self.table.item(row, column) is not None)
            hidden = bool(needle) and needle not in text
            self.table.setRowHidden(row, hidden)
            visible += 0 if hidden else 1
        if needle:
            self.status.setText(f"{visible} / {self.table.rowCount()} 个会话匹配")

    def selected_ids(self):
        rows = {index.row() for index in self.table.selectionModel().selectedRows()}
        ids = []
        for row in sorted(rows):
            item = self.table.item(row, 0)
            if item is not None:
                ids.append(item.text())
        return ids

    def view(self):
        ids = self.selected_ids()
        if not ids:
            self.status.setText("先选择一个会话")
            return
        session = self.sessions.get(ids[0])
        if session is None:
            self.refresh()
            return
        directory = Path(session["path"])
        try:
            meta = read_file(directory / "meta.json", 64 * 1024)
            transcript = read_file(directory / "transcript.jsonl", MAX_TRANSCRIPT)
        except (OSError, SecurityError) as exc:
            self.status.setText(f"读取失败：{exc}")
            return
        text = "meta.json\n" + meta.rstrip("\n") + "\n\ntranscript.jsonl\n" + transcript
        PreviewDialog(self, f"会话 {ids[0]}", text, language="text",
                      path=str(directory / "transcript.jsonl")).exec()

    def delete(self):
        ids = self.selected_ids()
        if not ids:
            self.status.setText("先选择要删除的会话")
            return
        if not self.confirm("删除会话", f"永久删除 {len(ids)} 个会话目录（含图片）？"):
            return
        try:
            result = delete_sessions(ids, root=self.root)
        except ValueError as exc:
            self.status.setText(f"删除失败：{exc}")
            return
        self.status.setText(
            f"已删除 {len(result['deleted'])} 个 · 释放 {_size_text(result['bytes_freed'])}"
            + (f" · 跳过 {len(result['skipped'])}" if result["skipped"] else ""))
        self.refresh()

    def prune(self, dry_run):
        days = self.days.value() or None
        try:
            preview = prune_sessions(keep=self.keep.value(), older_than_days=days,
                                     dry_run=True, root=self.root)
        except ValueError as exc:
            self.status.setText(f"清理失败：{exc}")
            return
        if dry_run:
            self.status.setText(
                f"预览：将删除 {len(preview['deleted'])} 个，释放 {_size_text(preview['bytes_freed'])}")
            return
        if not preview["deleted"]:
            self.status.setText("没有可清理的会话")
            return
        if not self.confirm(
                "清理会话",
                f"删除 {len(preview['deleted'])} 个旧会话（释放 {_size_text(preview['bytes_freed'])}）？"):
            return
        try:
            result = prune_sessions(keep=self.keep.value(), older_than_days=days,
                                    dry_run=False, root=self.root)
        except ValueError as exc:
            self.status.setText(f"清理失败：{exc}")
            return
        self.status.setText(
            f"已清理 {len(result['deleted'])} 个 · 释放 {_size_text(result['bytes_freed'])}")
        self.refresh()

    def open_folder(self):
        path = self.root or session_root()
        path.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))


class DoctorDialog(QDialog):
    """Render ``pymybot doctor`` as a status table."""

    def __init__(self, parent, doctor=None):
        super().__init__(parent)
        apply_theme(self)
        from ..cli import doctor as default_doctor
        self._doctor = doctor or default_doctor
        self.payload = {}
        self.setWindowTitle("环境诊断")
        self.setModal(True)
        self.resize(780, 560)
        layout = QVBoxLayout(self)
        self.summary = _label()
        layout.addWidget(self.summary)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["检查项", "状态", "版本", "说明"])
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        layout.addWidget(self.table, 1)
        row = QHBoxLayout()
        row.addWidget(_button("刷新", self.refresh))
        row.addWidget(_button("复制 JSON", self.copy))
        row.addStretch()
        row.addWidget(_button("关闭", self.accept))
        layout.addLayout(row)
        self.refresh()

    def refresh(self):
        try:
            self.payload = self._doctor()
        except Exception as exc:
            self.summary.setText(f"诊断失败：{type(exc).__name__}: {exc}")
            self.table.setRowCount(0)
            return
        healthy = bool(self.payload.get("healthy"))
        self.summary.setText(
            f"pymybot {self.payload.get('version', '?')} · Python {self.payload.get('python', '?')} · "
            f"{'健康' if healthy else '需要处理'}\n{self.payload.get('platform', '')}")
        checks = self.payload.get("checks") or []
        self.table.setRowCount(len(checks))
        colors = {"ok": "#1d6b45", "warning": "#9a4a00", "missing": "#b42332"}
        for row, check in enumerate(checks):
            status = str(check.get("status", ""))
            values = (
                str(check.get("label") or check.get("name", "")),
                status,
                str(check.get("version", "")),
                str(check.get("hint") or check.get("error", "")),
            )
            for column, value in enumerate(values):
                item = QTableWidgetItem(value)
                item.setToolTip(value)
                if column == 1:
                    item.setForeground(QColor(colors.get(status, "#243247")))
                self.table.setItem(row, column, item)

    def copy(self):
        QApplication.clipboard().setText(json.dumps(self.payload, indent=2, ensure_ascii=False))
        self.summary.setText("诊断 JSON 已复制到剪贴板")


class _CommandTask(QRunnable):
    """Qt thread-pool adapter; results cross back through the dialog's signal."""

    def __init__(self, dialog, argv):
        super().__init__()
        self.dialog = dialog
        self.argv = argv

    def run(self):
        try:
            result = self.dialog.runner(self.argv, self.dialog.cwd)
        except Exception as exc:
            result = {"code": None, "error": f"{type(exc).__name__}: {exc}"}
        try:
            self.dialog.completed.emit(result)
        except RuntimeError:  # the dialog was closed while the child ran
            pass


class CommandDialog(QDialog):
    """Run any one-shot backend command and show its JSON contract.

    This is a developer console, not a second implementation: argv comes from
    ``cli_args`` and execution from the same ``python -m pymybot`` child the
    hardware tree uses. Modes with their own lifecycle (serve/mcp/agent) are
    deliberately absent.
    """

    completed = Signal(object)
    COMMANDS = (
        ("check", "静态检查"), ("hardware", "列出硬件"), ("scripts", "列出脚本"),
        ("query", "只读查询 SQL"), ("run", "执行动作脚本"), ("sample", "采样变量"),
        ("apply-sql", "临时应用 SQL"), ("doctor", "环境诊断"), ("sessions", "会话列表"),
    )

    def __init__(self, parent, *, python, cwd, robot="", module_paths=(), camera_src_dir="",
                 scripts_dir="", timeout=180, runner=None, confirm=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("命令面板")
        self.setModal(True)
        self.resize(900, 720)
        self.python = python
        self.cwd = cwd
        self.module_paths = tuple(module_paths)
        self.camera_src_dir = camera_src_dir
        self.scripts_dir = scripts_dir
        self.robot = robot
        self.runner = runner or self._run_cli
        self.confirm = confirm or self._confirm
        self._running = False
        self.completed.connect(self._done)
        self._build(timeout)
        self.command_changed()

    def _build(self, timeout):
        layout = QVBoxLayout(self)
        row = QHBoxLayout()
        row.addWidget(_label("命令"))
        self.command = QComboBox()
        for name, label in self.COMMANDS:
            self.command.addItem(f"{name} · {label}", name)
        self.command.currentIndexChanged.connect(self.command_changed)
        row.addWidget(self.command, 1)
        self.hardware = QCheckBox("允许硬件")
        row.addWidget(self.hardware)
        layout.addLayout(row)
        form = QFormLayout()
        self.robot_edit = QLineEdit(self.robot)
        form.addRow("结构 SQL", self.robot_edit)
        self.script = QComboBox()
        self.script.setEditable(True)
        self._fill_scripts()
        form.addRow("动作脚本", self.script)
        self.sql = QPlainTextEdit()
        self.sql.setPlaceholderText("SHOW TABLES; 或 SELECT * FROM ...;")
        self.sql.setMaximumHeight(90)
        _mono(self.sql)
        form.addRow("SQL", self.sql)
        self.variable = QLineEdit()
        self.variable.setPlaceholderText("变量名")
        form.addRow("采样变量", self.variable)
        self.count = QSpinBox()
        self.count.setRange(1, 1000)
        self.interval = QSpinBox()
        self.interval.setRange(0, 60_000)
        self.interval.setSuffix(" ms")
        self.timeout = QDoubleSpinBox()
        self.timeout.setRange(0.1, 3600)
        self.timeout.setValue(float(timeout))
        self.timeout.setSuffix(" s")
        form.addRow("采样次数", self.count)
        form.addRow("采样间隔", self.interval)
        form.addRow("超时", self.timeout)
        layout.addLayout(form)
        self.preview = _label("", secondary=True)
        _mono(self.preview)
        layout.addWidget(self.preview)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.progress.hide()
        layout.addWidget(self.progress)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setLineWrapMode(QPlainTextEdit.LineWrapMode.WidgetWidth)
        _mono(self.output)
        self.output.setPlaceholderText("命令输出…")
        layout.addWidget(self.output, 1)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)
        actions = QHBoxLayout()
        self.run_button = _button("运行", self.run, role="primary")
        actions.addWidget(self.run_button)
        actions.addWidget(_button("复制命令", self.copy_command))
        actions.addWidget(_button("复制输出", self.copy_output))
        actions.addStretch()
        actions.addWidget(_button("关闭", self.accept))
        layout.addLayout(actions)
        for widget in (self.robot_edit, self.script, self.sql, self.variable,
                       self.count, self.interval, self.timeout, self.hardware):
            try:
                widget.currentTextChanged.connect(self.update_preview)
            except AttributeError:
                pass
            try:
                widget.textChanged.connect(self.update_preview)
            except AttributeError:
                pass
            try:
                widget.valueChanged.connect(self.update_preview)
            except AttributeError:
                pass
            try:
                widget.toggled.connect(self.update_preview)
            except AttributeError:
                pass
        self.update_preview()

    def _fill_scripts(self):
        self.script.addItem("")
        root = Path(self.scripts_dir) if self.scripts_dir else None
        if root is None or not root.is_dir():
            return
        found = []
        for base, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = sorted(name for name in dirs if not (Path(base) / name).is_symlink())
            for name in sorted(files):
                path = Path(base) / name
                if path.suffix == ".mt" and not path.is_symlink() and path.is_file():
                    found.append(path.relative_to(root).as_posix())
                if len(found) >= 1000:
                    break
        self.script.addItems(sorted(found))

    def _confirm(self, title, text):
        return QMessageBox.question(
            self, title, text, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes

    @property
    def name(self):
        return self.command.currentData()

    def command_changed(self):
        command = self.name
        needs_robot = command in {"check", "hardware", "query", "run", "sample", "apply-sql"}
        self.robot_edit.setEnabled(needs_robot)
        self.script.setEnabled(command in {"check", "run"})
        self.sql.setEnabled(command in {"query", "apply-sql"})
        self.variable.setEnabled(command == "sample")
        self.count.setEnabled(command == "sample")
        self.interval.setEnabled(command == "sample")
        self.timeout.setEnabled(command in {"run", "sample", "apply-sql"})
        self.hardware.setEnabled(command in {"run", "sample", "apply-sql"})
        if not self.hardware.isEnabled():
            self.hardware.setChecked(False)
        self.output.clear()
        self.status.setText("")
        self.update_preview()

    def build_argv(self):
        kwargs = {
            "robot": self.robot_edit.text().strip(),
            "script": self.script.currentText().strip(),
            "sql": self.sql.toPlainText().strip(),
            "name": self.variable.text().strip(),
            "count": self.count.value(),
            "interval_ms": self.interval.value(),
            "timeout": self.timeout.value(),
            "allow_hardware": self.hardware.isChecked(),
            "module_paths": self.module_paths,
            "camera_src_dir": self.camera_src_dir,
            "scripts_dir": self.scripts_dir,
        }
        return cli_args(self.name, **kwargs)

    def update_preview(self):
        try:
            argv = self.build_argv()
        except ValueError as exc:
            self.preview.setText(f"参数不完整：{exc}")
            return
        self.preview.setText(" ".join(argv))

    def run(self):
        if self._running:
            return
        try:
            argv = self.build_argv()
        except ValueError as exc:
            self.status.setText(f"参数不完整：{exc}")
            return
        if self.hardware.isChecked() and not self.confirm(
                "确认硬件权限", "该命令会激活机器人并可能写硬件；只对可信结构执行。"):
            return
        self._running = True
        self.run_button.setEnabled(False)
        self.progress.show()
        self.status.setText("运行中…")
        self.output.clear()
        QThreadPool.globalInstance().start(_CommandTask(self, argv))

    def _done(self, result):
        self._running = False
        self.run_button.setEnabled(True)
        self.progress.hide()
        if result.get("error"):
            self.status.setText(result["error"])
            self.output.setPlainText(result["error"])
            return
        payload = result.get("json")
        if payload is not None:
            self.output.setPlainText(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            self.output.setPlainText(str(result.get("stdout") or ""))
        code = result.get("code")
        duration = result.get("duration_ms")
        failed = (payload is not None and not payload.get("ok")) or code not in (0, None)
        self.status.setText(f"退出码 {code}" + (f" · {duration} ms" if duration is not None else "")
                            + (" · 命令失败" if failed else ""))
        if failed and result.get("stderr"):
            self.output.appendPlainText("\nstderr:\n" + str(result.get("stderr")))

    def copy_command(self):
        QApplication.clipboard().setText(self.preview.text())
        self.status.setText("命令已复制")

    def copy_output(self):
        QApplication.clipboard().setText(self.output.toPlainText())
        self.status.setText("输出已复制")

    def _run_cli(self, argv, cwd):
        call = CliCall(self.python, argv, cwd)
        result = call.wait()
        return {"code": result.code, "json": result.json, "stdout": result.stdout,
                "stderr": result.stderr[-4000:], "duration_ms": result.duration_ms}


class AboutDialog(QDialog):
    def __init__(self, parent):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("关于")
        self.setModal(True)
        self.resize(560, 340)
        layout = QVBoxLayout(self)
        logo = QLabel()
        logo.setPixmap(logo_pixmap(72))
        logo.setFixedSize(72, 72)
        layout.addWidget(logo)
        layout.addWidget(_label(f"MYBOT · pymybot {__version__}"))
        layout.addWidget(_label(
            "结构 SQL + Lua 驱动 + MT 动作，同一套执行器提供 GUI、CLI、Agent 与 MCP。\n"
            "Shell 使用沙箱后端；外部 MCP 服务拥有宿主用户权限，不是沙箱。", secondary=True))
        layout.addWidget(_label(f"Qt {self._qt_version()} · Python {sys.version.split()[0]}", secondary=True))
        row = QHBoxLayout()
        row.addWidget(_button("项目文档", self.open_docs))
        row.addWidget(_button("GitHub", lambda: QDesktopServices.openUrl(
            QUrl("https://github.com/gopsc/mybot"))))
        row.addStretch()
        row.addWidget(_button("关闭", self.accept))
        layout.addStretch()
        layout.addLayout(row)

    @staticmethod
    def _qt_version():
        from PySide6 import __version__ as qt
        return qt

    def open_docs(self):
        path = source_root() / "docs" / "README.md"
        if path.is_file():
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
        else:
            QDesktopServices.openUrl(QUrl("https://github.com/gopsc/mybot/tree/gui-mybot/docs"))


class ResourcePanel(QWidget):
    """Lazy, cached browser for action scripts, skills and source-tree docs."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.index = ResourceIndex(None)
        self.loaded = False
        self._pending = False
        self._fade = None
        self._effect = None
        self._build()

    def _build(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        row = QHBoxLayout()
        self.filter = QLineEdit()
        self.filter.setPlaceholderText("过滤资源…")
        self.filter.textChanged.connect(self._apply_filter)
        row.addWidget(self.filter, 1)
        row.addWidget(_button("刷新", self.reload))
        row.addWidget(_button("打开", self.open_selected))
        row.addWidget(_button("复制路径", self.copy_path))
        layout.addLayout(row)
        split = QSplitter(Qt.Orientation.Horizontal)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["资源", "大小"])
        self.tree.setColumnWidth(0, 240)
        self.tree.setAlternatingRowColors(True)
        self.tree.itemSelectionChanged.connect(self._on_select)
        self.tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected())
        split.addWidget(self.tree)
        self.preview = QStackedWidget()
        self.placeholder = _label("选择一个脚本、技能或文档预览", secondary=True)
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.markdown = QTextBrowser()
        self.markdown.setOpenExternalLinks(False)
        self.markdown.setLineWrapMode(QTextEdit.LineWrapMode.WidgetWidth)
        self.code = QPlainTextEdit()
        self.code.setReadOnly(True)
        self.code.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        _mono(self.code)
        self.highlighter = CodeHighlighter(self.code.document(), "mt")
        self.preview.addWidget(self.placeholder)
        self.preview.addWidget(self.markdown)
        self.preview.addWidget(self.code)
        split.addWidget(self.preview)
        split.setSizes([300, 620])
        layout.addWidget(split, 1)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)
        self.watcher = QFileSystemWatcher(self)
        self.watcher.directoryChanged.connect(self._schedule_reload)
        self._reload_timer = QTimer(self)
        self._reload_timer.setSingleShot(True)
        self._reload_timer.timeout.connect(self._auto_reload)

    def set_roots(self, scripts_root, skills_root=None, robots_root=None, module_paths=()):
        self.index = ResourceIndex(scripts_root, skills_root or default_skills_root(),
                                   robots_root=robots_root, module_paths=module_paths)
        self._watch_roots()
        if self.loaded:
            self.reload()

    def _watch_roots(self):
        paths = set()
        for root in (self.index.scripts_root, self.index.skills_root,
                     self.index.docs_root, self.index.robots_root, *self.index.module_paths):
            if root is None or not root.is_dir():
                continue
            paths.add(str(root))
            try:
                for child in list(root.iterdir())[:40]:
                    if child.is_dir() and not child.is_symlink():
                        paths.add(str(child))
            except OSError:
                continue
        existing = self.watcher.directories()
        if existing:
            self.watcher.removePaths(existing)
        for path in sorted(paths):
            self.watcher.addPath(path)

    def _schedule_reload(self, *_args):
        if self.loaded:
            self._reload_timer.start(400)

    def _auto_reload(self):
        if self.loaded and not self._pending:
            self.reload()

    def ensure_loaded(self):
        if self.loaded or self._pending:
            return
        self._pending = True
        QTimer.singleShot(0, self._load_once)

    def _load_once(self):
        self._pending = False
        if not self.loaded:
            self.loaded = True
            self.reload()

    def reload(self):
        self.index.refresh()
        self.tree.clear()
        groups = {}
        for resource in self.index.items:
            group = groups.get(resource.group)
            if group is None:
                group = QTreeWidgetItem(self.tree, [resource.group, ""])
                group.setFirstColumnSpanned(True)
                groups[resource.group] = group
            item = QTreeWidgetItem(group, [resource.name, _size_text(resource.size)])
            item.setData(0, Qt.ItemDataRole.UserRole, resource)
            item.setToolTip(0, resource.path)
        self.tree.expandAll()
        errors = "；".join(self.index.errors)
        self.status.setText(f"{len(self.index.items)} 个资源" + (f" · {errors}" if errors else ""))
        self._apply_filter()
        self._watch_roots()
        if self.index.items and self.tree.topLevelItemCount():
            first_group = self.tree.topLevelItem(0)
            if first_group.childCount():
                self.tree.setCurrentItem(first_group.child(0))

    def _animate_preview(self):
        if self._effect is None:
            self._effect = QGraphicsOpacityEffect(self.preview)
            self.preview.setGraphicsEffect(self._effect)
        self._fade = QPropertyAnimation(self._effect, b"opacity", self)
        self._fade.setDuration(140)
        self._fade.setStartValue(0.25)
        self._fade.setEndValue(1.0)
        self._fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._fade.start()

    def _apply_filter(self):
        needle = self.filter.text().strip().lower()
        for group_index in range(self.tree.topLevelItemCount()):
            group = self.tree.topLevelItem(group_index)
            visible = 0
            for child_index in range(group.childCount()):
                child = group.child(child_index)
                hidden = bool(needle) and needle not in child.text(0).lower()
                child.setHidden(hidden)
                visible += 0 if hidden else 1
            group.setHidden(bool(needle) and visible == 0)

    def _selected(self):
        item = self.tree.currentItem()
        if item is None or item.parent() is None:
            return None
        return item.data(0, Qt.ItemDataRole.UserRole)

    def _on_select(self):
        resource = self._selected()
        if resource is None:
            self.preview.setCurrentWidget(self.placeholder)
            return
        try:
            text = self.index.read(resource)
        except (OSError, SecurityError) as exc:
            self.placeholder.setText(f"无法预览：{exc}")
            self.preview.setCurrentWidget(self.placeholder)
            self.status.setText(str(exc))
            return
        if resource.language == "markdown":
            self.markdown.setMarkdown(text)
            self.preview.setCurrentWidget(self.markdown)
        else:
            self.highlighter.set_language(resource.language)
            self.code.setPlainText(text)
            self.preview.setCurrentWidget(self.code)
        self._animate_preview()
        self.status.setText(f"{resource.path} · {_size_text(resource.size)}")

    def open_selected(self):
        resource = self._selected()
        if resource is not None:
            QDesktopServices.openUrl(QUrl.fromLocalFile(resource.path))

    def copy_path(self):
        resource = self._selected()
        if resource is not None:
            QApplication.clipboard().setText(resource.path)
            self.status.setText("路径已复制")
