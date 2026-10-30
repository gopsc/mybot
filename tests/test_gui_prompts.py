"""Native prompt controls backed by a real, isolated PromptLibrary.

No model calls, screenshots or operator-home writes. Only confirmation choices
and the desktop folder opener are mocked; editing, CAS, backups and widgets are
real. The send guard uses the real stdio server and checks no request was sent.
"""
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

pytest.importorskip("PySide6")
from PySide6.QtCore import QPoint, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QCheckBox, QDialog, QDialogButtonBox, QLabel, QMessageBox

from pymybot.gui.app import App, SettingsDialog, ToolDialog
from pymybot.gui.config import GuiConfig, merge_args
from pymybot.gui.dialogs import PromptPanel
from pymybot.gui.protocol import ServeClient
from pymybot.prompts import MAX_PROMPT_TOTAL, PromptLibrary

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    os.environ["QT_QPA_PLATFORM"] = "offscreen"
    application = QApplication.instance() or QApplication([])
    application.setQuitOnLastWindowClosed(False)
    yield application


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path / "operator"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")


@pytest.fixture
def library():
    result = PromptLibrary()
    result.ensure_home()
    return result


@pytest.fixture
def widgets(qapp):
    opened = []

    def show(widget):
        opened.append(widget)
        widget.resize(900, 900)
        widget.show()
        qapp.processEvents()
        return widget

    yield show
    for widget in reversed(opened):
        for message in widget.findChildren(QMessageBox):
            message.reject()
        if isinstance(widget, App):
            widget.shutdown()
            widget.wait_for_shutdown()
        widget.close()
        widget.deleteLater()
    qapp.processEvents()


@pytest.fixture
def panel(widgets):
    widget = widgets(PromptPanel())
    widget.ensure_loaded()
    return widget


@pytest.fixture
def window(widgets, tmp_path):
    # Empty workspace: constructor has no hardware process or chosen robot.
    app = App(GuiConfig(workspace=str(tmp_path)), tmp_path / "settings.json")
    app._start_timer.stop()
    return widgets(app)


def click(button):
    pos = QPoint(10, button.height() // 2) if isinstance(button, QCheckBox) else button.rect().center()
    QTest.mouseClick(button, Qt.MouseButton.LeftButton, pos=pos)
    QApplication.processEvents()


def select(panel, layer):
    row = next(i for i, item in enumerate(panel._rows) if str(item["id"]) == str(layer))
    item = panel.table.item(row, 0)
    panel.table.scrollToItem(item)
    QTest.mouseClick(panel.table.viewport(), Qt.MouseButton.LeftButton,
                     pos=panel.table.visualItemRect(item).center())
    QApplication.processEvents()
    assert str(panel.layer) == str(layer)


def replace_text(editor, text):
    editor.setFocus()
    QTest.keyClick(editor, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(editor, text)


def close_warning(widget):
    warnings = [item for item in widget.findChildren(QMessageBox) if item.isVisible()]
    assert warnings
    text = warnings[-1].text()
    click(warnings[-1].button(QMessageBox.StandardButton.Ok))
    return text


def layer_path(library, layer):
    metadata = next(item for item in library.list_layers() if str(item["id"]) == str(layer))
    return library.home / metadata["file"]


def test_settings_lazy_load_and_stats_payload_roundtrip(widgets, window, tmp_path):
    settings = widgets(SettingsDialog(window, window.cfg, str(tmp_path)))
    assert settings.prompts.library is None
    assert not (Path(os.environ["MYBOT_HOME"]) / "prompts").exists()
    assert settings.prompts.auto_stats.isChecked()
    index = settings.tabs.indexOf(settings.prompts)
    QTest.mouseClick(settings.tabs.tabBar(), Qt.MouseButton.LeftButton,
                     pos=settings.tabs.tabBar().tabRect(index).center())
    assert settings.prompts.table.rowCount() == 6
    click(settings.prompts.auto_stats)
    click(settings.buttons.button(QDialogButtonBox.StandardButton.Save))
    assert settings.result() == QDialog.DialogCode.Accepted
    assert settings.values["auto_stats"] is False
    for key, value in settings.values.items():
        setattr(window.cfg, key, value)
    window.cfg.store(tmp_path / "saved.json")
    assert GuiConfig.load(tmp_path / "saved.json").auto_stats is False
    params = json.loads(json.dumps(window._agent_params("hello")))
    assert params["autoStats"] is False
    window.cfg.auto_stats = True
    assert window._agent_params("hello")["autoStats"] is True
    assert not any("USER 层" in label.text() for label in settings.findChildren(QLabel))


@pytest.mark.parametrize("value", [True, False, None, 0, 1, "false", [], {}])
def test_stats_config_sanitization_and_cli(tmp_path, value):
    path = tmp_path / "stats.json"
    GuiConfig(auto_stats=value).store(path)
    expected = value if isinstance(value, bool) else True
    assert GuiConfig.load(path).auto_stats is expected
    assert json.loads(path.read_text(encoding="utf-8"))["auto_stats"] is expected
    assert merge_args(GuiConfig(auto_stats=False), SimpleNamespace(no_prompt_stats=False)).auto_stats is False
    assert merge_args(GuiConfig(), SimpleNamespace(no_prompt_stats=True)).auto_stats is False
    path.write_text("{}", encoding="utf-8")
    assert GuiConfig.load(path).auto_stats is True


def test_prompt_edit_save_backup_next_load(panel, widgets):
    select(panel, "97")
    before = panel.loaded_hash
    replace_text(panel.editor, "New operator learning")
    click(panel.save_button)
    saved = panel.library.read("97")
    assert saved["content"] == "New operator learning"
    assert saved["sha256"] != before
    assert "备份：" in panel.backup_label.text()
    backup = Path(panel.backup_label.text().removeprefix("备份："))
    assert backup.exists()
    next_panel = widgets(PromptPanel())
    next_panel.ensure_loaded()
    select(next_panel, "97")
    assert next_panel.editor.toPlainText() == saved["content"]
    assert next_panel.loaded_hash == saved["sha256"]
    assert next_panel.table.item(2, 2).text() == "是"
    assert next_panel.table.item(2, 4).text() not in {"", "—"}


@pytest.mark.parametrize("layer", ["0", "10", "100"])
def test_operator_owned_layers_are_gui_readonly(panel, layer):
    select(panel, layer)
    before = panel.editor.toPlainText()
    assert panel.editor.isReadOnly()
    assert not panel.save_button.isEnabled()
    QTest.keyClicks(panel.editor, "DO NOT WRITE")
    assert panel.editor.toPlainText() == before
    assert panel.library.read(layer)["content"] == before


@pytest.mark.parametrize("layer", ["97", "98", "99"])
def test_editable_layers_use_library(panel, layer):
    select(panel, layer)
    assert not panel.editor.isReadOnly()
    replace_text(panel.editor, "operator update " + layer)
    click(panel.save_button)
    assert panel.library.read(layer)["content"] == "operator update " + layer


def test_save_conflict_keeps_external_change_and_draft(panel):
    select(panel, "97")
    loaded_hash = panel.loaded_hash
    replace_text(panel.editor, "GUI draft")
    panel.library.update("97", "external update", expected_hash=loaded_hash)
    click(panel.save_button)
    assert "重新加载" in close_warning(panel)
    assert panel.library.read("97")["content"] == "external update"
    assert panel.editor.toPlainText() == "GUI draft"
    assert panel.loaded_hash == loaded_hash


def test_missing_only_refill_preserves_modified_files(panel):
    panel.library.update("97", "keep my learning")
    missing = layer_path(panel.library, "98")
    missing.unlink()
    click(panel.refresh_button)
    row = next(i for i, item in enumerate(panel._rows) if str(item["id"]) == "98")
    assert panel.table.item(row, 5).text() == "缺失"
    assert not missing.exists(), "preview must not silently refill deleted layers"
    click(panel.fill_button)
    assert missing.exists()
    assert panel.library.read("97")["content"] == "keep my learning"
    assert "仅补齐" in panel.status.text()


def test_cancel_restore_all_is_noop(panel, monkeypatch):
    panel.library.update("98", "private operator preference")
    before = panel.library.read("98")
    choices = []

    def no(_parent, title, text, buttons, default):
        choices.append((title, text, default))
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", no)
    click(panel.restore_button)
    assert panel.library.read("98") == before
    assert choices and "全部六层" in choices[0][1]
    assert choices[0][2] == QMessageBox.StandardButton.No


def test_confirm_restore_all_displays_real_backup(panel, monkeypatch):
    panel.library.update("98", "private preference to backup")
    monkeypatch.setattr(QMessageBox, "question", lambda *a: QMessageBox.StandardButton.Yes)
    click(panel.restore_button)
    assert panel.library.read("98")["content"] != "private preference to backup"
    backup = Path(panel.backup_label.text().removeprefix("备份："))
    assert backup.is_dir()
    assert any(path.is_file() and b"private preference to backup" in path.read_bytes()
               for path in backup.rglob("*"))
    assert "已恢复全部" in panel.status.text()


@pytest.mark.parametrize("layer", ["0", "100"])
def test_tampered_safety_still_lists_and_can_be_repaired(panel, monkeypatch, layer):
    path = layer_path(panel.library, layer)
    path.write_text("tampered safety", encoding="utf-8")
    click(panel.refresh_button)
    assert panel.table.rowCount() == 6
    assert "预览不可用" in panel.preview.toPlainText()
    select(panel, layer)
    assert panel.editor.isReadOnly() and not panel.save_button.isEnabled()
    assert panel.editor.toPlainText() == ""
    assert panel.restore_button.isEnabled()
    monkeypatch.setattr(QMessageBox, "question", lambda *a: QMessageBox.StandardButton.Yes)
    click(panel.restore_button)
    assert panel.library.read(layer)["content"] != "tampered safety"
    assert panel.library.compose().text
    assert "预览不可用" not in panel.preview.toPlainText()
    assert Path(panel.backup_label.text().removeprefix("备份：")).exists()


def test_initial_tampering_does_not_crash_settings(library, widgets, tmp_path):
    layer_path(library, "0").write_text("broken", encoding="utf-8")
    settings = widgets(SettingsDialog(None, GuiConfig(), str(tmp_path)))
    assert settings.prompts.library is None
    settings.tabs.setCurrentWidget(settings.prompts)
    assert settings.prompts.table.rowCount() == 6
    assert settings.prompts.restore_button.isEnabled()
    assert "预览失败" in settings.prompts.status.text()
    for message in settings.findChildren(QMessageBox):
        click(message.button(QMessageBox.StandardButton.Ok))


def test_unavailable_prompt_home_is_panel_error_not_constructor_crash(widgets, tmp_path, monkeypatch):
    invalid = tmp_path / "file-not-directory"
    invalid.write_text("not a directory", encoding="utf-8")
    monkeypatch.setenv("MYBOT_HOME", str(invalid))
    settings = widgets(SettingsDialog(None, GuiConfig(), str(tmp_path)))
    assert settings.prompts.library is None
    settings.tabs.setCurrentWidget(settings.prompts)
    assert "失败" in settings.prompts.status.text()
    assert settings.prompts.restore_button.isEnabled()
    close_warning(settings)


def test_combined_preview_redacts_user_by_default_and_shows_true_size(library, widgets, tmp_path):
    secret = "PRIVATE-USER-PREFERENCE-unique"
    library.update("98", secret)
    panel = widgets(PromptPanel())
    panel.ensure_loaded()
    assert not panel.show_user.isChecked()
    assert panel.preview.isReadOnly()
    assert secret not in panel.preview.toPlainText()
    assert secret not in panel.editor.toPlainText()
    assert "USER 已隐藏" in panel.preview.toPlainText()
    assert str(len(library.compose().text.encode("utf-8"))) in panel.preview_size.text()
    assert str(MAX_PROMPT_TOTAL) in panel.preview_size.text()
    click(panel.show_user)
    assert secret in panel.preview.toPlainText()
    click(panel.show_user)
    assert secret not in panel.preview.toPlainText()
    assert not panel.preview.document().isUndoAvailable()
    cfg = GuiConfig(auto_stats=panel.auto_stats.isChecked())
    cfg.store(tmp_path / "prefs.json")
    assert secret not in (tmp_path / "prefs.json").read_text(encoding="utf-8")
    assert secret not in panel.status.text()
    assert secret not in panel.backup_label.text()


def test_short_user_redaction_does_not_damage_other_layers(library, widgets):
    library.update("98", "a")
    panel = widgets(PromptPanel())
    panel.ensure_loaded()
    assert library.read("10")["content"] in panel.preview.toPlainText()
    assert "[USER 已隐藏]" in panel.preview.toPlainText()


def test_settings_save_also_saves_unsaved_layer(widgets, tmp_path):
    settings = widgets(SettingsDialog(None, GuiConfig(), str(tmp_path)))
    settings.tabs.setCurrentWidget(settings.prompts)
    select(settings.prompts, "97")
    replace_text(settings.prompts.editor, "Saved through outer settings button")
    click(settings.buttons.button(QDialogButtonBox.StandardButton.Save))
    assert settings.result() == QDialog.DialogCode.Accepted
    assert settings.prompts.library.read("97")["content"] == "Saved through outer settings button"
    assert "content" not in settings.values


def test_oversize_unicode_save_rejected_without_changing_disk(panel):
    select(panel, "99")
    before = panel.library.read("99")
    cap = next(row["max_bytes"] for row in panel._rows if row["id"] == "99")
    panel.editor.setPlainText("私" * cap)
    assert str(3 * cap) in panel.edit_size.text()
    click(panel.save_button)
    close_warning(panel)
    assert panel.library.read("99") == before
    assert panel.editor.toPlainText() == "私" * cap


def test_open_prompt_folder_uses_library_root(panel, monkeypatch):
    from PySide6.QtGui import QDesktopServices
    opened = []
    monkeypatch.setattr(QDesktopServices, "openUrl", lambda url: opened.append(url.toLocalFile()) or True)
    click(panel.folder_button)
    assert opened == [str(panel.library.home)]


@pytest.mark.parametrize("layer", ["0", "100"])
def test_send_guard_blocks_tampered_safety_before_rpc(window, library, layer):
    client = ServeClient(sys.executable, ROOT)
    try:
        info = client.request("initialize", timeout=30)
        assert info["protocol"] == 1
        window.serve = client
        window.agent_available = True
        window.cfg.robot = str(ROOT / "robots" / "relay-test.sql")
        layer_path(library, layer).write_text("modified safety", encoding="utf-8")
        window.task_box.setPlainText("do not contact a model")
        sequence = client._seq
        failures = []

        def dismiss():
            dialog = QApplication.activeModalWidget()
            try:
                assert isinstance(dialog, QMessageBox)
                assert "发送已阻止" in dialog.windowTitle()
                assert "0 / 100" in dialog.text() and "设置 → 提示词" in dialog.text()
                click(dialog.button(QMessageBox.StandardButton.Ok))
            except Exception as exc:
                failures.append(exc)
                if dialog:
                    dialog.reject()

        QTimer.singleShot(0, dismiss)
        click(window.send_button)
        assert not failures
        assert client._seq == sequence
        assert window.task_box.toPlainText() == "do not contact a model"
        assert not window.busy
    finally:
        window.serve = None
        client.stop(grace=5)


@pytest.mark.parametrize("approve", [True, False])
def test_prompt_approval_shows_complete_diff_without_retaining_content(window, approve):
    secret = "PRIVATE-USER-DIFF"
    diff = "--- old\n+++ new\n" + "-before\n+after\n" * 600 + "+" + secret + "\n"
    failures = []

    def decide():
        dialog = QApplication.activeModalWidget()
        try:
            assert isinstance(dialog, ToolDialog)
            assert "持久修改提示词" in dialog.warning.text()
            assert dialog.diff.isReadOnly()
            assert dialog.diff.toPlainText() == diff
            assert dialog.deny_button.isDefault()
            click(dialog.approve_button if approve else dialog.deny_button)
        except Exception as exc:
            failures.append(exc)
            if dialog:
                dialog.reject()

    QTimer.singleShot(0, decide)
    assert window._ask_tool({"tool": "prompt:update_prompt",
                             "arguments": {"layer": "98", "diff": diff}}) is approve
    assert not failures
    window.turn_id = 42
    window._on_agent_event({"id": 42, "event": {"type": "tool_call", "tool": "update_prompt",
                                                "arguments": {"content": secret}}})
    assert secret not in window.chat.toPlainText()
    assert secret not in window.log.toPlainText()
    assert "before" not in window.chat.toPlainText()


def test_prompt_version_events_and_responses_update_status(window, qapp):
    window.turn_id = 42
    digest = "a123456789abcdef" * 4
    window.post(lambda: window._on_notify(window.generation, "agent.event", {
        "id": 42, "event": {"type": "prompt_version", "hash": digest[:16]}}))
    QTest.qWait(60)
    assert digest[:16] in window.status_prompt.text()
    window._on_agent_event({"id": 999, "event": {"type": "prompt_version", "hash": "b" * 16}})
    assert digest[:16] in window.status_prompt.text()
    window._turn_done(window.generation, 42, {"prompt_version": {"hash": "c" * 64, "layers": {}}}, None)
    assert window.status_prompt.text() == "提示词：" + "c" * 16
    assert "c" * 64 not in window.chat.toPlainText()
