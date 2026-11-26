"""Action-script editor with line numbers, highlighting and controller runs."""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile

from PySide6.QtCore import QRect, QSize, Qt, QRunnable, QThreadPool, Signal
from PySide6.QtGui import (QColor, QFontDatabase, QFontMetricsF, QKeySequence, QPainter,
                           QShortcut, QTextFormat)
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QHBoxLayout, QLabel, QMessageBox,
    QPlainTextEdit, QProgressBar, QPushButton, QSplitter, QTextEdit, QVBoxLayout, QWidget,
)

from ..security import SecurityError, checked_text, read_file
from .highlight import CodeHighlighter
from .protocol import CliCall, cli_args

MAX_EDITOR_BYTES = 1024 * 1024
MAX_SCRIPT_FILES = 1000


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


def _mono(widget):
    widget.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))


class LineNumberArea(QWidget):
    def __init__(self, editor):
        super().__init__(editor)
        self.editor = editor

    def sizeHint(self):
        return QSize(self.editor.line_number_area_width(), 0)

    def paintEvent(self, event):
        self.editor.line_number_area_paint_event(event)


class CodeEditor(QPlainTextEdit):
    """Plain-text editor with a line-number gutter and current-line highlight."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.gutter = LineNumberArea(self)
        self.blockCountChanged.connect(self._update_margin)
        self.updateRequest.connect(self._update_gutter)
        self.cursorPositionChanged.connect(self._highlight_current_line)
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        _mono(self)
        self.setTabStopDistance(QFontMetricsF(self.font()).horizontalAdvance(" ") * 4)
        self._update_margin()
        self._highlight_current_line()

    def line_number_area_width(self):
        digits = max(2, len(str(max(1, self.blockCount()))))
        return 10 + self.fontMetrics().horizontalAdvance("9") * digits

    def _update_margin(self, *_args):
        self.setViewportMargins(self.line_number_area_width(), 0, 0, 0)

    def _update_gutter(self, rect, dy):
        if dy:
            self.gutter.scroll(0, dy)
        else:
            self.gutter.update(0, rect.y(), self.gutter.width(), rect.height())
        if rect.contains(self.viewport().rect()):
            self._update_margin()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        contents = self.contentsRect()
        self.gutter.setGeometry(QRect(contents.left(), contents.top(),
                                      self.line_number_area_width(), contents.height()))

    def _highlight_current_line(self):
        selection = QTextEdit.ExtraSelection()
        selection.format.setBackground(QColor("#f3f7fd"))
        selection.format.setProperty(QTextFormat.Property.FullWidthSelection, True)
        selection.cursor = self.textCursor()
        selection.cursor.clearSelection()
        self.setExtraSelections([selection])

    def line_number_area_paint_event(self, event):
        painter = QPainter(self.gutter)
        painter.fillRect(event.rect(), QColor("#f1f5f9"))
        block = self.firstVisibleBlock()
        number = block.blockNumber()
        offset = self.contentOffset()
        top = self.blockBoundingGeometry(block).translated(offset).top()
        bottom = top + self.blockBoundingRect(block).height()
        painter.setPen(QColor("#64748b"))
        while block.isValid() and top <= event.rect().bottom():
            if block.isVisible() and bottom >= event.rect().top():
                painter.drawText(0, int(top), self.gutter.width() - 8, self.fontMetrics().height(),
                                 Qt.AlignmentFlag.AlignRight, str(number + 1))
            block = block.next()
            top = bottom
            bottom = top + self.blockBoundingRect(block).height()
            number += 1


class _EditorTask(QRunnable):
    """Run one controller command off the GUI thread."""

    def __init__(self, panel, argv):
        super().__init__()
        self.panel = panel
        self.argv = argv

    def run(self):
        try:
            result = self.panel.runner(self.argv, self.panel.cwd)
        except Exception as exc:
            result = {"code": None, "error": f"{type(exc).__name__}: {exc}"}
        try:
            self.panel.completed.emit(result)
        except RuntimeError:  # the panel was closed while the child ran
            pass


class ScriptEditorPanel(QWidget):
    """Edit action scripts, structure SQL and run them through the same CLI child.

    The panel never re-implements robot logic: argv comes from ``cli_args`` and
    execution is a short-lived ``python -m pymybot`` process. The GUI's long-lived
    ``serve`` child stays owned by the agent, so editing and running scripts does
    not depend on, or interfere with, an agent conversation.
    """

    completed = Signal(object)
    dirty_changed = Signal(bool)

    def __init__(self, parent=None, *, python=None, cwd=".", robot="", scripts_root="",
                 robots_root="", module_paths=(), camera_src_dir="", timeout=180.0,
                 runner=None, confirm=None, reader=None, writer=None):
        super().__init__(parent)
        self.python = python or sys.executable
        self.cwd = str(cwd or ".")
        self.robot = str(robot or "")
        self.scripts_root = Path(scripts_root).absolute() if str(scripts_root or "").strip() else None
        self.robots_root = Path(robots_root).absolute() if str(robots_root or "").strip() else None
        self.module_paths = tuple(str(path) for path in module_paths if str(path).strip())
        self.camera_src_dir = str(camera_src_dir or "")
        self.current_path: str | None = None
        self.saved_text = ""
        self._dirty = False
        self._loading = False
        self._running = False
        self._call: CliCall | None = None
        self.runner = runner or self._run_cli
        self.confirm = confirm or self._confirm
        self.reader = reader or (lambda path: read_file(path, cap=MAX_EDITOR_BYTES))
        self.writer = writer or self._write_text
        self.completed.connect(self._done)
        self._build(timeout)
        self.refresh_files()
        self._sync_robot_label()

    # -- construction ------------------------------------------------------
    def _build(self, timeout):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)
        files = QHBoxLayout()
        files.addWidget(_label("文件"))
        self.files = QComboBox()
        self.files.setMinimumWidth(220)
        self.files.activated.connect(self._file_selected)
        files.addWidget(self.files, 1)
        files.addWidget(_button("刷新", self.refresh_files))
        files.addWidget(_button("打开…", self.open_dialog))
        files.addWidget(_button("新建", self.new_file))
        layout.addLayout(files)

        target = QHBoxLayout()
        self.robot_label = _label("", secondary=True)
        self.robot_label.setWordWrap(False)
        self.robot_label.setMinimumWidth(160)
        target.addWidget(self.robot_label, 1)
        target.addWidget(_label("运行脚本"))
        self.run_script = QComboBox()
        self.run_script.setMinimumWidth(200)
        self.run_script.setToolTip("编辑结构 SQL 时选择一个动作脚本对它运行；编辑 .mt 时固定为当前文件")
        target.addWidget(self.run_script, 1)
        layout.addLayout(target)

        controls = QHBoxLayout()
        self.hardware = QCheckBox("允许硬件")
        self.hardware.setToolTip("运行会激活机器人并可能写硬件；只对可信结构执行")
        controls.addWidget(self.hardware)
        self.timeout = QDoubleSpinBox()
        self.timeout.setRange(0.1, 3600)
        self.timeout.setValue(float(timeout))
        self.timeout.setSuffix(" s")
        controls.addWidget(_label("超时"))
        controls.addWidget(self.timeout)
        controls.addStretch(1)
        self.save_button = _button("保存", self.save)
        self.check_button = _button("检查", self.check)
        self.run_button = _button("运行", self.run, role="primary")
        self.stop_button = _button("停止", self.stop, role="danger")
        self.stop_button.setEnabled(False)
        for button in (self.save_button, self.check_button, self.run_button, self.stop_button):
            controls.addWidget(button)
        layout.addLayout(controls)

        split = QSplitter(Qt.Orientation.Vertical)
        self.editor = CodeEditor()
        self.editor.setPlaceholderText("打开或新建 .mt 动作脚本或 .sql 结构…")
        self.highlighter = CodeHighlighter(self.editor.document(), "mt")
        self.editor.textChanged.connect(self._on_text_changed)
        split.addWidget(self.editor)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setLineWrapMode(QPlainTextEdit.LineWrapMode.WidgetWidth)
        _mono(self.output)
        self.output.setPlaceholderText("检查/运行输出（JSON）…")
        split.addWidget(self.output)
        split.setSizes([520, 170])
        layout.addWidget(split, 1)

        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.progress.hide()
        layout.addWidget(self.progress)
        self.status = _label("", secondary=True)
        layout.addWidget(self.status)

        for key, slot in (("Ctrl+S", self.save), ("Ctrl+Shift+S", self.save_as),
                          ("Ctrl+Return", self.run), ("Ctrl+Enter", self.run),
                          ("F6", self.check)):
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
            shortcut.activated.connect(slot)

    # -- context -----------------------------------------------------------
    def set_context(self, *, python=None, cwd=None, robot=None, scripts_root=None,
                    robots_root=None, module_paths=None, camera_src_dir=None, timeout=None):
        if python:
            self.python = python
        if cwd is not None:
            self.cwd = str(cwd or ".")
        if robot is not None:
            self.robot = str(robot or "")
        changed = False
        if scripts_root is not None:
            root = Path(scripts_root).absolute() if str(scripts_root or "").strip() else None
            if root != self.scripts_root:
                self.scripts_root = root
                changed = True
        if robots_root is not None:
            root = Path(robots_root).absolute() if str(robots_root or "").strip() else None
            if root != self.robots_root:
                self.robots_root = root
                changed = True
        if changed:
            self.refresh_files()
        if module_paths is not None:
            self.module_paths = tuple(str(path) for path in module_paths if str(path).strip())
        if camera_src_dir is not None:
            self.camera_src_dir = str(camera_src_dir or "")
        if timeout is not None:
            self.timeout.setValue(float(timeout))
        self._sync_robot_label()

    def _is_structure(self, path=None):
        return Path(path or self.current_path or "").suffix.lower() == ".sql"

    def _sync_robot_label(self):
        if self.current_path and self._is_structure():
            self.robot_label.setText(f"结构：{Path(self.current_path).name}（编辑中）")
            self.robot_label.setToolTip(self.current_path)
            return
        name = Path(self.robot).name if self.robot else "未选择结构"
        self.robot_label.setText(f"结构：{name}")
        self.robot_label.setToolTip(self.robot or "在工具栏选择结构 SQL")

    def refresh_files(self):
        current = self.current_path
        structures = []
        scripts = []
        if self.robots_root is not None and self.robots_root.is_dir():
            try:
                structures = [path for path in sorted(self.robots_root.glob("*.sql"))
                              if not path.is_symlink() and path.is_file()]
            except OSError as exc:
                self.status.setText(f"读取结构目录失败：{exc}")
        root = self.scripts_root
        if root is not None and root.is_dir():
            try:
                for base, dirs, names in os.walk(root, followlinks=False):
                    dirs[:] = sorted(name for name in dirs if not (Path(base) / name).is_symlink())
                    for name in sorted(names):
                        path = Path(base) / name
                        if path.suffix == ".mt" and not path.is_symlink() and path.is_file():
                            scripts.append(path)
                    if len(scripts) >= MAX_SCRIPT_FILES:
                        break
            except OSError as exc:
                self.status.setText(f"读取脚本目录失败：{exc}")

        self.files.blockSignals(True)
        self.files.clear()
        self.files.addItem("（未打开文件）", "")
        for path in structures[:MAX_SCRIPT_FILES]:
            self.files.addItem(f"结构/{path.name}", str(path))
        for path in sorted(scripts[:MAX_SCRIPT_FILES],
                           key=lambda item: item.relative_to(root).as_posix()):
            self.files.addItem(f"脚本/{path.relative_to(root).as_posix()}", str(path))
        if current:
            index = self.files.findData(str(current))
            if index < 0 and Path(current).is_file():
                self.files.addItem(str(current), str(current))
                index = self.files.count() - 1
            if index >= 0:
                self.files.setCurrentIndex(index)
        self.files.blockSignals(False)

        previous = self.run_script.currentData()
        self.run_script.blockSignals(True)
        self.run_script.clear()
        self.run_script.addItem("（选择动作脚本）", "")
        for path in sorted(scripts[:MAX_SCRIPT_FILES],
                           key=lambda item: item.relative_to(root).as_posix()):
            self.run_script.addItem(path.relative_to(root).as_posix(), str(path))
        if previous:
            index = self.run_script.findData(previous)
            if index >= 0:
                self.run_script.setCurrentIndex(index)
        self.run_script.blockSignals(False)
        self._sync_run_script()

    def _sync_run_script(self):
        if self.current_path and not self._is_structure():
            index = self.run_script.findData(self.current_path)
            if index < 0:
                self.run_script.addItem(Path(self.current_path).name, self.current_path)
                index = self.run_script.count() - 1
            self.run_script.setCurrentIndex(index)
            self.run_script.setEnabled(False)
            return
        self.run_script.setEnabled(bool(self.current_path and self._is_structure()))

    # -- file operations ---------------------------------------------------
    def open_dialog(self):
        start = str(Path(self.current_path).parent) if self.current_path else str(self.scripts_root or self.cwd)
        path, _filter = QFileDialog.getOpenFileName(
            self, "打开脚本或结构", start,
            "动作脚本或结构 (*.mt *.sql);;动作脚本 (*.mt);;结构 SQL (*.sql);;所有文件 (*)")
        if path:
            self.open_path(path)

    def open_path(self, path):
        """Load a script after offering to save unsaved edits."""
        path = str(Path(path).absolute())
        if not self.maybe_save():
            self._select_path(self.current_path)
            return False
        try:
            text = self.reader(path)
        except (OSError, SecurityError, UnicodeError) as exc:
            self.status.setText(f"无法打开：{exc}")
            self._select_path(self.current_path)
            return False
        # Qt's toPlainText() always uses LF; keep saved_text comparable so a
        # Windows CRLF checkout does not look dirty immediately after opening.
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        self.current_path = path
        self.saved_text = text
        self._replace_text(text)
        self._set_language(path)
        self._set_dirty(False)
        self._sync_robot_label()
        self._sync_run_script()
        self.output.clear()
        self.status.setText(f"已打开 {path}")
        index = self.files.findData(path)
        if index < 0:
            self.files.addItem(path, path)
            index = self.files.count() - 1
        self.files.setCurrentIndex(index)
        return True

    def new_file(self):
        if not self.maybe_save():
            self._select_path(self.current_path)
            return False
        self.current_path = None
        self.saved_text = ""
        self._replace_text("")
        self._set_language("untitled.mt")
        self._set_dirty(False)
        self._sync_robot_label()
        self._sync_run_script()
        self.output.clear()
        self.files.setCurrentIndex(0)
        self.status.setText("新脚本：保存后即可检查或运行")
        return True

    def save(self):
        if self.current_path is None:
            return self.save_as()
        return self._write(self.current_path)

    def save_as(self):
        default = (Path(self.current_path) if self.current_path
                   else (self.scripts_root or Path(self.cwd)) / "untitled.mt")
        path, _filter = QFileDialog.getSaveFileName(
            self, "保存脚本或结构", str(default),
            "动作脚本 (*.mt);;结构 SQL (*.sql);;所有文件 (*)")
        if not path:
            return False
        if not Path(path).suffix:
            path += ".mt"
        return self._write(path)

    def _write(self, path):
        text = self.editor.toPlainText()
        try:
            self.writer(path, text)
        except (OSError, SecurityError, UnicodeError) as exc:
            self.status.setText(f"保存失败：{exc}")
            return False
        self.current_path = str(Path(path).absolute())
        self.saved_text = text
        self._set_language(self.current_path)
        self._set_dirty(False)
        self.refresh_files()
        self._sync_robot_label()
        self.status.setText(f"已保存 {self.current_path}")
        return True

    def _write_text(self, path, text):
        text = checked_text(text, MAX_EDITOR_BYTES)
        target = Path(path).absolute()
        if not target.parent.is_dir():
            raise FileNotFoundError(f"目录不存在：{target.parent}")
        fd, temp = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                stream.write(text)
            os.replace(temp, target)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise

    def maybe_save(self):
        """Return False only when the operator cancels a pending save."""
        if not self._dirty:
            return True
        name = Path(self.current_path).name if self.current_path else "新脚本"
        box = QMessageBox(self)
        box.setWindowTitle("未保存的修改")
        box.setText(f"{name} 有未保存的修改。")
        box.setStandardButtons(QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard
                               | QMessageBox.StandardButton.Cancel)
        box.setDefaultButton(QMessageBox.StandardButton.Save)
        choice = box.exec()
        if choice == QMessageBox.StandardButton.Save:
            return self.save()
        return choice == QMessageBox.StandardButton.Discard

    def _file_selected(self, index):
        previous = self.current_path
        data = self.files.itemData(index)
        if data:
            if not self.open_path(data):
                self._select_path(previous)
        elif not self.new_file():
            self._select_path(previous)

    def _select_path(self, path):
        index = self.files.findData(str(path)) if path else 0
        self.files.setCurrentIndex(index if index >= 0 else 0)

    def _set_language(self, path):
        language = {".sql": "sql", ".py": "python", ".lua": "lua"}.get(
            Path(path).suffix.lower(), "mt")
        self.highlighter.set_language(language)

    # -- change tracking ---------------------------------------------------
    @property
    def dirty(self):
        return self._dirty

    @property
    def running(self):
        return self._running

    def _replace_text(self, text):
        # Qt may deliver intermediate textChanged signals while replacing the
        # document; blockSignals alone is not enough on every platform.
        self._loading = True
        self.editor.blockSignals(True)
        try:
            self.editor.setPlainText(text)
        finally:
            self.editor.blockSignals(False)
            self._loading = False

    def _on_text_changed(self):
        if self._loading:
            return
        self._set_dirty(self.editor.toPlainText() != self.saved_text)

    def _set_dirty(self, value):
        value = bool(value)
        if value != self._dirty:
            self._dirty = value
            self.dirty_changed.emit(value)

    # -- controller commands ----------------------------------------------
    def _run_script(self):
        if self.current_path and not self._is_structure():
            return self.current_path
        return self.run_script.currentData() or ""

    def _run_structure(self):
        if self.current_path and self._is_structure():
            return self.current_path
        return self.robot

    def build_argv(self, command):
        if command not in {"check", "run"}:
            raise ValueError(f"unsupported editor command: {command}")
        if not self.current_path:
            raise ValueError("请先保存脚本")
        if command == "check" and self._is_structure():
            return cli_args("check", robot=self.current_path, module_paths=self.module_paths,
                            camera_src_dir=self.camera_src_dir)
        script = self._run_script()
        robot = self._run_structure()
        if not str(script).strip():
            raise ValueError("请选择运行脚本")
        if not str(robot).strip():
            raise ValueError("请选择结构 SQL")
        timeout = self.timeout.value() if command == "run" else None
        return cli_args(command, robot=robot, script=script, timeout=timeout,
                        allow_hardware=command == "run" and self.hardware.isChecked(),
                        module_paths=self.module_paths, camera_src_dir=self.camera_src_dir)

    def check(self):
        self._start("check")

    def run(self):
        self._start("run")

    def _start(self, command):
        if self._running:
            return
        if self._dirty and not self.save():
            return
        if not self.current_path and not self.save_as():
            return
        try:
            argv = self.build_argv(command)
        except ValueError as exc:
            self.status.setText(f"参数不完整：{exc}")
            self.output.setPlainText(str(exc))
            return
        if command == "run" and self.hardware.isChecked() and not self.confirm(
                "确认硬件权限", "该命令会激活机器人并可能写硬件；只对可信结构执行。"):
            return
        self._running = True
        self._set_buttons()
        self.progress.show()
        self.output.clear()
        self.status.setText("检查中…" if command == "check" else "运行中…")
        QThreadPool.globalInstance().start(_EditorTask(self, argv))

    def stop(self):
        if self._call is not None:
            try:
                self._call.kill()
            except OSError:
                pass
            self.status.setText("正在停止…")

    def shutdown(self):
        self.stop()

    def _set_buttons(self):
        for button in (self.save_button, self.check_button, self.run_button):
            button.setEnabled(not self._running)
        self.stop_button.setEnabled(self._running)

    def _done(self, result):
        self._running = False
        self._set_buttons()
        self.progress.hide()
        if result.get("error"):
            self.status.setText(str(result["error"]))
            self.output.setPlainText(str(result["error"]))
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

    def _run_cli(self, argv, cwd):
        call = CliCall(self.python, argv, cwd)
        self._call = call
        try:
            result = call.wait()
        finally:
            self._call = None
        return {"code": result.code, "json": result.json, "stdout": result.stdout,
                "stderr": result.stderr[-4000:], "duration_ms": result.duration_ms}

    def _confirm(self, title, text):
        return QMessageBox.question(
            self, title, text, QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes
