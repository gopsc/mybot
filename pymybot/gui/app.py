"""Native Qt window over the long-lived ``pymybot serve`` process."""
from __future__ import annotations

import json
import logging
import os
import queue
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import (QEasingCurve, QEventLoop, QPropertyAnimation, Qt, QTimer,
                            QUrl, Signal)
from PySide6.QtGui import (QAction, QColor, QDesktopServices, QFont, QFontDatabase, QFontMetrics,
                           QKeySequence, QPixmap, QTextCharFormat, QTextCursor, QTextDocument)
from PySide6.QtWidgets import (
    QApplication, QComboBox, QDialog, QFileDialog, QFormLayout, QHBoxLayout, QInputDialog,
    QLabel,
    QLineEdit, QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QProgressBar,
    QScrollArea, QSplitter, QTabWidget, QToolBox, QToolButton,
    QVBoxLayout, QWidget,
)

logger = logging.getLogger(__name__)

from ..agent_skills import default_skills_root
from ..paths import asset_path, source_root
from ..robot import module_roots
from ..roles import create_role as create_role_profile, list_roles, read_history, role_path
from ..session_log import session_root
from . import GuiUnavailable
from .branding import logo_icon, logo_pixmap
from .config import GuiConfig, absolute_path, config_home, default_workspace, merge_args
from .dialogs import (AboutDialog, CommandDialog, DoctorDialog, McpConfigDialog,
                      ModelSetupDialog, PreviewDialog, ResourcePanel, SessionsDialog)
from .files import FilesPanel, SnapshotDialog
from .protocol import RpcError, ServeClient, resolve_python
from .settings import SettingsDialog, ToolDialog
from .splash import SplashScreen
from .theme import PALETTE, apply_theme as _apply_theme
from .widgets import SafeTextBrowser, button as _button, label as _label

TITLE = "mybot · 智能体"
MAX_DIALOG_ARGS = 4000


def _brief(value, limit=160):
    if value is None:
        return ""
    try:
        text = json.dumps(value, ensure_ascii=False, sort_keys=False)
    except (TypeError, ValueError):
        text = str(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


class ChatTranscript(SafeTextBrowser):
    """Read-only transcript that never loads resources referenced by Markdown."""


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
        self.run_id = None
        self.turn_text = 0
        self.at_line_start = True
        self._assistant_start = None
        self._assistant_markdown = ""
        # Last completed assistant segment, kept for speech after it is flushed.
        self._last_reply_markdown = ""
        self.pending_start = False
        self.pending_reset = False
        self._delete_role_name = ""
        self._resource_roots = None
        self._files_root = None
        self._stopping = False
        self._lifecycle_lock = threading.Lock()
        self._clients = {}
        self._lifecycle_workers = []
        self._dialogs = set()
        self.font_mono = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        from .voice import Speaker
        self.speaker = Speaker()
        self.speech_enabled = False

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
        self._load_role_list()
        self._load_role_history()
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))
        self._start_timer.start(120)
        self._refresh_status()
        self.web_button.blockSignals(True)
        # Respect the stored preference (web defaults to enabled). Approval
        # grants are runtime-only, so web starts pre-approved only when the
        # saved preference has web enabled.
        self.web_button.setChecked(bool(self.cfg.enable_web))
        self.cfg.allow_web = bool(self.cfg.enable_web)
        self.web_button.blockSignals(False)
        QTimer.singleShot(600, self._probe_speech)

    def _probe_speech(self):
        """Probe TTS off the constructor; disable the toggle when unusable."""
        if self._stopping or self.speech_button.isChecked():
            return
        if not self.speaker.available:
            self.speech_button.setEnabled(False)
            self.speech_button.setToolTip("本机没有可用的文本转语音引擎")

    def maybe_model_setup(self):
        """First-run wizard: offer guided model setup exactly once.

        Called by run_gui once the main window is visible — never during
        construction, so embedding or testing the window cannot trip a modal
        dialog. Skipped or completed, the visit is remembered so the dialog
        never nags; the settings dialog remains the manual path. Headless runs
        and MYBOT_GUI_MODEL_WIZARD=0 never open the dialog.
        """
        if self._stopping or self.cfg.model_setup_done:
            return
        enabled = os.environ.get("MYBOT_GUI_MODEL_WIZARD", "1").strip().lower()
        if enabled in {"0", "false", "no", "off"}:
            return
        if self.cfg.model or os.environ.get("MYBOT_MODEL"):
            self.cfg.model_setup_done = True
            self._save()
            return
        self._run_model_wizard()

    def open_model_wizard(self):
        """Manual entry from the sidebar; the once-gate never applies here."""
        if not self._stopping:
            self._run_model_wizard()

    def _run_model_wizard(self):
        dialog = ModelSetupDialog(self)
        accepted = self._exec_dialog(dialog) == QDialog.DialogCode.Accepted and dialog.values
        self.cfg.model_setup_done = True
        if accepted:
            for key in ("model", "base_url", "api_key_env"):
                setattr(self.cfg, key, dialog.values[key])
            self._sync_controls()
            self._refresh_model_label()
            self._notice("模型已配置；新对话将使用它")
        self._save()

    def _build(self):
        self.setWindowTitle(TITLE)
        self.resize(1180, 780)
        self.setMinimumSize(900, 600)
        self._build_menu()
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(16, 14, 16, 12)
        layout.setSpacing(12)
        toolbar = QHBoxLayout()
        toolbar.setSpacing(8)
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
        role_caption = _label("角色")
        role_caption.setWordWrap(False)
        toolbar.addWidget(role_caption)
        self.role_box = QComboBox()
        self.role_box.setMinimumWidth(130)
        self.role_box.activated.connect(self.on_role_changed)
        toolbar.addWidget(self.role_box)
        self.create_role_button = _button("新建", self.new_role)
        toolbar.addWidget(self.create_role_button)
        self.delete_role_button = _button("删除", self.delete_role)
        toolbar.addWidget(self.delete_role_button)
        self.refresh_button = _button("刷新", self.refresh_context)
        toolbar.addWidget(self.refresh_button)
        self.clear_button = _button("清空", self.clear_chat)
        self.clear_button.setToolTip("清空窗口记录；模型上下文不受影响")
        toolbar.addWidget(self.clear_button)
        self.snapshot_button = _button("抓拍", self.capture_snapshot)
        self.snapshot_button.setToolTip("用主机摄像头抓拍一张照片并预览（内置视觉工具）")
        toolbar.addWidget(self.snapshot_button)
        self.speech_button = QToolButton()
        self.speech_button.setText("朗读")
        self.speech_button.setCheckable(True)
        self.speech_button.setToolTip("朗读助手的最新回复（Qt 文本转语音；不可用时禁用）")
        self.speech_button.toggled.connect(self.toggle_speech)
        toolbar.addWidget(self.speech_button)
        self.web_button = QToolButton()
        self.web_button.setText("联网")
        self.web_button.setCheckable(True)
        self.web_button.setToolTip("开启后智能体获得 web_fetch / web_search（搜索端点在设置中配置）；新会话生效")
        self.web_button.toggled.connect(self.toggle_web)
        toolbar.addWidget(self.web_button)
        toolbar.addStretch(1)
        self.manage_button = QToolButton()
        self.manage_button.setText("管理")
        self.manage_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.manage_button.setMenu(self._manage_menu())
        toolbar.addWidget(self.manage_button)
        toolbar.addWidget(_button("命令", self.open_console))
        self.new_button = _button("新对话", self.new_conversation)
        self.stop_button = _button("停止", self.stop_autonomy, role="danger")
        self.abort_button = _button("急停", self.abort_all, role="danger")
        self.abort_button.setToolTip("停止当前动作并调用驱动的 safe()；不是硬件急停")
        toolbar.addWidget(self.new_button)
        toolbar.addWidget(self.stop_button)
        toolbar.addWidget(self.abort_button)
        toolbar.addWidget(_button("设置", self.open_settings))

        body = QSplitter(Qt.Orientation.Horizontal)
        body.setHandleWidth(6)
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
        action(files, "新对话", self.new_conversation, "Ctrl+N")
        action(files, "刷新上下文", self.refresh_context, "F5")
        files.addSeparator()
        action(files, "设置…", self.open_settings, "Ctrl+,")
        files.addSeparator()
        action(files, "退出", self.close, "Ctrl+Q")

        tools = bar.addMenu("工具")
        action(tools, "命令面板…", self.open_console, "Ctrl+Shift+P")
        action(tools, "MCP 配置…", self.open_mcp)
        action(tools, "会话管理…", self.open_sessions)
        action(tools, "长期记忆…", self.open_memory)
        action(tools, "任务历史…", self.open_missions)
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
        for text, slot in (("命令面板…", self.open_console),
                           ("MCP 配置…", self.open_mcp),
                           ("会话管理…", self.open_sessions),
                           ("长期记忆…", self.open_memory), ("任务历史…", self.open_missions),
                           ("环境诊断…", self.open_doctor),
                           ("资源预览", self.show_resources), ("清空对话", self.clear_chat)):
            action = QAction(text, menu)
            action.triggered.connect(lambda _checked=False, fn=slot: fn())
            menu.addAction(action)
        return menu

    def _set_workspace_label(self, text):
        self.workspace_label.setToolTip(text)
        self.workspace_label.setText(QFontMetrics(self.workspace_label.font()).elidedText(
            text, Qt.TextElideMode.ElideMiddle, self.workspace_label.maximumWidth()))
        if getattr(self, "files", None) is not None:
            # Every workspace/role change funnels through here, so the file
            # browser follows without needing a tab switch.
            self._sync_files_root()

    def _build_side(self, side):
        """Collapsible card sidebar: status, robot context, model.

        QToolBox keeps one card open at a time so the window stays calm; the
        status card offers a jump to the log instead of duplicating it.
        """
        layout = QVBoxLayout(side)
        layout.setContentsMargins(0, 0, 4, 0)
        self.side_box = QToolBox(side)
        self.side_box.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        layout.addWidget(self.side_box)

        status_page = QWidget()
        status_layout = QVBoxLayout(status_page)
        status_layout.setContentsMargins(8, 8, 8, 8)
        self.status_card = QLabel()
        self.status_card.setWordWrap(True)
        self.status_card.setTextFormat(Qt.TextFormat.PlainText)
        status_layout.addWidget(self.status_card)
        self.busy_progress = QProgressBar()
        self.busy_progress.setRange(0, 0)
        self.busy_progress.setTextVisible(False)
        self.busy_progress.hide()
        status_layout.addWidget(self.busy_progress)
        status_layout.addWidget(_button("查看运行日志", lambda: self.notebook.setCurrentWidget(self.log)))
        status_layout.addWidget(_label("联网与朗读开关在工具栏；搜索端点在设置中配置。", secondary=True))
        status_layout.addStretch()
        self.side_box.addItem(status_page, "状态")

        robot = QWidget()
        form = QFormLayout(robot)
        self.context_entries = {}
        fields = (
            ("skills_dir", "技能目录", "dir"),
            ("mcp_config", "MCP 配置（mcpServers JSON）", "edit"),
        )
        for name, label, mode in fields:
            row = QHBoxLayout()
            value = getattr(self.cfg, name)
            entry = QLineEdit(value)
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
        form.addRow(_label(
            "可信技能（run_skill）执行免审批并默认获得硬件权限；只安装你信任的技能。"
            "文件、Shell、联网和 MCP 工具默认开启并免审批；提示词更新仍逐次确认。",
            secondary=True))
        self.side_box.addItem(robot, "机器人上下文")

        model = QWidget()
        model_layout = QVBoxLayout(model)
        model_layout.setContentsMargins(8, 8, 8, 8)
        self.model_label = _label()
        model_layout.addWidget(self.model_label)
        model_layout.addWidget(_button("配置向导", self.open_model_wizard))
        model_layout.addStretch()
        self.side_box.addItem(model, "模型")
        self._refresh_model_label()

    def _build_chat(self, right):
        layout = QVBoxLayout(right)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)
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
        self.files = FilesPanel()
        self.notebook.addTab(self.chat, "对话")
        self.notebook.addTab(self.log, "日志")
        self.notebook.addTab(self.files, "文件")
        self.notebook.addTab(self.resources, "资源")
        self.notebook.currentChanged.connect(self._on_tab_changed)
        layout.addWidget(self.notebook, 1)
        self.task_edit = QLineEdit(self.cfg.task)
        self.task_edit.setPlaceholderText("可选：给自主循环一个初始目标；留空则由记忆体自拟，回车即启动")
        self.task_edit.setClearButtonEnabled(True)
        self.task_edit.returnPressed.connect(self.start_autonomy)
        layout.addWidget(self.task_edit)
        controls = QHBoxLayout()
        controls.setSpacing(10)
        self.start_button = _button("启动", self.start_autonomy, role="primary")
        self.start_button.setToolTip("记忆体自拟目标并持续派活给执行体；人类只观察和停止")
        self.stop_button.setToolTip("停止当前的自主循环")
        controls.addWidget(self.start_button)
        controls.addWidget(self.stop_button)
        self.run_state = _label("未启动", secondary=True)
        controls.addWidget(self.run_state, 1)
        layout.addLayout(controls)

    def _on_tab_changed(self, index):
        if self.notebook.widget(index) is self.resources:
            self.show_resources()
        elif self.notebook.widget(index) is self.files:
            self.show_files()

    def _sync_files_root(self):
        """Point the file browser at the current workspace/role (no tab switch)."""
        root = str(Path(self._workspace_root()).absolute())
        if root != self._files_root:
            self._files_root = root
            self.files.set_root(root)

    def show_files(self):
        self._sync_files_root()
        self.notebook.setCurrentWidget(self.files)

    def _robots_root(self):
        workspace = Path(self._workspace_root()).absolute()
        candidate = workspace / "robots"
        if candidate.is_dir():
            return str(candidate)
        if workspace == source_root() and asset_path("robots").is_dir():
            return str(asset_path("robots"))
        return ""

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
                logger.error("%s: %s", type(exc).__name__, exc)

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
        if markdown.strip():
            self._last_reply_markdown = markdown
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
            setattr(self.cfg, name, entry.text().strip())

    def _sync_controls(self):
        for name, entry in self.context_entries.items():
            entry.setText(getattr(self.cfg, name))
        self._sync_role_paths()

    def _browse_into(self, entry):
        chosen = QFileDialog.getExistingDirectory(self, "选择目录", self._workspace_root())
        if chosen:
            entry.setText(chosen)
            self._sync_config()

    def _refresh_model_label(self):
        model = self.cfg.model or os.environ.get("MYBOT_MODEL", "")
        key_env = self.cfg.api_key_env or "厂商默认变量"
        endpoint = self.cfg.base_url or "厂商默认"
        self.model_label.setText(f"模型：{model or '未设置（需 MYBOT_MODEL）'}\n端点：{endpoint}\n密钥变量：{key_env}")

    def pick_workspace(self):
        if self.busy:
            self._notice("执行中不能切换工作区；先停止当前这一轮")
            return
        if self.cfg.role:
            self._notice(f"当前角色使用固定工作区：{self._workspace_root()}", seconds=8)
            return
        chosen = QFileDialog.getExistingDirectory(self, "打开工作区", self._workspace_root())
        if not chosen or self._stopping:
            return
        self.cfg.workspace = chosen
        self.refresh_context()
        self._restart_server()

    def _load_role_list(self):
        current = self.cfg.role
        try:
            roles = list_roles()
        except OSError:
            roles = []
        self.role_box.blockSignals(True)
        self.role_box.clear()
        for item in roles:
            self.role_box.addItem(item["name"], item["name"])
            index = self.role_box.count() - 1
            self.role_box.setItemData(index, item.get("description") or item["root"],
                                      Qt.ItemDataRole.ToolTipRole)
        index = self.role_box.findData(current)
        if index < 0 and self.role_box.count():
            # Conversations are role-scoped; never fall back to a global prompt.
            index = 0
        self.role_box.setCurrentIndex(index)
        self.role_box.setPlaceholderText("未创建角色")
        self.cfg.role = self.role_box.currentData() or ""
        self.role_box.blockSignals(False)
        self.delete_role_button.setEnabled(bool(self.cfg.role))
        self._sync_role_paths()
        if not roles:
            self._notice("对话需要角色：点工具栏「新建」创建后再发送", seconds=10)

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

    def on_role_changed(self):
        previous = self.cfg.role
        self.cfg.role = self.role_box.currentData() or ""
        if self.cfg.role != previous:
            # The serve child keeps the previous role's conversation (and its
            # workspace lock and hardware) until something asks it to close.
            # Switching roles is the operator leaving that conversation, so
            # release it before the next turn can claim another role.
            self._release_conversation()
            self._clear_transcript()
        self.delete_role_button.setEnabled(bool(self.cfg.role))
        self._sync_role_paths()
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))
        self._resource_roots = None
        self._save()
        self._load_role_history()
        self._notice(f"已选择角色：{self.cfg.role}" if self.cfg.role else "请先新建角色再对话")

    def _release_conversation(self):
        """Close the active Agent conversation without clearing saved history."""
        client = self.serve
        if client is None or self._stopping:
            return
        generation = self.generation
        try:
            _, future = client.start_request("agent.reset", {})
        except RpcError as exc:
            self._log(f"[gui] 关闭上一角色的会话失败：{exc}\n")
            return
        self._background(lambda: future.result(),
                         lambda _value, error: self._conversation_released(generation, error))

    def _conversation_released(self, generation, error):
        if generation != self.generation or self._stopping:
            return
        if error is not None:
            self._log(f"[gui] 关闭上一角色的会话失败：{error}\n")
            self._notice("上一角色的会话未能关闭；发送前会再次尝试")
            self._refresh_status()
        else:
            self._refresh_status()

    def new_role(self):
        if self._stopping or self.busy:
            return
        name, accepted = QInputDialog.getText(self, "新建 Agent 角色", "角色名（字母、数字、中文、_、-、.）：")
        name = name.strip()
        if not accepted or not name:
            return
        workspace = self._workspace_root()
        skills = self._skills_root()
        source = Path(skills) if skills else None
        if source is None or not source.is_dir() or not any(source.glob("*/SKILL.md")):
            bundled = Path(default_skills_root())
            if bundled.is_dir() and any(bundled.glob("*/SKILL.md")):
                skills = str(bundled)
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
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))
        self._save()
        self._notice(f"角色 {role.name} 已创建：{role.root}")
        if workspace:
            self._resource_roots = None

    def delete_role(self):
        if self._stopping or self.busy:
            return
        name = self.cfg.role
        if not name:
            self._notice("没有选中的角色")
            return
        if not self._message("删除角色",
                             f"将永久删除角色「{name}」及其提示词、技能、工作区文件和对话历史，不可恢复。\n确定删除？",
                             confirm=True):
            return
        self._delete_role_name = name
        if self.serve is None:
            self._finish_delete_role(self.generation, None)
            return
        generation = self.generation
        self._notice("正在关闭该角色的会话…")
        try:
            # Close the Agent before removing the directory it reads and writes.
            _, future = self.serve.start_request("agent.reset", {})
        except RpcError as exc:
            self._finish_delete_role(generation, exc)
            return
        self._background(lambda: future.result(),
                         lambda _value, error: self._finish_delete_role(generation, error))

    def _finish_delete_role(self, generation, error):
        if generation != self.generation or self._stopping:
            return
        name, self._delete_role_name = self._delete_role_name, ""
        if not name:
            return
        if error is not None:
            self._message("删除角色失败", f"无法关闭当前会话：{error}")
            return
        try:
            from ..roles import delete_role as remove_role
            remove_role(name)
        except Exception as exc:
            self._message("删除角色失败", str(exc))
            return
        self.cfg.role = ""
        self._load_role_list()
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))
        self._resource_roots = None
        self._save()
        self._notice(f"已删除角色：{name}")
        self.refresh_context()

    def _workspace_root(self):
        if self.cfg.role:
            return str(role_path(self.cfg.role) / "workspace")
        return self.cfg.workspace or default_workspace()

    def _scripts_root(self):
        root = self._workspace_root()
        configured = absolute_path(self.cfg.scripts_dir, root)
        if configured:
            return configured
        candidate = Path(root).absolute() / "scripts"
        if candidate.is_dir():
            return str(candidate)
        if Path(root).absolute() == source_root() and asset_path("scripts").is_dir():
            return str(asset_path("scripts"))
        return str(Path(root).absolute())

    def _skills_root(self):
        if self.cfg.role:
            return str(role_path(self.cfg.role) / "skills")
        return absolute_path(self.cfg.skills_dir, self._workspace_root())

    def _mcp_root(self):
        if self.cfg.role:
            return str(role_path(self.cfg.role) / "mcp.json")
        return absolute_path(self.cfg.mcp_config, self._workspace_root())

    def _module_paths(self):
        root = self._workspace_root()
        values = [absolute_path(item, root) for item in self.cfg.module_paths if str(item).strip()]
        if Path(root).absolute() == source_root():
            values = [str(asset_path("modules")) if value == str(Path(root).absolute() / "modules")
                      and not Path(value).exists() else value for value in values]
        return values

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
            logger.warning("stop failed: %s", exc)
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
        workspace = self._workspace_root()
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
            self._chat_line("智能体不可用：当前解释器缺少 LangGraph/LangChain 依赖。", "error")
            self._chat_line("安装 pymybot[agent] 后重启本窗口；或用 --no-gui 走命令行控制器。", "system")
        elif not self.greeted:
            self.greeted = True
            self._chat_line("点「启动」开始自主运行：记忆体自拟目标，执行体通过可信技能动手。", "system")
        self._refresh_status()
        if self.pending_reset:
            self.pending_reset = False
            self.pending_start = False
            self._request_reset()
            self._refresh_status()
        elif self.pending_start:
            self.pending_start = False
            self._submit_start()
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
        if params.get("id") not in {self.turn_id, self.run_id}:
            return
        event = params.get("event") or {}
        kind = event.get("type")
        if kind == "text_delta":
            self._chat_delta(str(event.get("text") or ""))
        elif kind == "team.message":
            agent = event.get("agent") or "memory"
            label = "记忆体" if agent == "memory" else "执行体" if agent == "worker" else "系统"
            self._chat_line(f"[{label}] {event.get('text') or ''}", agent if agent in PALETTE else "system")
        elif kind == "mission.start":
            self._chat_line(f"▶ 任务 {event.get('mission') or ''}：{_brief(event.get('goal'), 120)}", "system")
        elif kind == "mission.end":
            usage = event.get("usage") or {}
            reason = event.get("reason") or ""
            line = (f"■ 任务结束：{event.get('status')} · 步数 {usage.get('steps', '?')}"
                    f" · 尝试 {usage.get('attempts', '?')}")
            if reason:
                line += f" · {_brief(reason, 160)}"
            self._chat_line(line, "system")
            if self.speech_enabled:
                self.speaker.say(self._last_reply_markdown or
                                 f"任务结束，状态{event.get('status')}。")
        elif kind == "team.propose":
            self._notice(f"记忆体自拟目标：{_brief(event.get('goal'), 80)}", seconds=4)
        elif kind == "team.stopped":
            self.run_id = None
            self._set_busy(False)
            self._chat_line(f"自主循环结束：{event.get('state') or ''}".rstrip(), "system")
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

    def _require_role(self):
        if self.cfg.role:
            return True
        self._notice("请先新建一个角色再启动")
        self._chat_line("自主运行需要角色：点工具栏「新建」创建角色后再启动。", "system")
        return False

    def start_autonomy(self):
        if self._stopping or self.busy:
            return
        if not self._require_role():
            return
        if self.serve is None:
            self.pending_start = True
            self._notice("正在启动 pymybot serve…")
            self._start_server()
            self._refresh_status()
            return
        self._submit_start()

    def _submit_start(self):
        if not self.agent_available:
            self._notice("智能体不可用：缺少 LangGraph/LangChain 依赖")
            return
        if not self._require_role():
            return
        self._sync_config()
        client, generation = self.serve, self.generation
        if self._stopping or client is None or self.busy:
            return
        try:
            from ..prompts import PromptLibrary
            library = PromptLibrary(home=role_path(self.cfg.role) / "prompts" if self.cfg.role else None,
                                extra_layers=bool(self.cfg.role))
            library.ensure_home()
            library.compose()
        except Exception as exc:
            self._message("启动已阻止：提示词安全校验失败",
                          f"{exc}\n\n0 / 100 安全层必须保持完整。请到「设置 → 提示词」"
                          "检查，必要时明确确认「恢复全部默认」修复后再启动。")
            return
        try:
            ident, future = client.start_request("agent.start", self._agent_params())
        except RpcError as exc:
            self._chat_line(str(exc), "error")
            return
        self.run_id = ident
        self.turn_id = None
        self.turn_text = 0
        self.at_line_start = True
        self._chat_line("▶ 启动自主运行：记忆体自拟目标，执行体动手；人类不参与。", "system")
        self._set_busy(True)
        self._background(lambda: future.result(),
                         lambda value, error: self._start_done(generation, ident, value, error))

    def _start_done(self, generation, ident, result, error):
        if self._stopping or generation != self.generation:
            return
        if self.run_id != ident:
            return  # A stop won the race; do not revive the busy state.
        if error is not None:
            self.run_id = None
            self._set_busy(False)
            self._chat_line(str(error), "error")
            return
        state = (result or {}).get("state") or "running"
        if (result or {}).get("running") is False:
            self.run_id = None
            self._set_busy(False)
            self._chat_line(f"自主循环已结束（{state}）。", "system")
            return
        self.run_id = ident
        self._set_busy(True)
        self._chat_line(f"自主循环运行中（{state}）。点「停止」结束。", "system")

    def stop_autonomy(self):
        client = self.serve
        if client is None:
            self.pending_start = False
            self._notice("服务未启动，已取消排队的启动")
            return
        if self.run_id is None:
            return
        try:
            _, future = client.start_request("agent.stop", {})
        except RpcError as exc:
            self._notice(f"停止失败：{exc}")
            return
        self.run_id = None
        self._notice("已请求停止自主循环…")
        self._background(lambda: future.result(),
                         lambda value, error: self._stop_done(value, error))

    def _stop_done(self, result, error):
        self.run_id = None
        if error is not None:
            self._chat_line(str(error), "error")
        else:
            self._chat_line("[已停止] 自主循环结束。", "system")
        self._set_busy(False)

    def _agent_params(self):
        """Agent parameters; hardware structures belong to the skill, not the GUI.

        The controller runtime and its ``robots/`` live in the hardware-controller
        skill, so an agent conversation never loads a structure of its own.
        """
        workspace = self._workspace_root()
        params = {
            "role": self.cfg.role or None,
            "skillsDir": "" if self.cfg.role else self._skills_root(),
            "mcpConfig": "" if self.cfg.role else self._mcp_root(),
            "allowMcpTools": True,
            "allowShell": True,
            "workspaceDir": workspace,
            "enableShell": True,
            "allowFileWrites": True,
            "maxHistoryBytes": self.cfg.max_history_bytes,
            "maxContextTokens": self.cfg.max_context_tokens,
            "contextReserveTokens": self.cfg.context_reserve_tokens,
            "maxRequests": self.cfg.max_requests,
            "maxToolCalls": self.cfg.max_tool_calls,
            "turnTimeout": self.cfg.turn_timeout,
            "modelRetries": self.cfg.model_retries,
            "fallbackModels": self.cfg.fallback_models,
            "requirePlanApproval": self.cfg.require_plan_approval,
            "timeout": self.cfg.timeout,
            "hotTurns": self.cfg.hot_turns,
            "warmTurns": self.cfg.warm_turns,
            "promptFile": absolute_path(self.cfg.prompt_file, workspace),
            "autoStats": self.cfg.auto_stats,
            "contextBytes": self.cfg.context_bytes,
            "intent": self.cfg.intent_mode,
            "sandbox": self.cfg.sandbox_mode,
            "protectPrompts": self.cfg.protect_prompts,
            # Web access follows the sidebar toggle; the SearXNG endpoint lives
            # in settings (empty endpoint means fetch-only).
            "enableWeb": bool(self.cfg.enable_web),
            "allowWeb": bool(self.cfg.allow_web),
            "searchEndpoint": self.cfg.search_endpoint,
        }
        goal = self.task_edit.text().strip()
        if goal:
            # Optional operator seed for the first mission; the memory agent
            # still proposes every later goal itself.
            params["task"] = goal
        for key, name in (("model", "model"), ("baseUrl", "base_url"), ("apiKeyEnv", "api_key_env")):
            value = getattr(self.cfg, name)
            if value:
                params[key] = value
        return {key: value for key, value in params.items() if value not in ("", [], None)}

    def _show_prompt_version(self, digest):
        if isinstance(digest, str) and len(digest) >= 16 and all(c in "0123456789abcdef" for c in digest.lower()):
            self.status_prompt.setText(f"提示词：{digest[:16]}")

    def toggle_speech(self, checked):
        """Read the latest assistant reply aloud whenever a turn finishes."""
        self.speech_enabled = bool(checked)
        if not checked:
            self.speaker.stop()
            return
        if not self.speaker.available:
            self.speech_button.setChecked(False)
            self._notice("本机没有可用的文本转语音引擎，朗读不可用")
            return
        self._notice("朗读已开启；回复完成后自动播报")

    def toggle_web(self, checked):
        self.cfg.enable_web = bool(checked)
        self.cfg.allow_web = bool(checked)
        self._save()
        self._notice("联网已开启，新会话生效；SearXNG 搜索端点在设置中配置"
                     if checked else "联网已关闭，新会话生效")

    def capture_snapshot(self):
        """Built-in vision: enumerate and grab off the UI thread, then preview."""
        if self.busy:
            self._notice("执行中不能抓拍；先停止当前这一轮")
            return
        if not self.snapshot_button.isEnabled():
            return
        self.snapshot_button.setEnabled(False)
        self._notice("正在抓拍…")

        def grab():
            from ..camera import CameraError, CameraService
            service = CameraService()
            cameras = service.list_cameras().get("cameras") or []
            if not cameras:
                raise CameraError("未发现可用摄像头")
            return service.capture(cameras[0].get("index", 0))

        self._background(grab, self._snapshot_done)

    def _snapshot_done(self, result, error):
        if self._stopping:
            return
        self.snapshot_button.setEnabled(True)
        if error is not None:
            self._notice(f"抓拍失败：{error}" if str(error) else f"抓拍失败：{type(error).__name__}")
            return
        data = (result or {}).get("data") or b""
        pixmap = QPixmap()
        if not data or not pixmap.loadFromData(data):
            self._notice("抓拍返回了无效图像")
            return
        self._exec_dialog(SnapshotDialog(self, pixmap, workspace=self._workspace_root(),
                                         width=result.get("width"), height=result.get("height")))

    def abort_all(self):
        """Best-effort stop; no confirmation so it remains usable in a hurry."""
        client = self.serve
        if client is None:
            self._notice("服务未启动，无法发送急停")
            return
        if self.turn_id is not None:
            client.cancel(self.turn_id)
        self._dismiss_approvals()
        self._notice("已发送急停请求…")
        generation = self.generation
        try:
            _, future = client.start_request("abort", {})
        except RpcError as exc:
            self._notice(f"急停失败：{exc}")
            return
        self._background(lambda: future.result(), lambda value, error: self._abort_done(generation, value, error))

    def _abort_done(self, generation, result, error):
        if generation != self.generation or self._stopping:
            return
        if error is not None:
            self._notice(f"急停失败：{error}", seconds=12)
            return
        result = result or {}
        if result.get("ok") is False:
            self._notice("急停请求失败：" + str((result.get("error") or {}).get("message", "未知错误")), seconds=12)
        elif result.get("aborted") is False:
            self._notice("没有活动硬件会话；当前对话已停止", seconds=8)
        else:
            failures = len(result.get("safe_failures") or [])
            suffix = f"（{failures} 个 safe() 失败）" if failures else ""
            self._notice("急停完成，硬件会话已释放" + suffix, seconds=12)
        self._refresh_status()

    def new_conversation(self):
        if self._stopping:
            return
        if self.busy:
            self._notice("先停止当前这一轮")
            return
        if self.serve is None:
            # Queue the reset instead of silently doing nothing on the first click.
            self.pending_reset = True
            self._notice("正在启动 pymybot serve，就绪后开始新对话…")
            self._start_server()
            return
        self._request_reset()

    def _request_reset(self):
        if self.serve is None or self._stopping:
            return
        generation = self.generation
        params = {"clearHistory": True}
        if self.cfg.role:
            params["role"] = self.cfg.role
        try:
            _, future = self.serve.start_request("agent.reset", params)
        except RpcError as exc:
            self._on_reset(generation, exc)
            return
        self._background(lambda: future.result(), lambda _value, error: self._on_reset(generation, error))

    def _on_reset(self, generation, error):
        if generation != self.generation or self._stopping:
            return
        if error is not None:
            self._chat_line(f"重置失败：{error}", "error")
            return
        # A new conversation must look new: drop the visible transcript too.
        self._clear_transcript()
        self._chat_line("[新对话，硬件已释放]", "system")
        self._refresh_status()

    def clear_chat(self):
        if not self.chat.toPlainText().strip():
            return
        if not self._message("清空对话", "只清空窗口中的记录；模型上下文和磁盘转录都不受影响。\n要重置模型上下文，请用工具栏的「新对话」。", confirm=True):
            return
        self._clear_transcript()
        self._notice("对话已清空（模型上下文未变）")

    def _clear_transcript(self):
        self.chat.clear()
        self.at_line_start = True
        self.turn_text = 0
        self._assistant_start = None
        self._assistant_markdown = ""
        self._last_reply_markdown = ""

    def _load_role_history(self):
        """Populate the chat widget with the selected role's stored conversation."""
        if not self.cfg.role:
            return
        try:
            path = role_path(self.cfg.role) / "history.json"
            raw_turns, cold, warm = read_history(path)
        except Exception:
            return
        if not raw_turns and not cold and not warm:
            return
        self._clear_transcript()
        if cold or warm:
            older = len(warm) if warm else 0
            if cold and older:
                self._chat_line(f"[之前有 {older} 轮以上的对话已压缩为摘要]", "system")
            elif cold:
                self._chat_line("[之前有较早的对话已压缩为摘要]", "system")
            elif older:
                self._chat_line(f"[之前有 {older} 轮对话已压缩为摘要]", "system")
        for turn in raw_turns:
            if not isinstance(turn, list):
                continue
            for msg in turn:
                if not isinstance(msg, dict):
                    continue
                msg_type = msg.get("type", "")
                data = msg.get("data") if isinstance(msg.get("data"), dict) else {}
                content = data.get("content", "")
                if not isinstance(content, str) or not content:
                    continue
                if msg_type == "human":
                    self._chat_line(f"你：{content}", "user")
                elif msg_type == "ai":
                    self._history_assistant(content)

    def _history_assistant(self, content):
        """Render a stored AI message with markdown formatting."""
        if not content or self._stopping:
            return
        self._flush_markdown()
        cursor = self.chat.textCursor()
        cursor.movePosition(QTextCursor.MoveOperation.End)
        if not self.at_line_start:
            self._insert_text(self.chat, "\n")
            self.at_line_start = True
        self._assistant_start = cursor.position()
        self._assistant_markdown = content
        self._insert_text(self.chat, content, "assistant")
        self.at_line_start = content.endswith("\n")
        self._flush_markdown()

    def copy_chat(self):
        text = self.chat.toPlainText().strip()
        if text:
            QApplication.clipboard().setText(text)
            self._notice("对话已复制到剪贴板")

    def open_mcp(self):
        if self._stopping:
            return
        self._sync_config()
        workspace = self._workspace_root()
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

    def _open_agent_preview(self, method, title, params=None, transform=None):
        if self._stopping:
            return
        client = self.serve
        if client is None:
            self._notice("服务未启动")
            return
        generation = self.generation

        def done(value, error):
            if self._stopping or generation != self.generation:
                return
            if error is not None:
                self._notice(f"{title}读取失败：{error}")
                return
            payload = transform(value) if transform else value
            text = json.dumps(payload, ensure_ascii=False, indent=2)
            self._exec_dialog(PreviewDialog(self, title, text, language="text"))

        try:
            _, future = client.start_request(method, params or {})
        except RpcError as exc:
            self._notice(f"{title}读取失败：{exc}")
            return
        self._background(lambda: future.result(), done)

    def open_memory(self):
        self._open_agent_preview(
            "agent.memory", "长期记忆", {"limit": 200},
            transform=lambda value: {
                "stats": (value or {}).get("stats"),
                "entries": (value or {}).get("entries") or [],
            })

    def open_missions(self):
        self._open_agent_preview(
            "agent.missions", "任务历史", {"limit": 100},
            transform=lambda value: (value or {}).get("missions") or [])

    def open_console(self):
        if self._stopping:
            return
        if self.busy:
            self._notice("执行中不能打开命令面板：第二次硬件会话会与当前轮冲突")
            return
        self._sync_config()
        workspace = self._workspace_root()
        dialog = CommandDialog(
            self, python=resolve_python(workspace, self.cfg.python), cwd=workspace,
            module_paths=self._module_paths(),
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

    def _ask_tool(self, params):
        tool = str(params.get("tool") or "?")
        try:
            arguments = json.dumps(params.get("arguments"), indent=2, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            arguments = repr(params.get("arguments"))
        is_prompt = tool == "prompt:update_prompt"
        # Prompt diffs and skill documents can exceed the ordinary small-tool
        # bound. Never truncate approval content; oversized requests are denied.
        limit = 2 * 1024 * 1024 if is_prompt else MAX_DIALOG_ARGS
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
                    library = PromptLibrary(home=role_path(self.cfg.role) / "prompts" if self.cfg.role else None,
                                extra_layers=bool(self.cfg.role))
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
        if self.busy:
            self._notice("执行中不能刷新上下文；先停止当前这一轮")
            return
        previous = self.cfg.role
        self._sync_config()
        self._load_role_list()
        if self.cfg.role != previous:
            self._release_conversation()
            self._clear_transcript()
        self._load_role_history()
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))

    def open_settings(self):
        if self._stopping:
            return
        if self.busy:
            self._notice("执行中不能修改设置；先停止当前这一轮")
            return
        self._sync_config()
        dialog = SettingsDialog(self, self.cfg, self._workspace_root(), str(self.config_path))
        if self._exec_dialog(dialog) != QDialog.DialogCode.Accepted or self._stopping:
            return
        before = (self.cfg.workspace, self.cfg.python, self.cfg.session_log)
        for name, value in dialog.values.items():
            setattr(self.cfg, name, value)
        self._sync_controls()
        saved = self._save()
        self._refresh_model_label()
        self._set_workspace_label(str(Path(self._workspace_root()).absolute()))
        if before != (self.cfg.workspace, self.cfg.python, self.cfg.session_log):
            self._restart_server()
        self._notice("设置已保存" if saved else "设置已应用，但配置文件写入失败（见日志）")

    def _save(self):
        self._sync_config()
        try:
            self.cfg.store(self.config_path)
        except OSError as exc:
            reason = f"设置保存失败（{self.config_path}）：{exc}"
            logger.error("%s", reason)
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
        if self.agent_available:
            flags.extend(("技能默认硬件", "工具免审批"))
        busy = "执行中…" if self.busy else "空闲"
        self.status_busy.setText(busy + ("（" + "、".join(flags) + "）" if flags else ""))
        card = getattr(self, "status_card", None)
        if card is not None:
            card.setText(f"服务：{self.serve_state}\n{agent}\n运行：{busy}")
        self.start_button.setEnabled(not self.busy and not self._stopping)
        self.stop_button.setEnabled(self.busy)
        self.abort_button.setEnabled(self.serve is not None)
        self.run_state.setText("运行中" if self.busy else "未启动")

    def _set_busy(self, busy):
        self.busy = busy
        self.start_button.setEnabled(not busy and not self._stopping)
        self.new_button.setEnabled(not busy)
        self.refresh_button.setEnabled(not busy)
        self.role_box.setEnabled(not busy)
        self.create_role_button.setEnabled(not busy)
        self.task_edit.setEnabled(not busy)
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
        self.generation += 1
        self._restart_pending = False
        self.pending_start = False
        self.serve = None
        self._start_timer.stop()
        self._notice_timer.stop()
        self._pump_timer.stop()
        self.speaker.shutdown()
        for dialog in tuple(self._dialogs):
            dialog.reject()
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
        splash.entered.connect(lambda: splash.fade_out(lambda: (_fade_in(window), window.maybe_model_setup())))
        splash.cancelled.connect(lambda: (window.shutdown(), loop.quit()))
        splash.show()
    else:
        window.show()
        window.maybe_model_setup()
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
