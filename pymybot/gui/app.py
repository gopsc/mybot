"""Native Qt window over the long-lived ``pymybot serve`` process."""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import QEventLoop, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QFontDatabase, QKeySequence, QPalette, QShortcut, QTextCharFormat, QTextCursor
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDoubleSpinBox, QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QLabel,
    QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit, QPushButton,
    QScrollArea, QSpinBox, QSplitter, QTabWidget, QTreeWidget, QTreeWidgetItem,
    QVBoxLayout, QWidget,
)

from . import GuiUnavailable
from .config import GuiConfig, config_home, default_workspace, merge_args
from .protocol import CANCELLED, CliCall, RpcError, ServeClient, cli_args, resolve_python

TITLE = "mybot · 智能体"
MAX_DIALOG_ARGS = 4000
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
QLineEdit, QPlainTextEdit, QTreeWidget {
    background: #ffffff; color: #243247; border: 1px solid #b8c3d2;
    border-radius: 5px; padding: 4px 6px; placeholder-text-color: #59677a;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QComboBox, QAbstractSpinBox {
    background: #ffffff; color: #243247; min-height: 1.8em;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QLineEdit:focus, QPlainTextEdit:focus, QTreeWidget:focus {
    border: 1px solid #245cc5;
}
QLineEdit:disabled, QPlainTextEdit:disabled, QComboBox:disabled, QAbstractSpinBox:disabled {
    color: #606d7e; background: #edf0f4; border-color: #d4dbe5;
}
QComboBox QAbstractItemView {
    background: #ffffff; color: #243247;
    selection-background-color: #245cc5; selection-color: #ffffff;
}
QPlainTextEdit#chatTranscript { padding: 10px; border: none; }
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
QTreeWidget { alternate-background-color: #f3f6fa; }
QTreeWidget::item { padding: 3px 0; }
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
QToolTip { background: #243247; color: #ffffff; border: none; padding: 5px 8px; }
"""


def _apply_theme(window):
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


def _brief(value, limit=160):
    if value is None:
        return ""
    try:
        text = json.dumps(value, ensure_ascii=False, sort_keys=False)
    except (TypeError, ValueError):
        text = str(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _absolute(path, root):
    text = str(path or "").strip()
    if not text:
        return ""
    candidate = Path(text)
    return str(candidate if candidate.is_absolute() else Path(root or ".").absolute() / candidate)


def _parse_bindings(text):
    bindings = {}
    for line in str(text).splitlines():
        name, separator, value = line.strip().partition("=")
        if separator and name.strip().isidentifier():
            bindings[name.strip()] = value
    return bindings


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


def _spin(value, maximum, fractional=False):
    box = QDoubleSpinBox() if fractional else QSpinBox()
    box.setRange(0.01 if fractional else 1, maximum)
    box.setValue(value)
    return box


class App(QMainWindow):
    closed = Signal()

    def __init__(self, config: GuiConfig, config_path: Path):
        super().__init__()
        self.cfg = config
        self.config_path = Path(config_path)
        self.queue = queue.Queue()
        self.serve: ServeClient | None = None
        self.starting = False
        self._restart_pending = False
        self._retiring = False
        self.generation = 0
        self.greeted = False
        self.serve_state = "未启动"
        self.agent_available = False
        self.busy = False
        self.turn_id = None
        self.turn_text = 0
        self.at_line_start = True
        self.pending_task = ""
        self._stopping = False
        self._lifecycle_lock = threading.Lock()
        self._clients = {}
        self._lifecycle_workers = []
        self._hardware_calls = set()
        self._hardware_generation = 0
        self._dialogs = set()
        self.font_mono = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)

        _apply_theme(self)
        self._build()
        self._notice_timer = QTimer(self)
        self._notice_timer.setSingleShot(True)
        self._notice_timer.timeout.connect(lambda: self.status_notice.setText(""))
        self._pump_timer = QTimer(self)
        self._pump_timer.timeout.connect(self._pump)
        self._pump_timer.start(30)
        self._start_timer = QTimer(self)
        self._start_timer.setSingleShot(True)
        self._start_timer.timeout.connect(self._start_server)
        self._load_robot_list()
        self._refresh_hardware()
        self._start_timer.start(120)
        self.task_box.setPlainText(self.cfg.task.strip())
        self._refresh_status()

    def _build(self):
        self.setWindowTitle(TITLE)
        self.resize(1180, 780)
        self.setMinimumSize(900, 600)
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        toolbar = QHBoxLayout()
        layout.addLayout(toolbar)
        toolbar.addWidget(_button("打开工作区", self.pick_workspace))
        self.workspace_label = _label()
        self.workspace_label.setMaximumWidth(220)
        toolbar.addWidget(self.workspace_label)
        toolbar.addWidget(_label("结构"))
        self.robot_box = QComboBox()
        self.robot_box.setMinimumWidth(180)
        self.robot_box.activated.connect(self.on_robot_changed)
        toolbar.addWidget(self.robot_box, 1)
        toolbar.addWidget(_button("选择 SQL", self.pick_robot))
        toolbar.addWidget(_button("刷新", self.refresh_context))
        self.new_button = _button("新对话", self.new_conversation)
        self.stop_button = _button("停止", self.stop_turn, role="danger")
        toolbar.addWidget(self.new_button)
        toolbar.addWidget(self.stop_button)
        toolbar.addWidget(_button("设置", self.open_settings))

        body = QSplitter(Qt.Orientation.Horizontal)
        layout.addWidget(body, 1)
        side_scroll = QScrollArea()
        side_scroll.setWidgetResizable(True)
        side_scroll.setMinimumWidth(280)
        side = QWidget()
        side_scroll.setWidget(side)
        self._build_side(side)
        body.addWidget(side_scroll)
        right = QWidget()
        self._build_chat(right)
        body.addWidget(right)
        body.setStretchFactor(0, 0)
        body.setStretchFactor(1, 1)
        body.setSizes([350, 810])

        self.status_state = _label()
        self.status_agent = _label()
        self.status_busy = _label()
        self.status_notice = _label()
        for label in (self.status_state, self.status_agent, self.status_busy, self.status_notice):
            self.statusBar().addWidget(label)

    def _build_side(self, side):
        layout = QVBoxLayout(side)
        robot = QGroupBox("机器人上下文")
        form = QFormLayout(robot)
        self.context_entries = {}
        fields = (
            ("scripts_dir", "脚本根目录", True), ("skills_dir", "技能目录", True),
            ("module_paths", "模块路径", False), ("camera_src_dir", "图片源目录", True),
        )
        for name, label, browse in fields:
            row = QHBoxLayout()
            value = getattr(self.cfg, name)
            entry = QLineEdit(os.pathsep.join(value) if name == "module_paths" else value)
            entry.editingFinished.connect(self._sync_config)
            self.context_entries[name] = entry
            row.addWidget(entry)
            if browse:
                row.addWidget(_button("…", lambda checked=False, e=entry: self._browse_into(e)))
            form.addRow(label, row)
        layout.addWidget(robot)

        hardware = QGroupBox("硬件")
        hw_layout = QVBoxLayout(hardware)
        self.hardware_tree = QTreeWidget()
        self.hardware_tree.setHeaderLabels(["变量", "驱动", "配置"])
        self.hardware_tree.setRootIsDecorated(False)
        self.hardware_tree.setAlternatingRowColors(True)
        self.hardware_tree.setMinimumHeight(140)
        self.hardware_tree.setColumnWidth(0, 90)
        self.hardware_tree.setColumnWidth(1, 80)
        hw_layout.addWidget(self.hardware_tree)
        self.hardware_note = _label("选择结构后自动读取", secondary=True)
        hw_layout.addWidget(self.hardware_note)
        layout.addWidget(hardware)

        guard = QGroupBox("权限与预算（每次启动重新确认）")
        form = QFormLayout(guard)
        self.hardware_toggle = QCheckBox("允许硬件（--allow-hardware）")
        self.hardware_toggle.setChecked(bool(self.cfg.allow_hardware))
        self.actions_toggle = QCheckBox("自动批准动作（不再逐次确认）")
        self.actions_toggle.setChecked(bool(self.cfg.allow_actions))
        for toggle in (self.hardware_toggle, self.actions_toggle):
            toggle.toggled.connect(self.on_permission_toggle)
            form.addRow(toggle)
        self.read_vars_entry = QLineEdit(",".join(self.cfg.read_vars))
        self.camera_vars_entry = QLineEdit(",".join(self.cfg.camera_vars))
        form.addRow("读取变量", self.read_vars_entry)
        form.addRow("相机变量", self.camera_vars_entry)
        self.timeout_box = _spin(self.cfg.timeout, 3600, fractional=True)
        self.requests_box = _spin(self.cfg.max_requests, 100)
        self.tools_box = _spin(self.cfg.max_tool_calls, 1000)
        form.addRow("超时（秒）", self.timeout_box)
        form.addRow("请求预算", self.requests_box)
        form.addRow("工具预算", self.tools_box)
        layout.addWidget(guard)
        model = QGroupBox("模型（在设置中修改）")
        model_layout = QVBoxLayout(model)
        self.model_label = _label()
        model_layout.addWidget(self.model_label)
        layout.addWidget(model)
        layout.addStretch()
        self._refresh_model_label()

    def _build_chat(self, right):
        layout = QVBoxLayout(right)
        layout.setContentsMargins(0, 0, 0, 0)
        self.notebook = QTabWidget()
        self.chat = QPlainTextEdit()
        self.chat.setReadOnly(True)
        self.chat.setObjectName("chatTranscript")
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(self.font_mono)
        self.log.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.log.setObjectName("eventLog")
        self.notebook.addTab(self.chat, "对话")
        self.notebook.addTab(self.log, "日志")
        layout.addWidget(self.notebook, 1)
        composer = QHBoxLayout()
        self.task_box = QPlainTextEdit()
        self.task_box.setPlaceholderText("与机器人对话…")
        self.task_box.setMaximumHeight(100)
        composer.addWidget(self.task_box, 1)
        buttons = QVBoxLayout()
        self.send_button = _button("发送", self.send_task, role="primary")
        buttons.addWidget(self.send_button)
        buttons.addWidget(_label("Ctrl+Enter", secondary=True))
        composer.addLayout(buttons)
        layout.addLayout(composer)
        self.send_shortcuts = []
        for key in ("Ctrl+Return", "Ctrl+Enter"):
            shortcut = QShortcut(QKeySequence(key), self.task_box)
            shortcut.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
            shortcut.activated.connect(self.send_task)
            self.send_shortcuts.append(shortcut)

    def post(self, callback):
        """Only the Qt timer consumes callbacks; cleanup never depends on it."""
        if not self._stopping:
            self.queue.put(callback)

    def _pump(self):
        for _ in range(200):
            if self._stopping:
                return
            try:
                callback = self.queue.get_nowait()
            except queue.Empty:
                return
            try:
                callback()
            except Exception as exc:
                print(f"pymybot gui: {type(exc).__name__}: {exc}", file=sys.stderr)

    def _background(self, fn, done=None, *, lifecycle=False):
        def run():
            try:
                value = fn()
            except Exception as exc:
                if done is not None:
                    self.post(lambda error=exc: done(None, error))
            else:
                if done is not None:
                    self.post(lambda: done(value, None))

        thread = threading.Thread(target=run, daemon=not lifecycle)
        if lifecycle:
            with self._lifecycle_lock:
                self._lifecycle_workers = [worker for worker in self._lifecycle_workers if worker.is_alive()]
                self._lifecycle_workers.append(thread)
        thread.start()

    def _notice(self, text, seconds=8):
        if self._stopping:
            return
        self.status_notice.setText(text)
        self._notice_timer.start(int(seconds * 1000))

    def _insert_text(self, widget, text, tag=None):
        cursor = widget.textCursor()
        cursor.movePosition(QTextCursor.MoveOperation.End)
        fmt = QTextCharFormat()
        if tag:
            fmt.setForeground(QColor(PALETTE[tag]))
            if tag in {"tool", "toolerr"}:
                fmt.setFont(self.font_mono)
            if tag == "user":
                fmt.setFontWeight(QFont.Weight.Bold)
            if tag == "system":
                fmt.setFontItalic(True)
        cursor.insertText(text, fmt)
        widget.setTextCursor(cursor)
        widget.ensureCursorVisible()

    def _log(self, chunk):
        if chunk and not self._stopping:
            self._insert_text(self.log, chunk if chunk.endswith("\n") else chunk + "\n")

    def _chat_line(self, text, tag=None):
        if self._stopping:
            return
        self._insert_text(self.chat, ("" if self.at_line_start else "\n") + text + "\n", tag)
        self.at_line_start = True

    def _chat_delta(self, text):
        if text and not self._stopping:
            self._insert_text(self.chat, text, "assistant")
            self.at_line_start = text.endswith("\n")
            self.turn_text += len(text)

    def _exec_dialog(self, dialog):
        self._dialogs.add(dialog)
        try:
            return dialog.exec()
        finally:
            self._dialogs.discard(dialog)
            dialog.deleteLater()

    def _message(self, title, text, *, confirm=False):
        dialog = QMessageBox(self)
        _apply_theme(dialog)
        dialog.setWindowTitle(title)
        dialog.setTextFormat(Qt.TextFormat.PlainText)
        dialog.setText(text)
        dialog.setIcon(QMessageBox.Icon.Warning)
        buttons = QMessageBox.StandardButton.Ok
        if confirm:
            buttons |= QMessageBox.StandardButton.Cancel
        dialog.setStandardButtons(buttons)
        dialog.setDefaultButton(QMessageBox.StandardButton.Cancel if confirm else QMessageBox.StandardButton.Ok)
        return self._exec_dialog(dialog) == QMessageBox.StandardButton.Ok

    def _sync_config(self):
        for name, entry in self.context_entries.items():
            value = entry.text().strip()
            setattr(self.cfg, name, [item.strip() for item in value.split(os.pathsep) if item.strip()]
                    if name == "module_paths" else value)
        self.cfg.read_vars = self._names(self.read_vars_entry.text())
        self.cfg.camera_vars = self._names(self.camera_vars_entry.text())
        self.cfg.timeout = self.timeout_box.value()
        self.cfg.max_requests = self.requests_box.value()
        self.cfg.max_tool_calls = self.tools_box.value()

    def _sync_controls(self):
        for name, entry in self.context_entries.items():
            value = getattr(self.cfg, name)
            entry.setText(os.pathsep.join(value) if name == "module_paths" else value)
        self.read_vars_entry.setText(",".join(self.cfg.read_vars))
        self.camera_vars_entry.setText(",".join(self.cfg.camera_vars))
        self.timeout_box.setValue(self.cfg.timeout)
        self.requests_box.setValue(self.cfg.max_requests)
        self.tools_box.setValue(self.cfg.max_tool_calls)

    def _browse_into(self, entry):
        chosen = QFileDialog.getExistingDirectory(self, "选择目录", self.cfg.workspace or default_workspace())
        if chosen:
            entry.setText(chosen)
            self._sync_config()

    def _refresh_model_label(self):
        model = self.cfg.model or os.environ.get("MYBOT_MODEL", "")
        key_env = self.cfg.api_key_env or "厂商默认变量"
        endpoint = self.cfg.base_url or "厂商默认"
        self.model_label.setText(f"模型：{model or '未设置（需 MYBOT_MODEL）'}\n端点：{endpoint}\n密钥变量：{key_env}")

    def pick_workspace(self):
        chosen = QFileDialog.getExistingDirectory(self, "打开工作区", self.cfg.workspace or default_workspace())
        if not chosen or self._stopping:
            return
        self.cfg.workspace = chosen
        self.cfg.robot = ""
        self.refresh_context()
        self._restart_server()

    def pick_robot(self):
        chosen, _ = QFileDialog.getOpenFileName(
            self, "选择机器人结构", self.cfg.workspace or default_workspace(), "SQL (*.sql)")
        if chosen and not self._stopping:
            self.cfg.robot = chosen
            self.refresh_context()

    def _load_robot_list(self):
        root = Path(self.cfg.workspace or default_workspace()).absolute()
        self.workspace_label.setText(str(root))
        found = []
        for base in (root / "robots", root):
            if base.is_dir():
                found.extend(str(path) for path in sorted(base.glob("*.sql")) if path.is_file())
        current = self._robot_path()
        if current and Path(current).is_file():
            found.insert(0, current)
        unique = list(dict.fromkeys(found))
        self.robot_box.clear()
        for path in unique:
            try:
                shown = Path(os.path.relpath(path, root)).as_posix()
            except ValueError:
                shown = path
            self.robot_box.addItem(shown, path)
        index = self.robot_box.findData(current)
        self.robot_box.setCurrentIndex(index if index >= 0 else (0 if unique else -1))
        self.cfg.robot = self.robot_box.currentData() or ""

    def on_robot_changed(self):
        self.cfg.robot = self.robot_box.currentData() or ""
        self._refresh_hardware()

    def _robot_path(self):
        return _absolute(self.cfg.robot, self.cfg.workspace or default_workspace())

    def _scripts_root(self):
        root = self.cfg.workspace or default_workspace()
        configured = _absolute(self.cfg.scripts_dir, root)
        if configured:
            return configured
        candidate = Path(root).absolute() / "scripts"
        return str(candidate if candidate.is_dir() else Path(root).absolute())

    def _module_paths(self):
        root = self.cfg.workspace or default_workspace()
        return [_absolute(item, root) for item in self.cfg.module_paths if str(item).strip()]

    def _stop_client(self, client):
        with self._lifecycle_lock:
            event = self._clients.get(client)
            owner = event is None
            if owner:
                event = self._clients[client] = threading.Event()
        if not owner:
            event.wait()
            return
        try:
            client.stop(grace=1)
        except Exception as exc:
            print(f"pymybot gui: stop failed: {exc}", file=sys.stderr)
        finally:
            with self._lifecycle_lock:
                event.set()
                self._clients.pop(client, None)

    def _start_server(self):
        if self.serve is not None or self.starting or self._retiring or self._stopping:
            return
        self._start_timer.stop()
        self.starting = True
        self._restart_pending = False
        self.generation += 1
        generation = self.generation
        self.serve_state = "启动中…"
        self._refresh_status()
        workspace = self.cfg.workspace or default_workspace()
        python = resolve_python(workspace, self.cfg.python)
        serve_args = ["-m", "pymybot", "serve"]
        if not self.cfg.session_log:
            serve_args.append("--no-session-log")

        def work():
            client = ServeClient(
                python, workspace, python_args=tuple(serve_args),
                on_notify=lambda method, params: self.post(lambda: self._on_notify(generation, method, params)),
                on_request=lambda ident, method, params: self.post(
                    lambda: self._on_request(generation, ident, method, params)),
                on_stderr=lambda chunk: self.post(lambda: self._server_log(generation, chunk)),
                on_exit=lambda code: self.post(lambda: self._on_serve_exit(generation, code)),
            )
            with self._lifecycle_lock:
                self._clients[client] = None
                stopping = self._stopping
            try:
                if stopping:
                    raise RpcError("GUI closed during startup")
                info = client.request("initialize", timeout=90)
                if self._stopping:
                    raise RpcError("GUI closed during startup")
                return client, info
            except BaseException:
                self._stop_client(client)
                raise

        self._background(work, lambda value, error: self._server_started(generation, value, error), lifecycle=True)

    def _server_started(self, generation, value, error):
        self.starting = False
        if self._stopping:
            if value is not None:
                self._background(lambda: self._stop_client(value[0]), lifecycle=True)
            return
        if generation != self.generation:
            if value is not None:
                self._start_after_stop(value[0])
            elif self._restart_pending:
                self._schedule_start()
            return
        if error is not None:
            self.serve = None
            self.serve_state = f"启动失败：{error}"
            self._log(f"[gui] serve 启动失败：{error}\n")
            self._chat_line(f"无法启动 pymybot serve：{error}", "error")
            self._chat_line("检查 Python 解释器与 pymybot 安装；也可以在设置里指定解释器。", "system")
            self._refresh_status()
            return
        client, info = value
        if not client.alive:
            self._on_serve_exit(generation, "启动时退出")
            return
        self.serve = client
        self.agent_available = bool(info.get("agent"))
        self.serve_state = f"就绪（协议 {info.get('protocol')}）"
        self._log(f"[gui] serve 就绪：{json.dumps(info, ensure_ascii=False)}\n")
        if not self.agent_available:
            self._chat_line("智能体不可用：当前解释器缺少 PydanticAI 依赖。", "error")
            self._chat_line("安装 pymybot[agent] 后重启本窗口；或用 --no-gui 走命令行控制器。", "system")
        elif not self.greeted:
            self.greeted = True
            self._chat_line("与机器人对话即可：模型会先列出硬件，再按需运行动作脚本。", "system")
        self._refresh_status()
        if self.pending_task:
            task, self.pending_task = self.pending_task, ""
            self._submit_task(task)
            self._refresh_status()

    def _schedule_start(self):
        self._restart_pending = False
        if not self._stopping:
            self._start_timer.start(150)

    def _start_after_stop(self, client):
        self._retiring = True
        self._background(lambda: self._stop_client(client), self._retired, lifecycle=True)

    def _retired(self, _value, _error):
        self._retiring = False
        if not self._stopping:
            self._schedule_start()

    def _dismiss_approvals(self):
        for dialog in tuple(self._dialogs):
            if isinstance(dialog, ToolDialog):
                dialog.reject()

    def _restart_server(self):
        if self._stopping:
            return
        self._start_timer.stop()
        client, self.serve = self.serve, None
        self.agent_available = False
        self.generation += 1
        self._dismiss_approvals()
        self.serve_state = "重新启动…"
        if self.busy:
            self._chat_line("服务重启；上一轮结果未知，检查机器人后再重试。", "error")
        self.turn_id = None
        self.turn_text = 0
        self.at_line_start = True
        self._set_busy(False)
        self._restart_pending = True
        if self.starting or self._retiring:
            return
        if client is None:
            self._schedule_start()
        else:
            self._start_after_stop(client)

    def _on_serve_exit(self, generation, code):
        if generation != self.generation or self._stopping:
            return
        self.serve = None
        self.agent_available = False
        self._dismiss_approvals()
        self.serve_state = f"已退出（{code}）"
        if self.busy:
            self._chat_line("pymybot serve 已退出；本轮结果未知，检查机器人后再重试。", "error")
        self.turn_id = None
        self._set_busy(False)

    def _server_log(self, generation, chunk):
        if generation == self.generation:
            self._log(chunk)

    def _on_notify(self, generation, method, params):
        if generation != self.generation or self._stopping:
            return
        if method == "session":
            self.agent_available = bool(params.get("agent")) or self.agent_available
            self._refresh_status()
        elif method == "agent.event":
            self._on_agent_event(params)
        elif method == "sample":
            self._log(f"[sample] {_brief(params)}\n")

    def _on_request(self, generation, ident, method, params):
        client = self.serve
        if generation != self.generation or client is None or self._stopping:
            return
        result = {"approved": self._ask_tool(params)} if method == "confirm" else None
        if self._stopping or generation != self.generation or client is not self.serve:
            return
        try:
            client.respond(ident, result)
        except RpcError as exc:
            self._log(f"[gui] 回复失败：{exc}\n")

    def _on_agent_event(self, params):
        if params.get("id") != self.turn_id:
            return
        event = params.get("event") or {}
        kind = event.get("type")
        if kind == "text_delta":
            self._chat_delta(str(event.get("text") or ""))
        elif kind == "tool_call":
            self._chat_line(f"→ {event.get('tool')} {_brief(event.get('arguments'))}", "tool")
        elif kind == "tool_result":
            tool, ok, state = event.get("tool"), event.get("ok"), event.get("state")
            status = "" if ok is None else ("ok" if ok else "失败")
            if state:
                status = f"{status} / {state}" if status else str(state)
            self._chat_line(f"⇦ {tool} {status}".rstrip(), "tool" if ok is not False else "toolerr")

    def send_task(self):
        if self._stopping:
            return
        task = self.task_box.toPlainText().strip()
        if not task:
            return
        if self.busy:
            self._notice("上一轮还在执行，先点停止或等待完成")
            return
        if self.serve is None:
            self.pending_task = task
            self._notice("正在启动 pymybot serve…")
            self._start_server()
            self._refresh_status()
            return
        self._submit_task(task)

    def _submit_task(self, task):
        if not self.agent_available:
            self._notice("智能体不可用：缺少 PydanticAI 依赖")
            return
        self._sync_config()
        robot = self._robot_path()
        if not robot or not Path(robot).is_file():
            self._message("需要结构文件", "先选择机器人结构（.sql）文件。")
            return
        scripts = self._scripts_root()
        if not Path(scripts).is_dir():
            self._message("脚本目录不存在", f"脚本根目录不存在：\n{scripts}")
            return
        if self._send(task) and self.task_box.toPlainText().strip() == task:
            self.task_box.clear()

    def _send(self, task):
        client, generation = self.serve, self.generation
        if self._stopping or client is None or not self.agent_available or self.busy:
            return False
        if self.hardware_toggle.isChecked() and not self._confirm_hardware():
            return False
        if self._stopping or client is not self.serve or generation != self.generation or self.busy:
            return False
        self._sync_config()
        workspace = self.cfg.workspace or default_workspace()
        params = {
            "task": task, "robot": self._robot_path(), "scriptsDir": self._scripts_root(),
            "cameraSrcDir": _absolute(self.cfg.camera_src_dir, workspace),
            "skillsDir": _absolute(self.cfg.skills_dir, workspace),
            "readVars": self.cfg.read_vars, "cameraVars": self.cfg.camera_vars,
            "vars": self.cfg.vars or None,
            "allowActions": self.actions_toggle.isChecked(),
            "allowHardware": self.hardware_toggle.isChecked(),
            "timeout": self.cfg.timeout, "maxRequests": self.cfg.max_requests,
            "maxToolCalls": self.cfg.max_tool_calls, "modulePaths": self._module_paths(),
        }
        for key, name in (("model", "model"), ("baseUrl", "base_url"), ("apiKeyEnv", "api_key_env")):
            value = getattr(self.cfg, name)
            if value:
                params[key] = value
        params = {key: value for key, value in params.items() if value not in ("", [], None)}
        try:
            ident, future = client.start_request("agent.ask", params)
        except RpcError as exc:
            self._chat_line(str(exc), "error")
            return False
        self._chat_line(f"你：{task}", "user")
        self.turn_id = ident
        self.turn_text = 0
        self.at_line_start = True
        self._set_busy(True)
        self._background(lambda: future.result(),
                         lambda value, error: self._turn_done(generation, ident, value, error))
        return True

    def _turn_done(self, generation, ident, result, error):
        if self._stopping or generation != self.generation or ident != self.turn_id:
            return
        self.turn_id = None
        self._dismiss_approvals()
        self._set_busy(False)
        if error is not None:
            if isinstance(error, RpcError) and error.code == CANCELLED:
                self._chat_line("[已停止]", "system")
            else:
                self._chat_line(str(error), "error")
                for event in getattr(error, "tool_events", []):
                    self._chat_line(f"  {_brief(event, 200)}", "system")
            return
        result = result or {}
        if self.turn_text == 0 and result.get("output"):
            self._chat_delta(str(result["output"]))
        usage = result.get("usage") or {}
        self._chat_line(
            "[完成 · 请求 {requests} · 工具 {tool_calls} · tokens {input_tokens}/{output_tokens}]".format(
                requests=usage.get("requests", "?"), tool_calls=usage.get("tool_calls", "?"),
                input_tokens=usage.get("input_tokens", "?"), output_tokens=usage.get("output_tokens", "?")),
            "system")

    def stop_turn(self):
        self.pending_task = ""
        if self.busy and self.serve is not None and self.turn_id is not None:
            self.serve.cancel(self.turn_id)
            self._dismiss_approvals()
            self._notice("已请求停止…")
        self._refresh_status()

    def new_conversation(self):
        if self._stopping:
            return
        if self.busy:
            self._notice("先停止当前这一轮")
            return
        if self.serve is None:
            self._start_server()
            return
        generation = self.generation
        try:
            _, future = self.serve.start_request("agent.reset", {})
        except RpcError as exc:
            self._on_reset(generation, exc)
            return
        self._background(lambda: future.result(), lambda _value, error: self._on_reset(generation, error))

    def _on_reset(self, generation, error):
        if generation != self.generation or self._stopping:
            return
        self._chat_line(f"重置失败：{error}" if error else "[新对话，硬件已释放]", "error" if error else "system")

    def on_permission_toggle(self):
        self._refresh_status()

    def _confirm_hardware(self):
        return self._message(
            "确认硬件权限",
            "即将以 --allow-hardware 运行：会打开物理设备，激活本身就可能写硬件。\n\n"
            "只对已审阅的可信结构文件与驱动授权。", confirm=True)

    def _ask_tool(self, params):
        tool = str(params.get("tool") or "?")
        try:
            arguments = json.dumps(params.get("arguments"), indent=2, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            arguments = repr(params.get("arguments"))
        if len(arguments) > MAX_DIALOG_ARGS:
            self._message("拒绝：参数过长", f"工具 {tool} 的参数超过 {MAX_DIALOG_ARGS} 字符，无法完整审阅，已拒绝。")
            self._chat_line(f"{tool} 已拒绝（参数过长）", "toolerr")
            return False
        dialog = ToolDialog(self, tool, arguments)
        approved = self._exec_dialog(dialog) == QDialog.DialogCode.Accepted
        self._chat_line(f"{tool} {'已批准' if approved else '已拒绝'}", "tool")
        return approved

    def refresh_context(self):
        self._sync_config()
        self._load_robot_list()
        self._refresh_hardware()

    def _refresh_hardware(self):
        if self._stopping:
            return
        self._hardware_generation += 1
        generation = self._hardware_generation
        robot = self._robot_path()
        self.hardware_tree.clear()
        self.hardware_note.setText("读取中…")
        if not robot or not Path(robot).is_file():
            self.hardware_note.setText("未选择结构文件")
            return
        workspace = self.cfg.workspace or default_workspace()
        python = resolve_python(workspace, self.cfg.python)
        try:
            args = cli_args("hardware", robot=robot, module_paths=self._module_paths(),
                            camera_src_dir=_absolute(self.cfg.camera_src_dir, workspace))
        except ValueError as exc:
            self.hardware_note.setText(str(exc))
            return

        def work():
            call = CliCall(python, args, workspace, on_stderr=lambda line: self.post(lambda: self._log(line)))
            with self._lifecycle_lock:
                self._hardware_calls.add(call)
                stopping = self._stopping
            try:
                if stopping:
                    call.kill()
                return call.wait()
            finally:
                with self._lifecycle_lock:
                    self._hardware_calls.discard(call)

        def done(result, error):
            if self._stopping or generation != self._hardware_generation:
                return
            if error is not None:
                self.hardware_note.setText(f"读取失败：{error}")
                return
            payload = result.json or {}
            if not payload.get("ok"):
                message = (payload.get("error") or {}).get("message") or result.stderr.strip() or "未知错误"
                self.hardware_note.setText(f"读取失败：{message}")
                return
            items = payload.get("hardware") or []
            for item in items:
                QTreeWidgetItem(self.hardware_tree, [str(item.get("name", "")), str(item.get("type", "")),
                                                    _brief(item.get("metadata"), 80)])
            self.hardware_note.setText(f"{len(items)} 个变量（未激活）")

        self._background(work, done, lifecycle=True)

    @staticmethod
    def _names(text):
        names = []
        for item in str(text).replace("，", ",").split(","):
            name = item.strip()
            if name and name.isidentifier() and name not in names:
                names.append(name)
        return names

    def open_settings(self):
        if self._stopping:
            return
        self._sync_config()
        dialog = SettingsDialog(self, self.cfg, self.cfg.workspace or default_workspace(), str(self.config_path))
        if self._exec_dialog(dialog) != QDialog.DialogCode.Accepted or self._stopping:
            return
        before = (self.cfg.workspace, self.cfg.python, self.cfg.session_log)
        for name, value in dialog.values.items():
            setattr(self.cfg, name, value)
        self.cfg.task = ""
        self._sync_controls()
        saved = self._save()
        self._refresh_model_label()
        self._load_robot_list()
        self._refresh_hardware()
        if before != (self.cfg.workspace, self.cfg.python, self.cfg.session_log):
            self._restart_server()
        self._notice("设置已保存" if saved else "设置已应用，但配置文件写入失败（见日志）")

    def _save(self):
        self._sync_config()
        try:
            self.cfg.store(self.config_path)
        except OSError as exc:
            reason = f"设置保存失败（{self.config_path}）：{exc}"
            print(f"pymybot gui: {reason}", file=sys.stderr)
            self._log(f"[gui] {reason}\n")
            self._notice("配置写入失败，详见日志")
            return False
        self._log(f"[gui] 设置已写入 {self.config_path}\n")
        return True

    def _refresh_status(self):
        self.status_state.setText(f"服务：{self.serve_state}")
        self.status_agent.setText("智能体：可用" if self.agent_available else "智能体：不可用")
        flags = []
        if self.hardware_toggle.isChecked():
            flags.append("允许硬件")
        if self.actions_toggle.isChecked():
            flags.append("自动批准动作")
        busy = "执行中…" if self.busy else "空闲"
        self.status_busy.setText(busy + ("（" + "、".join(flags) + "）" if flags else ""))
        self.stop_button.setEnabled(self.busy or bool(self.pending_task))

    def _set_busy(self, busy):
        self.busy = busy
        self.send_button.setEnabled(not busy)
        self.new_button.setEnabled(not busy)
        self._refresh_status()

    def shutdown(self):
        with self._lifecycle_lock:
            if self._stopping:
                return
            self._stopping = True
            clients = [client for client, event in self._clients.items() if event is None]
            if self.serve is not None and self.serve not in self._clients:
                clients.append(self.serve)
            calls = list(self._hardware_calls)
        self.generation += 1
        self._restart_pending = False
        self.pending_task = ""
        self.serve = None
        self._start_timer.stop()
        self._notice_timer.stop()
        self._pump_timer.stop()
        for dialog in tuple(self._dialogs):
            dialog.reject()
        for call in calls:
            call.kill()
        for client in clients:
            self._background(lambda c=client: self._stop_client(c), lifecycle=True)
        self._save()
        while not self.queue.empty():
            try:
                self.queue.get_nowait()
            except queue.Empty:
                break

    def wait_for_shutdown(self, timeout=5):
        deadline = time.monotonic() + timeout
        with self._lifecycle_lock:
            workers = list(self._lifecycle_workers)
        for worker in workers:
            worker.join(max(0, deadline - time.monotonic()))

    def closeEvent(self, event):
        if not self._stopping and self.busy and not self._message(
                "退出", "本轮仍在执行：退出会取消它，且已派发的动作不会回滚。继续？", confirm=True):
            event.ignore()
            return
        self.shutdown()
        event.accept()
        self.closed.emit()


class ToolDialog(QDialog):
    """Native modal approval; reject, Escape and window close all deny."""

    def __init__(self, parent, tool, arguments):
        super().__init__(parent)
        _apply_theme(self)
        self.setWindowTitle("智能体请求调用工具")
        self.setModal(True)
        self.resize(620, 400)
        self.setMinimumSize(520, 320)
        layout = QVBoxLayout(self)
        layout.addWidget(_label(f"工具：{tool}"))
        layout.addWidget(_label("下面是模型给出的完整参数；批准后本次调用立即执行。", secondary=True))
        self.arguments = QPlainTextEdit()
        self.arguments.setReadOnly(True)
        self.arguments.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.arguments.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.arguments.setPlainText(arguments)
        layout.addWidget(self.arguments, 1)
        row = QHBoxLayout()
        row.addStretch()
        self.approve_button = _button("批准并执行", self.accept)
        self.deny_button = _button("拒绝", self.reject)
        self.approve_button.setAutoDefault(False)
        self.deny_button.setDefault(True)
        row.addWidget(self.approve_button)
        row.addWidget(self.deny_button)
        layout.addLayout(row)
        self.deny_button.setFocus()


class SettingsDialog(QDialog):
    FIELDS = (
        ("workspace", "工作区"), ("python", "Python 解释器"),
        ("model", "模型（provider:model）"), ("base_url", "端点 Base URL"),
        ("api_key_env", "API Key 环境变量名"), ("scripts_dir", "脚本根目录"),
        ("skills_dir", "技能目录"), ("camera_src_dir", "图片源目录"),
        ("module_paths", "模块路径（每行一个）"),
        ("read_vars", "读取变量（逗号分隔）"), ("camera_vars", "相机变量（逗号分隔）"),
        ("vars", "变量覆盖（NAME=VALUE，每行一个，仅本次运行）"),
    )

    def __init__(self, parent, cfg: GuiConfig, workspace, config_path=""):
        super().__init__(parent)
        _apply_theme(self)
        self.setWindowTitle("设置")
        self.setModal(True)
        self.resize(640, 680)
        self.values = None
        layout = QVBoxLayout(self)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        body = QWidget()
        form = QFormLayout(body)
        scroll.setWidget(body)
        layout.addWidget(scroll, 1)
        self.entries = {}
        for name, label in self.FIELDS:
            value = getattr(cfg, name)
            if name == "module_paths":
                widget = QPlainTextEdit("\n".join(value))
                widget.setMaximumHeight(85)
            elif name == "vars":
                widget = QPlainTextEdit("\n".join(f"{key}={text}" for key, text in value.items()))
                widget.setMaximumHeight(85)
            else:
                widget = QLineEdit(",".join(value) if isinstance(value, list) else str(value or ""))
            self.entries[name] = widget
            if name in {"workspace", "scripts_dir", "skills_dir", "camera_src_dir"}:
                row = QHBoxLayout()
                row.addWidget(widget)
                row.addWidget(_button("…", lambda checked=False, w=widget: self._browse(w, workspace)))
                form.addRow(label, row)
            else:
                form.addRow(label, widget)
        self.timeout = _spin(cfg.timeout, 3600, fractional=True)
        self.requests = _spin(cfg.max_requests, 100)
        self.tools = _spin(cfg.max_tool_calls, 1000)
        form.addRow("超时（秒）", self.timeout)
        form.addRow("请求预算", self.requests)
        form.addRow("工具预算", self.tools)
        self.session_log = QCheckBox("保存会话转录（~/.mybot/sessions）")
        self.session_log.setChecked(bool(cfg.session_log))
        form.addRow(self.session_log)
        layout.addWidget(_label("密钥只读取环境变量，窗口不保存也不显示它。", secondary=True))
        layout.addWidget(_label(f"配置文件：{config_path or '（默认位置）'}", secondary=True))
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setText("保存")
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        self.buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        self.buttons.accepted.connect(self._save)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)

    def _browse(self, widget, workspace):
        chosen = QFileDialog.getExistingDirectory(self, "选择目录", workspace)
        if chosen:
            widget.setText(chosen)

    def _save(self):
        values = {}
        for name, widget in self.entries.items():
            if name == "module_paths":
                values[name] = [line.strip() for line in widget.toPlainText().splitlines() if line.strip()]
            elif name == "vars":
                values[name] = _parse_bindings(widget.toPlainText())
            elif name in {"read_vars", "camera_vars"}:
                values[name] = App._names(widget.text())
            else:
                values[name] = widget.text().strip()
        values.update(timeout=self.timeout.value(), max_requests=self.requests.value(),
                      max_tool_calls=self.tools.value(), session_log=self.session_log.isChecked())
        self.values = values
        self.accept()


def _check_display():
    platform = os.environ.get("QT_QPA_PLATFORM", "").split(":", 1)[0].lower()
    if (sys.platform.startswith("linux") and not os.environ.get("DISPLAY")
            and not os.environ.get("WAYLAND_DISPLAY") and platform not in {"offscreen", "minimal"}):
        raise GuiUnavailable(
            "No graphical display: set DISPLAY/WAYLAND_DISPLAY, use --no-gui, "
            "or explicitly set QT_QPA_PLATFORM=offscreen for headless testing.")


def run_gui(args):
    _check_display()
    path = config_home() / "settings.json"
    config = merge_args(GuiConfig.load(path), args).sanitized()
    application = QApplication.instance()
    owns_application = application is None
    if owns_application:
        application = QApplication([sys.argv[0]])
    window = App(config, path)
    loop = application if owns_application else QEventLoop()
    window.closed.connect(loop.quit)
    application.aboutToQuit.connect(window.shutdown)
    window.show()
    try:
        loop.exec()
    finally:
        window.shutdown()
        window.close()
        window.wait_for_shutdown()
        application.aboutToQuit.disconnect(window.shutdown)
        window.deleteLater()
    return {"closed": True}
