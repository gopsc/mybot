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
from PySide6.QtGui import QColor, QDesktopServices, QFontDatabase, QPixmap
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


class SafeTextBrowser(QTextBrowser):
    """Preview widget that never loads local/remote resources from Markdown."""

    def loadResource(self, _resource_type, _url):
        return None


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
            self.view = SafeTextBrowser()
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


class PromptPanel(QWidget):
    """Lazy operator editor. Only PromptLibrary may write prompt files.

    Contents live in widgets, never preferences, application logs or transcripts.
    A failed safety check must leave the repair controls available.
    """

    def __init__(self, parent=None, *, auto_stats=True, home=None, operator_path=None,
                 extra_layers=False):
        super().__init__(parent)
        self.library = None
        self.loaded = False
        self.home = home
        self.operator_path = operator_path
        self.extra_layers = extra_layers is True
        self.layer = None
        self.loaded_hash = None
        self._row = -1
        self._rows = []
        layout = QVBoxLayout(self)
        layout.addWidget(_label(
            "0 / 10 / 100 在 GUI 中只读；97（SOUL）/ 98（USER）/ 99（STATS）可编辑。\n"
            "角色目录里额外的 NNN_名称.md 层按编号排在 10 与 97 之间，对 Agent 只读。\n"
            "0 / 100 安全层必须保持默认校验值。保存层、补齐和恢复立即生效，设置取消不回滚。", secondary=True))
        self.auto_stats = QCheckBox("自动更新 STATS（仅统计数据，不记录 USER 内容）")
        self.auto_stats.setChecked(auto_stats)
        layout.addWidget(self.auto_stats)
        self.root_label = _label("切换到此页时加载提示词库", secondary=True)
        layout.addWidget(self.root_label)
        row = QHBoxLayout()
        self.refresh_button = _button("重新加载", self.reload)
        self.fill_button = _button("仅补齐缺失", self.fill_missing)
        self.restore_button = _button("恢复全部默认…", self.restore_all, role="danger")
        self.folder_button = _button("打开目录", self.open_folder)
        for button in (self.refresh_button, self.fill_button, self.restore_button, self.folder_button):
            row.addWidget(button)
        layout.addLayout(row)
        self.table = QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(["编号 / 文件名", "字节 / 上限", "已修改", "权限", "mtime", "状态"])
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.verticalHeader().setVisible(False)
        self.table.setMaximumHeight(205)
        self.table.itemSelectionChanged.connect(self._select)
        layout.addWidget(self.table)
        self.editor_label = _label("选择一个层")
        layout.addWidget(self.editor_label)
        self.editor = QPlainTextEdit()
        self.editor.setReadOnly(True)
        _mono(self.editor)
        layout.addWidget(self.editor, 1)
        save_row = QHBoxLayout()
        self.save_button = _button("保存当前层（备份）", self.save, role="primary")
        self.save_button.setEnabled(False)
        save_row.addWidget(self.save_button)
        self.edit_size = _label("", secondary=True)
        save_row.addWidget(self.edit_size)
        self.editor.textChanged.connect(self._edited)
        layout.addLayout(save_row)
        preview_row = QHBoxLayout()
        self.show_user = QCheckBox("显示 USER 私人内容（仅本次预览）")
        self.show_user.toggled.connect(self.refresh_preview)
        preview_row.addWidget(self.show_user)
        self.preview_size = _label("", secondary=True)
        preview_row.addWidget(self.preview_size, 1)
        layout.addLayout(preview_row)
        self.preview = QPlainTextEdit()
        self.preview.setReadOnly(True)
        self.preview.setUndoRedoEnabled(False)
        _mono(self.preview)
        layout.addWidget(self.preview, 1)
        layout.addWidget(_label("合成预览使用已保存的层及可选操作者指导；动态工程/工具上下文在发送时加入。", secondary=True))
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)
        self.backup_label = _label("", secondary=True)
        self.backup_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(self.backup_label)

    def _error(self, action, exc):
        text = (f"{action}失败：{exc}\n"
                "若 0 / 100 安全层被修改或缺失，发送将被阻止；可明确确认「恢复全部默认」修复。")
        self.status.setText(text)
        # Non-blocking so a failed initial load cannot trap Settings construction.
        message = QMessageBox(QMessageBox.Icon.Warning, "提示词库", text,
                              QMessageBox.StandardButton.Ok, self)
        message.setTextFormat(Qt.TextFormat.PlainText)
        message.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        message.open()

    def _get_library(self):
        if self.library is None:
            from ..prompts import PromptLibrary
            self.library = PromptLibrary(home=self.home, extra_layers=self.extra_layers)
        return self.library

    def ensure_loaded(self):
        if not self.loaded:
            self.reload()

    def _confirm(self, title, text):
        return QMessageBox.question(
            self, title, text, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes

    def _discard(self):
        return not self.editor.document().isModified() or self._confirm(
            "放弃未保存修改", "当前层尚未保存，放弃这些修改？")

    def reload(self):
        if not self._discard():
            return
        try:
            library = self._get_library()
            if not self.loaded:
                # Constructor is read-only; bootstrap only on explicit tab use.
                try:
                    library.ensure_home()
                finally:
                    self.loaded = True
            self.status.setText("已加载已保存的提示词层")
        except Exception as exc:
            self._error("加载", exc)
        self._refresh()

    def _refresh(self):
        if self.library is None:
            return
        selected = self.layer
        try:
            self._rows = self.library.list_layers()
        except Exception as exc:
            self._error("列出层", exc)
            return
        self.root_label.setText(str(self.library.home))
        self.table.blockSignals(True)
        self.table.setRowCount(len(self._rows))
        for row, layer in enumerate(self._rows):
            stamp = layer.get("mtime")
            if isinstance(stamp, (float, int)):
                stamp = datetime.fromtimestamp(stamp).astimezone().isoformat(timespec="seconds")
            values = (
                f"{layer['id']} · {layer['file']}", f"{layer['bytes']} / {layer['max_bytes']}",
                "是" if layer["modified"] else "否",
                "可编辑" if str(layer["id"]) in {"97", "98", "99"} else "只读（操作者维护）",
                str(stamp or "—"), "缺失" if layer["missing"] else "存在")
            for column, value in enumerate(values):
                item = QTableWidgetItem(value)
                item.setToolTip(value)
                self.table.setItem(row, column, item)
        self.table.blockSignals(False)
        self.editor.document().setModified(False)
        self._row = -1
        row = next((i for i, layer in enumerate(self._rows) if layer["id"] == selected), 0)
        self.table.selectRow(row)
        self._select()
        self.refresh_preview()

    def _select(self):
        row = self.table.currentRow()
        if row == self._row or not 0 <= row < len(self._rows):
            return
        if not self._discard():
            self.table.blockSignals(True)
            self.table.selectRow(self._row)
            self.table.blockSignals(False)
            return
        self._row = row
        metadata = self._rows[row]
        self.layer = metadata["id"]
        self.loaded_hash = None
        self.editor.clear()
        self.editor.setReadOnly(True)
        self.save_button.setEnabled(False)
        editable = str(self.layer) in {"97", "98", "99"}
        self.editor_label.setText(f"{metadata['file']} · " + ("可编辑" if editable else "只读"))
        try:
            data = self.library.read(self.layer)
            self.loaded_hash = data["sha256"]
            self.editor.setPlainText(data["content"])
            self.editor.setReadOnly(not editable)
            self.editor.document().setModified(False)
        except Exception as exc:
            self.status.setText(f"无法读取 {metadata['file']}：{exc}；可补齐缺失或恢复全部默认。")
        self._edited()

    def _edited(self):
        size = len(self.editor.toPlainText().encode("utf-8"))
        self.edit_size.setText(f"{size} 字节 · 保存时校验版本及大小")
        self.save_button.setEnabled(self.loaded_hash is not None and not self.editor.isReadOnly())

    def save(self):
        if self.loaded_hash is None or self.editor.isReadOnly():
            return False
        try:
            result = self.library.update(
                self.layer, self.editor.toPlainText(), actor="operator", reason="GUI prompt editor",
                expected_hash=self.loaded_hash)
        except Exception as exc:
            self._error("保存（可能已被外部修改，请重新加载后重试）", exc)
            return False
        self.editor.document().setModified(False)
        self._refresh()
        self.status.setText(f"已保存层 {self.layer}；下一轮生效")
        self._show_backup(result)
        return True

    def _show_backup(self, result):
        self.backup_label.setText(f"备份：{result.get('backup') or '无（没有覆盖已有文件）'}")

    def fill_missing(self):
        if not self._discard():
            return
        self._restore(missing_only=True)

    def restore_all(self):
        if not self._confirm(
                "恢复全部提示词", "将备份并覆盖全部六层（包括 USER 私人内容和操作者维护的层），"
                "并放弃未保存修改。此操作也可修复 0 / 100 安全层。\n确定恢复全部默认？"):
            return
        self._restore(missing_only=False)

    def _restore(self, *, missing_only):
        try:
            result = self._get_library().restore(missing_only=missing_only)
            self.loaded = True
        except Exception as exc:
            self._error("恢复", exc)
            return
        self.editor.document().setModified(False)
        self._refresh()
        self.status.setText("已仅补齐缺失层（已有内容保持不变）" if missing_only else "已恢复全部默认层")
        self._show_backup(result)

    def open_folder(self):
        try:
            root = self._get_library().home
            if not QDesktopServices.openUrl(QUrl.fromLocalFile(str(root))):
                raise OSError("系统未能打开目录")
        except Exception as exc:
            self._error("打开目录", exc)

    def refresh_preview(self):
        self.preview.clear()
        self.preview_size.clear()
        if self.library is None:
            return
        try:
            from ..agent_prompt import read_operator_prompt
            from ..prompts import MAX_PROMPT_TOTAL
            if any(layer["missing"] for layer in self.library.list_layers()):
                self.preview.setPlainText("预览不可用：有缺失层，请点击「仅补齐缺失」。")
                return
            operator = read_operator_prompt(self.operator_path() if self.operator_path else "")
            result = self.library.compose(operator=operator)
            text = result.text
            size = len(text.encode("utf-8"))
            if not self.show_user.isChecked():
                user = self.library.read("98")
                # Never expose a stale snapshot if USER changed between reads,
                # including a concurrent replacement with empty text.
                if user["sha256"] != result.layer_hashes["98"]:
                    text = "[USER 已隐藏；内容已变化，请重新加载预览]"
                else:
                    # Match the entire framed layer, not a short USER value that
                    # may also appear in unrelated layers. A future framing
                    # change fails closed rather than guessing at boundaries.
                    frame = f"\n--- PROMPT LAYER 98: {user['file']} ---\n"
                    framed = frame + user["content"]
                    text = (text.replace(framed, frame + "[USER 已隐藏]") if framed in text
                            else "[USER 已隐藏；无法安全分离私人层，请重新加载预览]")
            self.preview.setPlainText(text)
            self.preview_size.setText(f"实际合成：{size} / {MAX_PROMPT_TOTAL} 字节")
        except Exception as exc:
            self.preview.setPlainText("预览不可用；安全校验未通过时禁止发送。")
            self.status.setText(f"预览失败：{exc}；可通过恢复全部默认修复安全层。")


class ModelSetupDialog(QDialog):
    """First-run guided model setup.

    The wizard records the provider, model name, optional endpoint and the
    environment variable that holds the API key. The key VALUE never enters
    the window: it is read by the backend from the operator's environment, so
    there is no shared key and no hidden default.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("首次运行：配置模型")
        self.setModal(True)
        self.resize(580, 320)
        self.values = None
        from ..agent import PROVIDER_KEY_ENV, available_providers
        self._key_envs = PROVIDER_KEY_ENV
        layout = QVBoxLayout(self)
        intro = QLabel("选择模型提供商并填写模型名。密钥的值保存在你自己的环境变量中，"
                       "本窗口只记录变量名，从不读取、显示或存储密钥。\n"
                       "没有配置时智能体无法启动；也可以稍后在设置里完成。")
        intro.setWordWrap(True)
        intro.setObjectName("secondaryText")
        layout.addWidget(intro)
        form = QFormLayout()
        self.provider = QComboBox()
        self.provider.addItem(f"稍后再说（跳过向导）", "")
        for name in available_providers():
            self.provider.addItem(f"{name}  ·  密钥变量 {self._key_envs.get(name, '自定义')}", name)
        self.provider.currentIndexChanged.connect(self._provider_changed)
        form.addRow("提供商", self.provider)
        self.model_name = QLineEdit()
        self.model_name.setPlaceholderText("例如 gpt-4o / claude-sonnet-4-5 / deepseek-chat")
        self.model_name.textChanged.connect(self._refresh_preview)
        form.addRow("模型名", self.model_name)
        self.base_url = QLineEdit()
        self.base_url.setPlaceholderText("留空使用官方端点；自托管/OpenAI 兼容端点填 HTTPS 地址")
        form.addRow("端点 Base URL", self.base_url)
        self.key_env = QLineEdit()
        self.key_env.textChanged.connect(self._refresh_preview)
        form.addRow("API Key 环境变量名", self.key_env)
        layout.addLayout(form)
        self.preview = QLabel("")
        self.preview.setWordWrap(True)
        self.preview.setObjectName("secondaryText")
        layout.addWidget(self.preview)
        layout.addStretch(1)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        self.skip_button = QPushButton("跳过")
        self.skip_button.clicked.connect(self._skip)
        buttons.addWidget(self.skip_button)
        self.save_button = QPushButton("保存并使用")
        self.save_button.setProperty("role", "primary")
        self.save_button.setDefault(True)
        self.save_button.clicked.connect(self._save)
        buttons.addWidget(self.save_button)
        layout.addLayout(buttons)
        self._provider_changed()

    def _provider_changed(self, *_):
        name = self.provider.currentData()
        self.key_env.setText(self._key_envs.get(name, ""))
        configured = bool(name)
        for widget in (self.model_name, self.base_url, self.key_env):
            widget.setEnabled(configured)
        self._refresh_preview()

    def _refresh_preview(self, *_):
        name = self.provider.currentData()
        if not name:
            self.preview.setText("跳过：不保存任何模型设置；可在 设置 → 模型与预算 中手动填写。")
            return
        model = f"{name}:{self.model_name.text().strip()}" if self.model_name.text().strip() else "—"
        endpoint = self.base_url.text().strip() or "官方默认端点"
        self.preview.setText(f"将配置：{model} · {endpoint} · 密钥读取环境变量 {self.key_env.text().strip() or '—'}")

    def _skip(self):
        self.values = {}
        self.reject()

    def _save(self):
        name = self.provider.currentData()
        if not name:
            self._skip()
            return
        model = self.model_name.text().strip()
        if not model:
            QMessageBox.warning(self, "缺少模型名", "请填写模型名，或选择“跳过”。")
            return
        base_url = self.base_url.text().strip()
        if base_url and not base_url.startswith(("http://", "https://")):
            QMessageBox.warning(self, "端点无效", "Base URL 需要以 http:// 或 https:// 开头。")
            return
        key_env = self.key_env.text().strip()
        if not key_env.isidentifier():
            QMessageBox.warning(self, "密钥变量无效",
                                "API Key 环境变量名必须是合法的变量名（字母、数字、下划线）。")
            return
        self.values = {"model": f"{name}:{model}", "base_url": base_url, "api_key_env": key_env}
        self.accept()


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

    def __init__(self, parent, *, python, cwd, robot="", module_paths=(),
                 scripts_dir="", timeout=180, runner=None, confirm=None):
        super().__init__(parent)
        apply_theme(self)
        self.setWindowTitle("命令面板")
        self.setModal(True)
        self.resize(900, 720)
        self.python = python
        self.cwd = cwd
        self.module_paths = tuple(module_paths)
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
        self.timeout.setEnabled(command in {"run", "sample"})
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
        self.status.setText(f"{self._count} 个文件 · {self.root}")
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
            item.setHidden(bool(needle) and not visible and bool(item.childCount()))
            return visible
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
            self.markdown.setPlainText(text)
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
        self.markdown = SafeTextBrowser()
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
