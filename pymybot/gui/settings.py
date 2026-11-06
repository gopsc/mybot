"""Operator settings and tool-approval dialogs.

Extracted from the window module: these two dialogs carry every agent/backend
switch and the per-call approval gate, so they own their own module instead of
inflating ``app.py``.
"""
from __future__ import annotations

from PySide6.QtGui import QFontDatabase
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QMessageBox,
    QHBoxLayout, QLineEdit, QPlainTextEdit, QTabWidget,
    QVBoxLayout, QWidget,
)

from ..roles import role_path
from .config import GuiConfig, absolute_path
from .prompts_panel import PromptPanel
from .theme import apply_theme as _apply_theme
from .widgets import button as _button, label as _label, spin as _spin

INTENT_CHOICES = (("auto", "自动（推荐）"), ("off", "关闭"), ("chat", "闲聊（只读）"),
                  ("inspect", "查看（只读）"), ("control", "控制（硬件动作）"),
                  ("author", "编写（文件）"), ("diagnose", "诊断（含 Shell）"))
SANDBOX_CHOICES = (("auto", "自动（bubblewrap 可用时）"), ("off", "关闭（仅工作区牢笼）"),
                   ("bwrap", "强制 bubblewrap"))


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
        self.field_buttons = {}
        self._workspace = workspace
        self._role = cfg.role
        layout = QVBoxLayout(self)
        self.tabs = tabs = QTabWidget()
        layout.addWidget(tabs, 1)

        general = QWidget()
        general_form = QFormLayout(general)
        self._field(general_form, cfg, "workspace", "工作区", browse=True)
        self._field(general_form, cfg, "python", "Python 解释器")
        self._field(general_form, cfg, "skills_dir", "技能目录", browse=True)
        tabs.addTab(general, "通用")

        model = QWidget()
        model_form = QFormLayout(model)
        self._field(model_form, cfg, "model", "模型（provider:model）")
        self._field(model_form, cfg, "base_url", "端点 Base URL")
        self._field(model_form, cfg, "api_key_env", "API Key 环境变量名")
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
        for label, widget in (("历史上限（KiB）", self.history_bytes),
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
        self.max_requests = _spin(cfg.max_requests, 10_000)
        self.max_tool_calls = _spin(cfg.max_tool_calls, 100_000)
        self.turn_timeout = _spin(int(cfg.turn_timeout) if cfg.turn_timeout else 1, 86400)
        self.turn_timeout.setMinimum(0)
        self.turn_timeout.setValue(int(cfg.turn_timeout or 0))
        self.model_retries = _spin(cfg.model_retries, 10)
        self.model_retries.setMinimum(0)
        self.fallback_models = QLineEdit(",".join(cfg.fallback_models))
        self.require_plan_approval = QCheckBox("自主任务逐次计划审批")
        self.require_plan_approval.setChecked(bool(cfg.require_plan_approval))
        for label, widget in (("单轮请求上限", self.max_requests),
                              ("单轮工具上限", self.max_tool_calls),
                              ("单轮墙钟（秒，0 关闭）", self.turn_timeout),
                              ("模型重试", self.model_retries),
                              ("备用模型（逗号分隔）", self.fallback_models)):
            model_form.addRow(label, widget)
        model_form.addRow(self.require_plan_approval)
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
        self.protect_prompts = QCheckBox("保护提示词目录（关闭沙箱时需取消勾选）")
        self.protect_prompts.setChecked(bool(cfg.protect_prompts))
        model_form.addRow(self.protect_prompts)
        self.session_log = QCheckBox("保存会话转录（~/.mybot/sessions）")
        self.session_log.setChecked(bool(cfg.session_log))
        model_form.addRow(self.session_log)
        model_form.addRow(_label("密钥只读取环境变量，窗口不保存也不显示它。", secondary=True))
        tabs.addTab(model, "模型与预算")

        advanced = QWidget()
        advanced_form = QFormLayout(advanced)
        self._field(advanced_form, cfg, "mcp_config", "MCP 配置（mcpServers JSON）", browse_file=True)
        self._field(advanced_form, cfg, "prompt_file", "可选操作者指导文件（OPERATOR，≤8 KiB）",
                    browse_file=True, caption="选择操作者指导文件",
                    file_filter="Markdown/文本 (*.md *.txt);;所有文件 (*)")
        self._field(advanced_form, cfg, "search_endpoint", "SearXNG 搜索端点（留空仅抓取）")
        advanced_form.addRow(_label(f"配置文件：{config_path or '（默认位置）'}", secondary=True))
        tabs.addTab(advanced, "高级 / MCP")
        self._bind_role_paths()

        self.prompts = PromptPanel(
            self, auto_stats=cfg.auto_stats,
            home=role_path(cfg.role) / "prompts" if cfg.role else None,
            extra_layers=bool(cfg.role),
            operator_path=lambda: absolute_path(self.entries["prompt_file"].text(),
                                            self.entries["workspace"].text() or self._workspace))
        tabs.addTab(self.prompts, "提示词")
        tabs.currentChanged.connect(
            lambda _index: self.prompts.ensure_loaded() if tabs.currentWidget() is self.prompts else None)

        layout.addWidget(_label("工具默认开启并免审批；提示词更新和宿主抓图仍逐次确认。", secondary=True))
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setText("保存")
        self.buttons.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        self.buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        self.buttons.accepted.connect(self._save)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)

    def _field(self, form, cfg, name, label, *, browse=False, browse_file=False,
               caption="选择 MCP 配置", file_filter="JSON (*.json)"):
        value = getattr(cfg, name)
        widget = QLineEdit(",".join(value) if isinstance(value, list) else str(value or ""))
        self.entries[name] = widget
        if browse:
            row = QHBoxLayout()
            row.addWidget(widget)
            button = _button("…", lambda checked=False, w=widget: self._browse(w))
            self.field_buttons[name] = button
            row.addWidget(button)
            form.addRow(label, row)
        elif browse_file:
            row = QHBoxLayout()
            row.addWidget(widget)
            button = _button("…", lambda checked=False, w=widget: self._browse_file(
                w, caption, file_filter))
            self.field_buttons[name] = button
            row.addWidget(button)
            form.addRow(label, row)
        else:
            form.addRow(label, widget)

    def _bind_role_paths(self):
        """Show role-owned paths read-only; the backend ignores global overrides."""
        if not self._role:
            return
        root = role_path(self._role)
        values = {"workspace": root / "workspace", "skills_dir": root / "skills",
                  "mcp_config": root / "mcp.json"}
        for name, path in values.items():
            entry = self.entries[name]
            entry.setText(str(path))
            entry.setToolTip(str(path))
            entry.setEnabled(False)
            button = self.field_buttons.get(name)
            if button is not None:
                button.setEnabled(False)

    def _browse(self, widget):
        chosen = QFileDialog.getExistingDirectory(self, "选择目录", self._workspace)
        if chosen:
            widget.setText(chosen)

    def _browse_file(self, widget, caption="选择 MCP 配置", file_filter="JSON (*.json)"):
        chosen, _ = QFileDialog.getOpenFileName(self, caption, self._workspace, file_filter)
        if chosen:
            widget.setText(chosen)

    def _save(self):
        if self.prompts.editor.document().isModified() and not self.prompts.save():
            return
        values = {}
        for name, widget in self.entries.items():
            if self._role and name in {"workspace", "skills_dir", "mcp_config"}:
                continue
            values[name] = widget.text().strip()
        values.update(max_history_bytes=max(64, self.history_bytes.value()) * 1024,
                      max_context_tokens=(self.max_context_tokens.value()
                                          if self.max_context_enabled.isChecked() else None),
                      context_reserve_tokens=self.context_reserve_tokens.value(),
                      context_bytes=(max(1, self.context_kib.value()) * 1024
                                     if self.context_enabled.isChecked() else 0),
                      intent_mode=self.intent_box.currentData(),
                      sandbox_mode=self.sandbox_box.currentData(),
                      protect_prompts=self.protect_prompts.isChecked(),
                      session_log=self.session_log.isChecked(),
                      max_requests=self.max_requests.value(),
                      max_tool_calls=self.max_tool_calls.value(),
                      turn_timeout=float(self.turn_timeout.value()),
                      model_retries=self.model_retries.value(),
                      fallback_models=[item.strip() for item in
                                       self.fallback_models.text().split(",") if item.strip()],
                      require_plan_approval=self.require_plan_approval.isChecked(),
                      auto_stats=self.prompts.auto_stats.isChecked())
        self.values = values
        self.accept()

    def _message(self, title, text):
        QMessageBox.warning(self, title, text)


