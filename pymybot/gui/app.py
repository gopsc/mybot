"""Native Qt window over the long-lived ``pymybot serve`` process."""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import (QEasingCurve, QEventLoop, QPropertyAnimation, Qt, QTimer,
                            QUrl, Signal)
from PySide6.QtGui import (QAction, QColor, QDesktopServices, QFont, QFontDatabase, QFontMetrics,
                           QKeySequence, QShortcut, QTextCharFormat, QTextCursor, QTextDocument)
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDoubleSpinBox, QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QInputDialog,
    QLabel,
    QLineEdit, QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QScrollArea, QSpinBox, QSplitter, QTabWidget, QTextBrowser, QToolButton, QTreeWidget,
    QTreeWidgetItem, QVBoxLayout, QWidget,
)

from ..paths import source_root
from ..robot import module_roots
from ..roles import create_role as create_role_profile, list_roles, role_path
from ..session_log import session_root
from . import GuiUnavailable
from .branding import logo_icon, logo_pixmap
from .config import GuiConfig, config_home, default_workspace, merge_args
from .dialogs import (AboutDialog, CommandDialog, DoctorDialog, McpConfigDialog, PreviewDialog,
                      PromptPanel, ResourcePanel, SessionsDialog)
from .protocol import CANCELLED, CliCall, RpcError, ServeClient, cli_args, resolve_python
from .splash import SplashScreen
from .theme import PALETTE, apply_theme as _apply_theme

TITLE = "mybot · 智能体"
MAX_DIALOG_ARGS = 4000
INTENT_LABELS = {"auto": "自动", "off": "关闭", "chat": "闲聊", "inspect": "查看",
                 "control": "控制", "author": "编写", "diagnose": "诊断"}
INTENT_CHOICES = (("auto", "自动（推荐）"), ("off", "关闭"), ("chat", "闲聊（只读）"),
                  ("inspect", "查看（只读）"), ("control", "控制（硬件动作）"),
                  ("author", "编写（文件）"), ("diagnose", "诊断（含 Shell）"))
SANDBOX_CHOICES = (("auto", "自动（bubblewrap 可用时）"), ("off", "关闭（仅工作区牢笼）"),
                   ("bwrap", "强制 bubblewrap"))


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


class ChatTranscript(QTextBrowser):
    """Read-only transcript that never loads resources referenced by Markdown."""

    def loadResource(self, _resource_type, _url):
        return None


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
        self.mcp_available = False
        self.busy = False
        self.turn_id = None
        self.turn_text = 0
        self.at_line_start = True
        self._assistant_start = None
        self._assistant_markdown = ""
        self.pending_task = ""
        self.last_task = ""
        self.last_failed = False
        self._resource_roots = None
        self._confirmed_grants = set()
        self._in_permission = False
        self._stopping = False
        self._lifecycle_lock = threading.Lock()
        self._clients = {}
        self._lifecycle_workers = []
        self._hardware_calls = set()
        self._hardware_generation = 0
        self._dialogs = set()
        self.font_mono = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)

        self.setWindowIcon(logo_icon())
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
        self._hardware_timer = QTimer(self)
        self._hardware_timer.setSingleShot(True)
        self._hardware_timer.timeout.connect(self._refresh_hardware)
        self._load_role_list()
        self._load_robot_list()
        self._refresh_hardware()
        self._start_timer.start(120)
        self.task_box.setPlainText(self.cfg.task.strip())
        self._refresh_status()

    def _build(self):
        self.setWindowTitle(TITLE)
        self.resize(1180, 780)
        self.setMinimumSize(900, 600)
        self._build_menu()
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        toolbar = QHBoxLayout()
        layout.addLayout(toolbar)
        brand = QLabel()
        brand.setPixmap(logo_pixmap(24))
        brand.setFixedSize(24, 24)
        brand.setToolTip("MYBOT robot control station")
        toolbar.addWidget(brand)
        toolbar.addWidget(_button("打开工作区", self.pick_workspace))
        self.workspace_label = _label()
        self.workspace_label.setWordWrap(False)
        self.workspace_label.setMaximumWidth(180)
        toolbar.addWidget(self.workspace_label)
        toolbar.addWidget(_label("角色"))
        self.role_box = QComboBox()
        self.role_box.setMinimumWidth(130)
        self.role_box.activated.connect(self.on_role_changed)
        toolbar.addWidget(self.role_box)
        self.create_role_button = _button("新建", self.new_role)
        toolbar.addWidget(self.create_role_button)
        toolbar.addWidget(_label("结构"))
        self.robot_box = QComboBox()
        self.robot_box.setMinimumWidth(160)
        self.robot_box.activated.connect(self.on_robot_changed)
        toolbar.addWidget(self.robot_box, 1)
        toolbar.addWidget(_button("刷新", self.refresh_context))
        self.manage_button = QToolButton()
        self.manage_button.setText("管理")
        self.manage_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.manage_button.setMenu(self._manage_menu())
        toolbar.addWidget(self.manage_button)
        toolbar.addWidget(_button("命令", self.open_console))
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
        body.setSizes([380, 1020])

        self.status_state = _label()
        self.status_agent = _label()
        self.status_busy = _label()
        self.status_notice = _label()
        self.status_prompt = _label()
        self.status_prompt.setToolTip("本轮实际使用的提示词版本（SHA-256 前 16 位）")
        self.statusBar().addPermanentWidget(self.status_prompt)
        self.busy_progress = QProgressBar()
        self.busy_progress.setRange(0, 0)
        self.busy_progress.setFixedWidth(90)
        self.busy_progress.setTextVisible(False)
        self.busy_progress.hide()
        for label in (self.status_state, self.status_agent, self.status_busy):
            label.setWordWrap(False)
            self.statusBar().addWidget(label)
        self.statusBar().addWidget(self.status_notice)
        self.statusBar().addPermanentWidget(self.busy_progress)

    def _build_menu(self):
        def action(menu, text, slot, shortcut=None):
            item = QAction(text, self)
            if shortcut:
                item.setShortcut(QKeySequence(shortcut))
            item.triggered.connect(lambda _checked=False, fn=slot: fn())
            menu.addAction(item)
            return item

        bar = self.menuBar()
        files = bar.addMenu("文件")
        action(files, "打开工作区…", self.pick_workspace, "Ctrl+O")
        action(files, "选择结构…", self.pick_robot, "Ctrl+Shift+O")
        action(files, "刷新上下文", self.refresh_context, "F5")
        files.addSeparator()
        action(files, "设置…", self.open_settings, "Ctrl+,")
        files.addSeparator()
        action(files, "退出", self.close, "Ctrl+Q")

        tools = bar.addMenu("工具")
        action(tools, "命令面板…", self.open_console, "Ctrl+Shift+P")
        action(tools, "MCP 配置…", self.open_mcp)
        action(tools, "会话管理…", self.open_sessions)
        action(tools, "环境诊断…", self.open_doctor)
        action(tools, "资源预览", self.show_resources)
        tools.addSeparator()
        action(tools, "打开会话目录", self.open_sessions_folder)
        action(tools, "清空对话", self.clear_chat)
        action(tools, "复制对话", self.copy_chat)

        help_menu = bar.addMenu("帮助")
        action(help_menu, "使用文档", self.open_docs, "F1")
        action(help_menu, "关于", self.open_about)

    def _manage_menu(self):
        menu = QMenu(self)
        for text, slot in (("命令面板…", self.open_console), ("MCP 配置…", self.open_mcp),
                           ("会话管理…", self.open_sessions), ("环境诊断…", self.open_doctor),
                           ("资源预览", self.show_resources), ("清空对话", self.clear_chat)):
            action = QAction(text, menu)
            action.triggered.connect(lambda _checked=False, fn=slot: fn())
            menu.addAction(action)
        return menu

    def _set_workspace_label(self, text):
        self.workspace_label.setToolTip(text)
        self.workspace_label.setText(QFontMetrics(self.workspace_label.font()).elidedText(
            text, Qt.TextElideMode.ElideMiddle, self.workspace_label.maximumWidth()))

    def _build_side(self, side):
        layout = QVBoxLayout(side)
        robot = QGroupBox("机器人上下文")
        form = QFormLayout(robot)
        self.context_entries = {}
        fields = (
            ("scripts_dir", "脚本根目录", "dir"), ("skills_dir", "技能目录", "dir"),
            ("module_paths", "模块路径", None), ("camera_src_dir", "图片源目录", "dir"),
            ("mcp_config", "MCP 配置（mcpServers JSON）", "edit"),
        )
        for name, label, mode in fields:
            row = QHBoxLayout()
            value = getattr(self.cfg, name)
            entry = QLineEdit(os.pathsep.join(value) if name == "module_paths" else value)
            entry.setToolTip(entry.text())
            entry.textChanged.connect(lambda text, e=entry: e.setToolTip(text))
            entry.editingFinished.connect(self._sync_config)
            self.context_entries[name] = entry
            row.addWidget(entry)
            if mode == "dir":
                row.addWidget(_button("…", lambda checked=False, e=entry: self._browse_into(e)))
            elif mode == "edit":
                row.addWidget(_button("编辑", self.open_mcp))
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
        self.history_box = _spin(self.cfg.history_turns, 20)
        form.addRow("超时（秒）", self.timeout_box)
        form.addRow("请求预算", self.requests_box)
        form.addRow("工具预算", self.tools_box)
        form.addRow("历史轮数", self.history_box)
        layout.addWidget(guard)

        advanced = QGroupBox("高级工具权限（默认关闭）")
        advanced_form = QFormLayout(advanced)
        self.file_tools_toggle = QCheckBox("文件工具（工作区只读）")
        self.file_tools_toggle.setChecked(bool(self.cfg.enable_file_tools))
        self.file_writes_toggle = QCheckBox("允许文件写入（逐次确认）")
        self.file_writes_toggle.setChecked(bool(self.cfg.allow_file_writes))
        self.shell_tools_toggle = QCheckBox("Shell 工具（沙箱可配置）")
        self.shell_tools_toggle.setChecked(bool(self.cfg.enable_shell))
        self.shell_grant_toggle = QCheckBox("自动批准 Shell")
        self.shell_grant_toggle.setChecked(bool(self.cfg.allow_shell))
        self.web_tools_toggle = QCheckBox("联网工具（抓取/搜索）")
        self.web_tools_toggle.setChecked(bool(self.cfg.enable_web))
        self.web_grant_toggle = QCheckBox("自动批准联网请求")
        self.web_grant_toggle.setChecked(bool(self.cfg.allow_web))
        self.mcp_tools_toggle = QCheckBox("自动批准 MCP 工具")
        self.mcp_tools_toggle.setChecked(bool(self.cfg.allow_mcp_tools))
        for toggle in (self.file_tools_toggle, self.file_writes_toggle,
                       self.shell_tools_toggle, self.shell_grant_toggle,
                       self.web_tools_toggle, self.web_grant_toggle, self.mcp_tools_toggle):
            toggle.toggled.connect(self.on_permission_toggle)
            advanced_form.addRow(toggle)
        advanced_form.addRow(_label(
            "Shell 使用设置中的沙箱后端；MCP 是宿主用户权限进程；联网请求默认逐次确认。", secondary=True))
        layout.addWidget(advanced)

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
        self.chat = ChatTranscript()
        self.chat.setReadOnly(True)
        self.chat.setOpenLinks(False)
        self.chat.setOpenExternalLinks(False)
        self.chat.setObjectName("chatTranscript")
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(self.font_mono)
        self.log.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.log.setObjectName("eventLog")
        self.resources = ResourcePanel()
        self.notebook.addTab(self.chat, "对话")
        self.notebook.addTab(self.log, "日志")
        self.notebook.addTab(self.resources, "资源")
        self.notebook.currentChanged.connect(self._on_tab_changed)
        layout.addWidget(self.notebook, 1)
        composer = QHBoxLayout()
        self.task_box = QPlainTextEdit()
        self.task_box.setPlaceholderText("与机器人对话…")
        self.task_box.setMaximumHeight(100)
        composer.addWidget(self.task_box, 1)
        buttons = QVBoxLayout()
        self.send_button = _button("发送", self.send_task, role="primary")
        buttons.addWidget(self.send_button)
        self.composer_retry = _button("重试", self.retry_task)
        self.composer_retry.setEnabled(False)
        buttons.addWidget(self.composer_retry)
        buttons.addWidget(_label("Ctrl+Enter", secondary=True))
        composer.addLayout(buttons)
        layout.addLayout(composer)
        self.send_shortcuts = []
        for key in ("Ctrl+Return", "Ctrl+Enter"):
            shortcut = QShortcut(QKeySequence(key), self.task_box)
            shortcut.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
            shortcut.activated.connect(self.send_task)
            self.send_shortcuts.append(shortcut)

    def _on_tab_changed(self, index):
        if self.notebook.widget(index) is self.resources:
            self.show_resources()

    def _robots_root(self):
        workspace = Path(self.cfg.workspace or default_workspace()).absolute()
        candidate = workspace / "robots"
        if candidate.is_dir():
            return str(candidate)
        robot = self._robot_path()
        return str(Path(robot).parent) if robot and Path(robot).is_file() else ""

    def show_resources(self):
        modules = self._module_paths() or [str(path) for path in module_roots()]
        roots = (self._scripts_root(), self._skills_root(),
                 self._robots_root(), tuple(modules))
        if roots != self._resource_roots:
            self._resource_roots = roots
            self.resources.set_roots(*roots)
        self.notebook.setCurrentWidget(self.resources)
        self.resources.ensure_loaded()

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
        bar = widget.verticalScrollBar()
        at_bottom = bar.value() >= bar.maximum() - 4
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
        if at_bottom:
            widget.ensureCursorVisible()

    def _log(self, chunk):
        if chunk and not self._stopping:
            self._insert_text(self.log, chunk if chunk.endswith("\n") else chunk + "\n")

    def _flush_markdown(self):
        """Render the completed assistant segment without re-rendering its deltas."""
        if self._assistant_start is None:
            return
        start, markdown = self._assistant_start, self._assistant_markdown
        self._assistant_start = None
        self._assistant_markdown = ""
        document = QTextDocument()
        document.setDefaultFont(self.chat.font())
        # Qt Markdown otherwise silently interprets/removes raw HTML. Escape it
        # so model output stays literal while Markdown formatting still works.
        document.setMarkdown(markdown.replace("&", "&amp;").replace("<", "&lt;"))
        cursor = self.chat.textCursor()
        cursor.setPosition(start)
        cursor.movePosition(QTextCursor.MoveOperation.End, QTextCursor.MoveMode.KeepAnchor)
        cursor.removeSelectedText()
        cursor.insertHtml(document.toHtml())
        end = cursor.position()
        cursor.setPosition(start)
        cursor.setPosition(end, QTextCursor.MoveMode.KeepAnchor)
        fmt = QTextCharFormat()
        fmt.setForeground(QColor(PALETTE["assistant"]))
        cursor.mergeCharFormat(fmt)

    def _chat_line(self, text, tag=None):
        if self._stopping:
            return
        self._flush_markdown()
        self._insert_text(self.chat, ("" if self.at_line_start else "\n") + text + "\n", tag)
        self.at_line_start = True

    def _chat_delta(self, text):
        if text and not self._stopping:
            if self._assistant_start is None:
                cursor = self.chat.textCursor()
                cursor.movePosition(QTextCursor.MoveOperation.End)
                self._assistant_start = cursor.position()
            self._assistant_markdown += text
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
            if self.cfg.role and name in {"skills_dir", "mcp_config"}:
                continue
            value = entry.text().strip()
            setattr(self.cfg, name, [item.strip() for item in value.split(os.pathsep) if item.strip()]
                    if name == "module_paths" else value)
        self.cfg.read_vars = self._names(self.read_vars_entry.text())
        self.cfg.camera_vars = self._names(self.camera_vars_entry.text())
        self.cfg.timeout = self.timeout_box.value()
        self.cfg.max_requests = self.requests_box.value()
        self.cfg.max_tool_calls = self.tools_box.value()
        self.cfg.history_turns = self.history_box.value()
        self.cfg.enable_file_tools = self.file_tools_toggle.isChecked()
        self.cfg.enable_shell = self.shell_tools_toggle.isChecked()
        self.cfg.allow_file_writes = self.file_writes_toggle.isChecked()
        self.cfg.allow_shell = self.shell_grant_toggle.isChecked()
        self.cfg.enable_web = self.web_tools_toggle.isChecked()
        self.cfg.allow_web = self.web_grant_toggle.isChecked()
        self.cfg.allow_mcp_tools = self.mcp_tools_toggle.isChecked()

    def _sync_controls(self):
        for name, entry in self.context_entries.items():
            value = getattr(self.cfg, name)
            entry.setText(os.pathsep.join(value) if name == "module_paths" else value)
        self.read_vars_entry.setText(",".join(self.cfg.read_vars))
        self.camera_vars_entry.setText(",".join(self.cfg.camera_vars))
        self.timeout_box.setValue(self.cfg.timeout)
        self.requests_box.setValue(self.cfg.max_requests)
        self.tools_box.setValue(self.cfg.max_tool_calls)
        self.history_box.setValue(self.cfg.history_turns)
        self.file_tools_toggle.setChecked(bool(self.cfg.enable_file_tools))
        self.shell_tools_toggle.setChecked(bool(self.cfg.enable_shell))
        self.file_writes_toggle.setChecked(bool(self.cfg.allow_file_writes))
        self.shell_grant_toggle.setChecked(bool(self.cfg.allow_shell))
        self.web_tools_toggle.setChecked(bool(self.cfg.enable_web))
        self.web_grant_toggle.setChecked(bool(self.cfg.allow_web))
        self.mcp_tools_toggle.setChecked(bool(self.cfg.allow_mcp_tools))
        self._sync_role_paths()

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

    def _load_role_list(self):
        current = self.cfg.role
        try:
            roles = list_roles()
        except OSError:
            roles = []
        self.role_box.blockSignals(True)
        self.role_box.clear()
        self.role_box.addItem("默认（全局 Prompt）", "")
        for item in roles:
            self.role_box.addItem(item["name"], item["name"])
            index = self.role_box.count() - 1
            self.role_box.setItemData(index, item.get("description") or item["root"],
                                      Qt.ItemDataRole.ToolTipRole)
        index = self.role_box.findData(current)
        self.role_box.setCurrentIndex(index if index >= 0 else 0)
        self.cfg.role = self.role_box.currentData() or ""
        self.role_box.blockSignals(False)
        self._sync_role_paths()

    def _sync_role_paths(self):
        role = self.cfg.role
        if role:
            root = role_path(role)
            values = {"skills_dir": str(root / "skills"), "mcp_config": str(root / "mcp.json")}
        else:
            values = {name: getattr(self.cfg, name) for name in ("skills_dir", "mcp_config")}
        for name, value in values.items():
            entry = self.context_entries[name]
            entry.blockSignals(True)
            entry.setText(value)
            entry.setToolTip(value)
            entry.setEnabled(not role)
            entry.blockSignals(False)
        self.on_permission_toggle()

    def on_role_changed(self):
        self.cfg.role = self.role_box.currentData() or ""
        self._sync_role_paths()
        self._save()
        self._notice(f"已选择角色：{self.cfg.role}" if self.cfg.role else "已使用全局 Prompt 与默认能力")

    def new_role(self):
        if self._stopping or self.busy:
            return
        name, accepted = QInputDialog.getText(self, "新建 Agent 角色", "角色名（字母、数字、中文、_、-、.）：")
        name = name.strip()
        if not accepted or not name:
            return
        workspace = self.cfg.workspace or default_workspace()
        skills = self._skills_root()
        mcp = self._mcp_root()
        try:
            role = create_role_profile(
                name,
                skills_from=skills if skills and Path(skills).is_dir() else None,
                mcp_from=mcp if mcp and Path(mcp).is_file() else None,
            )
        except Exception as exc:
            self._message("新建角色失败", str(exc))
            return
        self.cfg.role = role.name
        self._load_role_list()
        self._save()
        self._notice(f"角色 {role.name} 已创建：{role.root}")
        if workspace:
            self._resource_roots = None

    def _load_robot_list(self):
        root = Path(self.cfg.workspace or default_workspace()).absolute()
        self._set_workspace_label(str(root))
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
        self._hardware_timer.start(140)

    def _robot_path(self):
        return _absolute(self.cfg.robot, self.cfg.workspace or default_workspace())

    def _scripts_root(self):
        root = self.cfg.workspace or default_workspace()
        configured = _absolute(self.cfg.scripts_dir, root)
        if configured:
            return configured
        candidate = Path(root).absolute() / "scripts"
        return str(candidate if candidate.is_dir() else Path(root).absolute())

    def _skills_root(self):
        if self.cfg.role:
            return str(role_path(self.cfg.role) / "skills")
        return _absolute(self.cfg.skills_dir, self.cfg.workspace or default_workspace())

    def _mcp_root(self):
        if self.cfg.role:
            return str(role_path(self.cfg.role) / "mcp.json")
        return _absolute(self.cfg.mcp_config, self.cfg.workspace or default_workspace())

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
        self.mcp_available = bool(info.get("mcp"))
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
        self.mcp_available = False
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
        self.mcp_available = False
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
        elif kind == "prompt_version":
            self._show_prompt_version(event.get("hash"))
        elif kind == "tool_call":
            tool = event.get("tool")
            arguments = ("[提示词内容仅在审批窗口显示]" if tool in {"prompt:update_prompt", "update_prompt"}
                         else _brief(event.get("arguments")))
            self._chat_line(f"→ {tool} {arguments}", "tool")
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
        self._sync_config()
        if self.shell_tools_toggle.isChecked() and not self.file_tools_toggle.isChecked():
            self._notice("Shell 工具需要先启用文件工具")
            return False
        for kind, toggle in (("file_writes", self.file_writes_toggle),
                             ("shell", self.shell_grant_toggle),
                             ("web", self.web_grant_toggle),
                             ("mcp", self.mcp_tools_toggle)):
            if toggle.isChecked() and kind not in self._confirmed_grants:
                if not self._confirm_grant(kind):
                    toggle.setChecked(False)
                    return False
                self._confirmed_grants.add(kind)
        if self._stopping or client is not self.serve or generation != self.generation or self.busy:
            return False
        try:
            # Revalidate just before dispatch, including when an earlier turn was
            # valid. Backend validation remains authoritative for any later race.
            from ..prompts import PromptLibrary
            library = PromptLibrary(home=role_path(self.cfg.role) / "prompts" if self.cfg.role else None)
            library.ensure_home()
            library.compose()
        except Exception as exc:
            self._message("发送已阻止：提示词安全校验失败",
                          f"{exc}\n\n0 / 100 安全层必须保持完整。请到「设置 → 提示词」"
                          "检查，必要时明确确认「恢复全部默认」修复后再发送。")
            return False
        params = self._agent_params(task)
        try:
            ident, future = client.start_request("agent.ask", params)
        except RpcError as exc:
            self._chat_line(str(exc), "error")
            return False
        self._chat_line(f"你：{task}", "user")
        self.last_task = task
        self.last_failed = False
        self.turn_id = ident
        self.turn_text = 0
        self.at_line_start = True
        self._set_busy(True)
        self._background(lambda: future.result(),
                         lambda value, error: self._turn_done(generation, ident, value, error))
        return True

    def _agent_params(self, task):
        workspace = self.cfg.workspace or default_workspace()
        use_workspace = self.file_tools_toggle.isChecked() or self.shell_tools_toggle.isChecked()
        params = {
            "task": task, "role": self.cfg.role or None,
            "robot": self._robot_path(), "scriptsDir": self._scripts_root(),
            "cameraSrcDir": _absolute(self.cfg.camera_src_dir, workspace),
            "skillsDir": "" if self.cfg.role else self._skills_root(),
            "mcpConfig": "" if self.cfg.role else self._mcp_root(),
            "readVars": self.cfg.read_vars, "cameraVars": self.cfg.camera_vars,
            "vars": self.cfg.vars or None,
            "allowActions": self.actions_toggle.isChecked(),
            "allowHardware": self.hardware_toggle.isChecked(),
            "allowMcpTools": self.mcp_tools_toggle.isChecked(),
            "workspaceDir": workspace if use_workspace else "",
            "enableShell": self.shell_tools_toggle.isChecked(),
            "allowShell": self.shell_grant_toggle.isChecked(),
            "allowFileWrites": self.file_writes_toggle.isChecked(),
            "historyTurns": self.cfg.history_turns,
            "maxHistoryBytes": self.cfg.max_history_bytes,
            "maxContextTokens": self.cfg.max_context_tokens,
            "contextReserveTokens": self.cfg.context_reserve_tokens,
            "promptFile": _absolute(self.cfg.prompt_file, workspace),
            "autoStats": self.cfg.auto_stats,
            "contextBytes": self.cfg.context_bytes,
            "intent": self.cfg.intent_mode,
            "sandbox": self.cfg.sandbox_mode,
            "enableWeb": self.cfg.enable_web,
            "allowWeb": self.cfg.allow_web,
            "searchEndpoint": self.cfg.search_endpoint if self.cfg.enable_web else "",
            "timeout": self.cfg.timeout, "maxRequests": self.cfg.max_requests,
            "maxToolCalls": self.cfg.max_tool_calls, "modulePaths": self._module_paths(),
        }
        for key, name in (("model", "model"), ("baseUrl", "base_url"), ("apiKeyEnv", "api_key_env")):
            value = getattr(self.cfg, name)
            if value:
                params[key] = value
        return {key: value for key, value in params.items() if value not in ("", [], None)}

    def _turn_done(self, generation, ident, result, error):
        if self._stopping or generation != self.generation or ident != self.turn_id:
            return
        self.turn_id = None
        self._dismiss_approvals()
        self._set_busy(False)
        if error is not None:
            self.last_failed = True
            if isinstance(error, RpcError) and error.code == CANCELLED:
                self._chat_line("[已停止]", "system")
            else:
                self._chat_line(str(error), "error")
                for event in getattr(error, "tool_events", []):
                    summary = ("prompt:update_prompt [内容已隐藏]"
                               if event.get("tool") in {"prompt:update_prompt", "update_prompt", "read_prompt"}
                               else _brief(event, 200))
                    self._chat_line(f"  {summary}", "system")
            self._refresh_status()
            return
        result = result or {}
        self._show_prompt_version((result.get("prompt_version") or {}).get("hash"))
        if self.turn_text == 0 and result.get("output"):
            self._chat_delta(str(result["output"]))
        usage = result.get("usage") or {}
        intent = result.get("intent") or {}
        if intent.get("name") not in (None, "off"):
            label = INTENT_LABELS.get(intent["name"], intent["name"])
            self._notice(f"意图：{label} · 置信度 {float(intent.get('confidence') or 0):.0%}",
                         seconds=4)
        self._chat_line(
            "[完成 · 请求 {requests} · 工具 {tool_calls} · tokens {input_tokens}/{output_tokens}]".format(
                requests=usage.get("requests", "?"), tool_calls=usage.get("tool_calls", "?"),
                input_tokens=usage.get("input_tokens", "?"), output_tokens=usage.get("output_tokens", "?")),
            "system")

    def _show_prompt_version(self, digest):
        if isinstance(digest, str) and len(digest) >= 16 and all(c in "0123456789abcdef" for c in digest.lower()):
            self.status_prompt.setText(f"提示词：{digest[:16]}")

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
        params = ({"clearHistory": True, "role": self.cfg.role} if self.cfg.role else {})
        try:
            _, future = self.serve.start_request("agent.reset", params)
        except RpcError as exc:
            self._on_reset(generation, exc)
            return
        self._background(lambda: future.result(), lambda _value, error: self._on_reset(generation, error))

    def _on_reset(self, generation, error):
        if generation != self.generation or self._stopping:
            return
        self._chat_line(f"重置失败：{error}" if error else "[新对话，硬件已释放]", "error" if error else "system")

    def retry_task(self):
        if self.busy:
            self._notice("上一轮还在执行，先停止或等待完成")
            return
        task = self.last_task.strip()
        if not task:
            return
        self.task_box.setPlainText(task)
        self.send_task()

    def _update_retry_buttons(self):
        enabled = bool(self.last_task) and not self.busy and not self._stopping
        self.composer_retry.setEnabled(enabled)

    def clear_chat(self):
        if not self.chat.toPlainText().strip():
            return
        if not self._message("清空对话", "清空窗口中的对话记录？磁盘上的会话转录不受影响。", confirm=True):
            return
        self.chat.clear()
        self.at_line_start = True
        self.turn_text = 0
        self._assistant_start = None
        self._assistant_markdown = ""
        self._notice("对话已清空")

    def copy_chat(self):
        text = self.chat.toPlainText().strip()
        if text:
            QApplication.clipboard().setText(text)
            self._notice("对话已复制到剪贴板")

    def open_mcp(self):
        if self._stopping:
            return
        self._sync_config()
        workspace = self.cfg.workspace or default_workspace()
        path = self._mcp_root()
        dialog = McpConfigDialog(self, path, base_dir=Path(path).parent if self.cfg.role else workspace)
        if self._exec_dialog(dialog) == QDialog.DialogCode.Accepted and dialog.saved_path:
            if not self.cfg.role:
                self.cfg.mcp_config = dialog.saved_path
            self._sync_role_paths()
            self._save()
            self._notice("MCP 配置已保存")

    def open_sessions(self):
        if self._stopping:
            return
        self._exec_dialog(SessionsDialog(self))

    def open_doctor(self):
        if self._stopping:
            return
        self._exec_dialog(DoctorDialog(self))

    def open_console(self):
        if self._stopping:
            return
        self._sync_config()
        workspace = self.cfg.workspace or default_workspace()
        dialog = CommandDialog(
            self, python=resolve_python(workspace, self.cfg.python), cwd=workspace,
            robot=self._robot_path(), module_paths=self._module_paths(),
            camera_src_dir=_absolute(self.cfg.camera_src_dir, workspace),
            scripts_dir=self._scripts_root(), timeout=self.cfg.timeout,
            confirm=lambda title, text: self._message(title, text, confirm=True))
        self._exec_dialog(dialog)

    def open_about(self):
        if not self._stopping:
            self._exec_dialog(AboutDialog(self))

    def open_docs(self):
        path = source_root() / "docs" / "README.md"
        if path.is_file():
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
        else:
            QDesktopServices.openUrl(QUrl("https://github.com/gopsc/mybot/tree/gui-mybot/docs"))

    def open_sessions_folder(self):
        root = session_root()
        try:
            root.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            self._notice(f"无法创建会话目录：{exc}")
            return
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(root)))

    def on_permission_toggle(self):
        if self._in_permission:
            return
        self._in_permission = True
        try:
            file_tools = self.file_tools_toggle.isChecked()
            self.file_writes_toggle.setEnabled(file_tools)
            self.shell_tools_toggle.setEnabled(file_tools)
            if not file_tools:
                self.file_writes_toggle.setChecked(False)
                self.shell_tools_toggle.setChecked(False)
            shell = self.shell_tools_toggle.isChecked()
            self.shell_grant_toggle.setEnabled(shell)
            if not shell:
                self.shell_grant_toggle.setChecked(False)
            web = self.web_tools_toggle.isChecked()
            self.web_grant_toggle.setEnabled(web)
            if not web:
                self.web_grant_toggle.setChecked(False)
            has_mcp = (Path(self._mcp_root()).is_file() if self.cfg.role
                       else bool(self.context_entries["mcp_config"].text().strip()))
            self.mcp_tools_toggle.setEnabled(has_mcp)
            if not has_mcp:
                self.mcp_tools_toggle.setChecked(False)
        finally:
            self._in_permission = False
        self._refresh_status()

    def _confirm_hardware(self):
        return self._message(
            "确认硬件权限",
            "即将以 --allow-hardware 运行：会打开物理设备，激活本身就可能写硬件。\n\n"
            "只对已审阅的可信结构文件与驱动授权。", confirm=True)

    def _confirm_grant(self, kind):
        messages = {
            "file_writes": ("允许文件写入", "模型可以创建或修改工作区文件（含脚本/驱动），仍会逐次弹出审批。"),
            "shell": ("允许 Shell 自动批准",
                      "Shell 使用设置中的沙箱后端；工作区牢笼不是 OS 边界。\n"
                      "只对当前启动授权，关闭窗口即失效。"),
            "web": ("允许联网自动批准",
                    "模型可以抓取 HTTPS 页面并查询已配置的 SearXNG；私网/回环地址会被拒绝。\n"
                    "只对当前启动授权，关闭窗口即失效。"),
            "mcp": ("允许 MCP 工具自动批准",
                    "外部 MCP 服务以宿主用户权限运行，不是沙箱；其输出是不可信数据。\n"
                    "只对当前启动授权，关闭窗口即失效。"),
        }
        title, text = messages[kind]
        return self._message(title, text, confirm=True)

    def _ask_tool(self, params):
        tool = str(params.get("tool") or "?")
        try:
            arguments = json.dumps(params.get("arguments"), indent=2, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            arguments = repr(params.get("arguments"))
        is_prompt = tool == "prompt:update_prompt"
        # Prompt diffs and skill documents can exceed the ordinary small-tool
        # bound. Never truncate approval content; oversized requests are denied.
        limit = 2 * 1024 * 1024 if is_prompt else (512 * 1024 if tool == "create_skill" else MAX_DIALOG_ARGS)
        if len(arguments) > limit:
            self._message("拒绝：参数过长", f"工具 {tool} 的参数超过 {limit} 字符，无法完整审阅，已拒绝。")
            self._chat_line(f"{tool} 已拒绝（参数过长）", "toolerr")
            return False
        diff = None
        if is_prompt:
            try:
                data = params.get("arguments") or {}
                diff = data.get("diff")
                if not isinstance(diff, str):
                    from difflib import unified_diff
                    from ..prompts import PromptLibrary
                    library = PromptLibrary(home=role_path(self.cfg.role) / "prompts" if self.cfg.role else None)
                    library.ensure_home()
                    before = library.read(data["layer"])
                    diff = "".join(unified_diff(
                        before["content"].splitlines(keepends=True),
                        data["content"].splitlines(keepends=True),
                        fromfile=before["file"], tofile=before["file"] + " (proposed)"))
            except Exception:
                self._message("拒绝：缺少完整差异", "无法生成提示词变更的完整 diff，已拒绝；请重新发起请求。")
                return False
        dialog = ToolDialog(self, tool, arguments, diff=diff)
        approved = self._exec_dialog(dialog) == QDialog.DialogCode.Accepted
        self._chat_line(f"{tool} {'已批准' if approved else '已拒绝'}", "tool")
        return approved

    def refresh_context(self):
        self._sync_config()
        self._hardware_timer.stop()
        self._load_role_list()
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
        agent = "智能体：可用" if self.agent_available else "智能体：不可用"
        if self.agent_available and self.mcp_available:
            agent += " · MCP：可用"
        self.status_agent.setText(agent)
        flags = []
        if self.hardware_toggle.isChecked():
            flags.append("允许硬件")
        if self.actions_toggle.isChecked():
            flags.append("自动批准动作")
        if self.file_tools_toggle.isChecked():
            flags.append("文件")
        if self.shell_tools_toggle.isChecked():
            flags.append("Shell")
        if self.mcp_tools_toggle.isChecked():
            flags.append("MCP")
        busy = "执行中…" if self.busy else "空闲"
        self.status_busy.setText(busy + ("（" + "、".join(flags) + "）" if flags else ""))
        self.stop_button.setEnabled(self.busy or bool(self.pending_task))
        self._update_retry_buttons()

    def _set_busy(self, busy):
        self.busy = busy
        self.send_button.setEnabled(not busy)
        self.new_button.setEnabled(not busy)
        self.role_box.setEnabled(not busy)
        self.create_role_button.setEnabled(not busy)
        self.busy_progress.setVisible(busy)
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

    def __init__(self, parent, tool, arguments, *, diff=None):
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
        if tool == "prompt:update_prompt":
            self.resize(820, 680)
            self.warning = _label(
                "警告：prompt:update_prompt 将持久修改提示词，影响后续模型行为。\n"
                "请审阅完整差异；本次批准不授予未来自动修改权限。内容仅在此审批窗口显示。")
            layout.addWidget(self.warning)
            self.diff = QPlainTextEdit()
            self.diff.setReadOnly(True)
            self.diff.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
            self.diff.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
            self.diff.setPlainText(diff if diff else "（无文本差异）")
            layout.addWidget(self.diff, 2)
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
    """Tabbed operator settings covering every agent/backend switch."""

    def __init__(self, parent, cfg: GuiConfig, workspace, config_path=""):
        super().__init__(parent)
        _apply_theme(self)
        self.setWindowTitle("设置")
        self.setModal(True)
        self.resize(760, 760)
        self.values = None
        self.entries = {}
        self._workspace = workspace
        layout = QVBoxLayout(self)
        self.tabs = tabs = QTabWidget()
        layout.addWidget(tabs, 1)

        general = QWidget()
        general_form = QFormLayout(general)
        self._field(general_form, cfg, "workspace", "工作区", browse=True)
        self._field(general_form, cfg, "python", "Python 解释器")
        self._field(general_form, cfg, "scripts_dir", "脚本根目录", browse=True)
        self._field(general_form, cfg, "skills_dir", "技能目录", browse=True)
        self._field(general_form, cfg, "camera_src_dir", "图片源目录", browse=True)
        self._field(general_form, cfg, "module_paths", "模块路径（每行一个）", kind="lines")
        self._field(general_form, cfg, "read_vars", "读取变量（逗号分隔）")
        self._field(general_form, cfg, "camera_vars", "相机变量（逗号分隔）")
        tabs.addTab(general, "通用")

        model = QWidget()
        model_form = QFormLayout(model)
        self._field(model_form, cfg, "model", "模型（provider:model）")
        self._field(model_form, cfg, "base_url", "端点 Base URL")
        self._field(model_form, cfg, "api_key_env", "API Key 环境变量名")
        self.timeout = _spin(cfg.timeout, 3600, fractional=True)
        self.requests = _spin(cfg.max_requests, 100)
        self.tools = _spin(cfg.max_tool_calls, 1000)
        self.history_turns = _spin(cfg.history_turns, 20)
        self.history_bytes = _spin(max(1, cfg.max_history_bytes // 1024), 65536)
        self.max_context_enabled = QCheckBox("限制模型上下文窗口")
        self.max_context_enabled.setChecked(cfg.max_context_tokens is not None)
        self.max_context_tokens = _spin(cfg.max_context_tokens or 32768, 2 * 1024 * 1024)
        self.max_context_tokens.setMinimum(1024)
        self.context_reserve_tokens = _spin(cfg.context_reserve_tokens, 64 * 1024)
        self.context_reserve_tokens.setMinimum(0)
        self.max_context_tokens.setEnabled(self.max_context_enabled.isChecked())
        self.context_reserve_tokens.setEnabled(self.max_context_enabled.isChecked())
        self.max_context_enabled.toggled.connect(self.max_context_tokens.setEnabled)
        self.max_context_enabled.toggled.connect(self.context_reserve_tokens.setEnabled)
        for label, widget in (("超时（秒）", self.timeout), ("请求预算", self.requests),
                              ("工具预算", self.tools), ("历史轮数", self.history_turns),
                              ("历史上限（KiB）", self.history_bytes),
                              ("最大上下文（tokens）", self.max_context_tokens),
                              ("上下文预留（tokens）", self.context_reserve_tokens)):
            model_form.addRow(label, widget)
        model_form.addRow("", self.max_context_enabled)
        self.context_enabled = QCheckBox("注入工程上下文（工作区/结构/脚本清单）")
        self.context_enabled.setChecked(bool(cfg.context_bytes))
        self.context_kib = _spin(max(1, cfg.context_bytes // 1024), 64)
        self.context_enabled.toggled.connect(self.context_kib.setEnabled)
        self.context_kib.setEnabled(self.context_enabled.isChecked())
        context_row = QHBoxLayout()
        context_row.addWidget(self.context_enabled, 1)
        context_row.addWidget(self.context_kib)
        context_row.addWidget(_label("KiB"))
        model_form.addRow("工程上下文", context_row)
        self.intent_box = QComboBox()
        for value, label in INTENT_CHOICES:
            self.intent_box.addItem(label, value)
        index = self.intent_box.findData(cfg.intent_mode)
        self.intent_box.setCurrentIndex(max(0, index))
        model_form.addRow("意图路由", self.intent_box)
        self.sandbox_box = QComboBox()
        for value, label in SANDBOX_CHOICES:
            self.sandbox_box.addItem(label, value)
        sandbox_index = self.sandbox_box.findData(cfg.sandbox_mode)
        self.sandbox_box.setCurrentIndex(max(0, sandbox_index))
        model_form.addRow("Shell 沙箱", self.sandbox_box)
        self.session_log = QCheckBox("保存会话转录（~/.mybot/sessions）")
        self.session_log.setChecked(bool(cfg.session_log))
        model_form.addRow(self.session_log)
        model_form.addRow(_label("密钥只读取环境变量，窗口不保存也不显示它。", secondary=True))
        tabs.addTab(model, "模型与预算")

        permissions = QWidget()
        permission_form = QFormLayout(permissions)
        self.file_tools = QCheckBox("启用文件工具（工作区只读）")
        self.file_writes = QCheckBox("允许文件写入（逐次确认）")
        self.shell_tools = QCheckBox("启用 Shell 工具（沙箱可配置）")
        self.shell_grant = QCheckBox("自动批准 Shell")
        self.web_tools = QCheckBox("启用联网工具（抓取/搜索）")
        self.web_grant = QCheckBox("自动批准联网请求")
        self.mcp_grant = QCheckBox("自动批准 MCP 工具")
        for toggle, value in ((self.file_tools, cfg.enable_file_tools),
                              (self.file_writes, cfg.allow_file_writes),
                              (self.shell_tools, cfg.enable_shell),
                              (self.shell_grant, cfg.allow_shell),
                              (self.web_tools, cfg.enable_web),
                              (self.web_grant, cfg.allow_web),
                              (self.mcp_grant, cfg.allow_mcp_tools)):
            toggle.setChecked(bool(value))
            toggle.toggled.connect(self._permissions_changed)
            permission_form.addRow(toggle)
        permission_form.addRow(_label(
            "Shell 使用设置中的沙箱后端（bubblewrap 或工作区牢笼）；MCP 仍是宿主用户权限进程。\n"
            "自动批准只在本次启动有效；文件写入、Shell 和 MCP 自动批准在首次发送时仍会弹窗确认。", secondary=True))
        tabs.addTab(permissions, "权限")

        advanced = QWidget()
        advanced_form = QFormLayout(advanced)
        self._field(advanced_form, cfg, "mcp_config", "MCP 配置（mcpServers JSON）", browse_file=True)
        self._field(advanced_form, cfg, "prompt_file", "可选操作者指导文件（OPERATOR，≤8 KiB）",
                    browse_file=True, caption="选择操作者指导文件",
                    file_filter="Markdown/文本 (*.md *.txt);;所有文件 (*)")
        self._field(advanced_form, cfg, "search_endpoint", "SearXNG 搜索端点（留空仅抓取）")
        self._field(advanced_form, cfg, "vars", "变量覆盖（NAME=VALUE，每行一个，仅本次运行）", kind="lines")
        advanced_form.addRow(_label(f"配置文件：{config_path or '（默认位置）'}", secondary=True))
        tabs.addTab(advanced, "高级 / MCP")

        self.prompts = PromptPanel(
            self, auto_stats=cfg.auto_stats,
            home=role_path(cfg.role) / "prompts" if cfg.role else None,
            operator_path=lambda: _absolute(self.entries["prompt_file"].text(),
                                            self.entries["workspace"].text() or self._workspace))
        tabs.addTab(self.prompts, "提示词")
        tabs.currentChanged.connect(
            lambda _index: self.prompts.ensure_loaded() if tabs.currentWidget() is self.prompts else None)

        layout.addWidget(_label("运行时权限以左侧栏为准；这里保存偏好与预算。", secondary=True))
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setText("保存")
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        self.buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        self.buttons.accepted.connect(self._save)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)
        self._permissions_changed()

    def _field(self, form, cfg, name, label, *, kind="text", browse=False, browse_file=False,
               caption="选择 MCP 配置", file_filter="JSON (*.json)"):
        value = getattr(cfg, name)
        if kind == "lines" and name == "module_paths":
            widget = QPlainTextEdit("\n".join(value))
            widget.setMaximumHeight(85)
        elif kind == "lines":
            widget = QPlainTextEdit("\n".join(f"{key}={text}" for key, text in value.items()))
            widget.setMaximumHeight(85)
        else:
            widget = QLineEdit(",".join(value) if isinstance(value, list) else str(value or ""))
        self.entries[name] = widget
        if browse:
            row = QHBoxLayout()
            row.addWidget(widget)
            row.addWidget(_button("…", lambda checked=False, w=widget: self._browse(w)))
            form.addRow(label, row)
        elif browse_file:
            row = QHBoxLayout()
            row.addWidget(widget)
            row.addWidget(_button("…", lambda checked=False, w=widget: self._browse_file(
                w, caption, file_filter)))
            form.addRow(label, row)
        else:
            form.addRow(label, widget)

    def _browse(self, widget):
        chosen = QFileDialog.getExistingDirectory(self, "选择目录", self._workspace)
        if chosen:
            widget.setText(chosen)

    def _browse_file(self, widget, caption="选择 MCP 配置", file_filter="JSON (*.json)"):
        chosen, _ = QFileDialog.getOpenFileName(self, caption, self._workspace, file_filter)
        if chosen:
            widget.setText(chosen)

    def _permissions_changed(self):
        files = self.file_tools.isChecked()
        self.file_writes.setEnabled(files)
        self.shell_tools.setEnabled(files)
        if not files:
            self.file_writes.setChecked(False)
            self.shell_tools.setChecked(False)
        shell = self.shell_tools.isChecked()
        self.shell_grant.setEnabled(shell)
        if not shell:
            self.shell_grant.setChecked(False)
        web = self.web_tools.isChecked()
        self.web_grant.setEnabled(web)
        if not web:
            self.web_grant.setChecked(False)
        entry = self.entries.get("mcp_config")
        has_mcp = bool(entry is not None and entry.text().strip())
        self.mcp_grant.setEnabled(has_mcp)
        if not has_mcp:
            self.mcp_grant.setChecked(False)

    def _save(self):
        mcp_config = self.entries["mcp_config"].text().strip()
        if self.file_writes.isChecked() and not self.file_tools.isChecked():
            self._message("需要文件工具", "允许文件写入前，先启用文件工具。")
            return
        if self.mcp_grant.isChecked() and not mcp_config:
            self._message("需要 MCP 配置", "自动批准 MCP 工具前，先选择 mcpServers JSON 配置文件。")
            return
        if self.shell_grant.isChecked() and not self.shell_tools.isChecked():
            self._message("需要 Shell 工具", "自动批准 Shell 前，先启用 Shell 工具。")
            return
        if self.prompts.editor.document().isModified() and not self.prompts.save():
            return
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
                      max_tool_calls=self.tools.value(), history_turns=self.history_turns.value(),
                      max_history_bytes=max(64, self.history_bytes.value()) * 1024,
                      max_context_tokens=(self.max_context_tokens.value()
                                          if self.max_context_enabled.isChecked() else None),
                      context_reserve_tokens=self.context_reserve_tokens.value(),
                      context_bytes=(max(1, self.context_kib.value()) * 1024
                                     if self.context_enabled.isChecked() else 0),
                      intent_mode=self.intent_box.currentData(),
                      sandbox_mode=self.sandbox_box.currentData(),
                      session_log=self.session_log.isChecked(),
                      auto_stats=self.prompts.auto_stats.isChecked(),
                      enable_file_tools=self.file_tools.isChecked(),
                      enable_shell=self.shell_tools.isChecked(),
                      enable_web=self.web_tools.isChecked(),
                      allow_file_writes=self.file_writes.isChecked(),
                      allow_shell=self.shell_grant.isChecked(),
                      allow_web=self.web_grant.isChecked(),
                      allow_mcp_tools=self.mcp_grant.isChecked())
        self.values = values
        self.accept()

    def _message(self, title, text):
        QMessageBox.warning(self, title, text)


def _check_display():
    platform = os.environ.get("QT_QPA_PLATFORM", "").split(":", 1)[0].lower()
    if (sys.platform.startswith("linux") and not os.environ.get("DISPLAY")
            and not os.environ.get("WAYLAND_DISPLAY") and platform not in {"offscreen", "minimal"}):
        raise GuiUnavailable(
            "No graphical display: set DISPLAY/WAYLAND_DISPLAY, use --no-gui, "
            "or explicitly set QT_QPA_PLATFORM=offscreen for headless testing.")


def _splash_enabled(args):
    if getattr(args, "no_splash", False):
        return False
    value = os.environ.get("MYBOT_GUI_SPLASH", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


def _startup_status(window):
    state = window.serve_state
    if window.agent_available:
        state += " · 智能体就绪"
    if window.mcp_available:
        state += " · MCP 就绪"
    if window.serve is not None:
        hint = "服务已就绪；按 Enter 或点击按钮进入"
    elif window.starting or window._restart_pending:
        hint = "正在启动服务；也可以先进入，后台会继续"
    else:
        hint = "服务尚未就绪；进入后可在设置中检查解释器"
    return f"初始化：{state}", hint


def _fade_in(window):
    window.setWindowOpacity(0.0)
    window.show()
    window.raise_()
    window.activateWindow()
    animation = QPropertyAnimation(window, b"windowOpacity", window)
    animation.setDuration(280)
    animation.setStartValue(0.0)
    animation.setEndValue(1.0)
    animation.setEasingCurve(QEasingCurve.Type.OutCubic)
    animation.finished.connect(lambda: window.setWindowOpacity(1.0))
    window._entry_animation = animation
    animation.start()


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
    splash = None
    if _splash_enabled(args):
        splash = SplashScreen(lambda: _startup_status(window))
        splash.setWindowModality(Qt.WindowModality.ApplicationModal)
        screen = application.primaryScreen()
        if screen is not None:
            splash.move(screen.availableGeometry().center() - splash.rect().center())
        splash.entered.connect(lambda: splash.fade_out(lambda: _fade_in(window)))
        splash.cancelled.connect(lambda: (window.shutdown(), loop.quit()))
        splash.show()
    else:
        window.show()
    try:
        loop.exec()
    finally:
        if splash is not None:
            splash.close()
        window.shutdown()
        window.close()
        window.wait_for_shutdown()
        application.aboutToQuit.disconnect(window.shutdown)
        window.deleteLater()
    return {"closed": True}
