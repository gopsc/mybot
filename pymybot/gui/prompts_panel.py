"""Operator prompt editor for the settings dialog.

Prompt files are written only by PromptLibrary; widget contents never enter
preferences, logs or transcripts. Loaded lazily when the settings tab is first
opened, so constructing the window never touches the prompt home.
"""
from __future__ import annotations

from datetime import datetime

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QCheckBox, QHeaderView, QHBoxLayout, QMessageBox,
                               QPlainTextEdit, QTableWidget, QTableWidgetItem,
                               QVBoxLayout, QWidget)

from .widgets import button as _button, label as _label, mono as _mono


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
