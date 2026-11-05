"""Regenerate the real GUI screenshots under ``docs/screenshots``.

This drives the REAL window against the REAL serve backend (a genuine
``python -m pymybot serve`` child), with a disposable demo workspace so the
files tab shows actual previews. Nothing is mocked except the operator home
(MYBOT_HOME) and the display (QT_QPA_PLATFORM=offscreen).

Usage: python tools/gui_screenshots.py [--out docs/screenshots] [--timeout 30]
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import Qt  # noqa: E402
from PySide6.QtGui import QColor, QPixmap  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

REPO = ROOT
SCREENSHOTS = [
    "gui-splash.png", "gui.png", "gui-files.png", "gui-files-html.png",
    "gui-resources.png", "gui-wizard.png", "gui-settings.png",
    "gui-command.png", "gui-sessions.png", "gui-mcp.png", "gui-doctor.png",
]
DEMO_SQL = "CREATE TABLE Relay(name String, path String);\nINSERT INTO Relay(name, path) VALUES('relay0', 'virt-relay');\n"
DEMO_MT = "@Action\nrelay0.test dev.echo;\n7 9;\n@\n"
DEMO_MD = """# mybot 演示工作区

这是一个**真实**的工作区文件树：`文件` 标签页直接浏览本目录。

- `robot.sql` 结构文件（SQL 高亮）
- `demo.mt` 动作脚本（MT 高亮）
- `page.html` 侧边栏 HTML 预览（不执行脚本、不加载外部资源）
- `logo.png` 图片预览
"""
DEMO_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>侧边栏预览</title>
<style>body{font-family:sans-serif;color:#0f172a}h1{color:#2563eb}</style>
</head><body>
<h1>mybot 文件预览</h1>
<p>HTML 预览在 <b>QTextBrowser</b> 中渲染：不执行 JavaScript，也不加载任何外部资源。</p>
<ul><li>只读浏览</li><li>安全沙盒</li><li>真实工作区</li></ul>
</body></html>
"""


def prepare_workspace(base: Path) -> Path:
    workspace = base / "demo-workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "robot.sql").write_text(DEMO_SQL, encoding="utf-8")
    (workspace / "demo.mt").write_text(DEMO_MT, encoding="utf-8")
    (workspace / "README.md").write_text(DEMO_MD, encoding="utf-8")
    (workspace / "page.html").write_text(DEMO_HTML, encoding="utf-8")
    from pymybot.gui.branding import logo_pixmap
    logo_pixmap(64).save(str(workspace / "logo.png"))
    return workspace


def pump(application, seconds):
    """Run the event loop for a wall-clock duration, keeping the UI live."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        application.processEvents()
        time.sleep(0.01)


def wait_for(condition, application, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        application.processEvents()
        if condition():
            return True
        time.sleep(0.05)
    raise RuntimeError(f"timeout waiting for: {message}")


def grab(widget, out: Path, name: str):
    pixmap = widget.grab()
    target = out / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not pixmap.save(str(target)):
        raise RuntimeError(f"cannot save {target}")
    print(f"saved {target} ({pixmap.width()}x{pixmap.height()})")


def select_file(panel, name):
    found = []

    def walk(item):
        if item.data(0, Qt.ItemDataRole.UserRole) and item.text(0) == name:
            found.append(item)
        for index in range(item.childCount()):
            walk(item.child(index))

    walk(panel.tree.invisibleRootItem())
    assert found, f"file {name} not in the tree"
    panel.tree.setCurrentItem(found[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(REPO / "docs" / "screenshots"))
    parser.add_argument("--timeout", type=float, default=30.0)
    arguments = parser.parse_args()
    out = Path(arguments.out)

    os.environ["MYBOT_SESSION_LOG"] = "0"
    home = Path(tempfile.mkdtemp(prefix="mybot-shots-"))
    os.environ["MYBOT_HOME"] = str(home / "operator")

    application = QApplication.instance() or QApplication([sys.argv[0]])
    application.setQuitOnLastWindowClosed(False)
    workspace = prepare_workspace(home)  # after QApplication: logo_pixmap needs QGuiApplication

    from pymybot.gui import app as gui_app
    from pymybot.gui.config import GuiConfig
    from pymybot.gui.dialogs import (DoctorDialog, McpConfigDialog, ModelSetupDialog,
                                     SessionsDialog)
    from pymybot.gui.splash import SplashScreen

    splash = SplashScreen()
    splash.show()
    pump(application, 0.5)
    grab(splash, out, "gui-splash.png")
    splash.close()

    config = GuiConfig(workspace=str(workspace), robot=str(workspace / "robot.sql"))
    window = gui_app.App(config, home / "settings.json")
    try:
        wait_for(lambda: window.serve is not None, application, arguments.timeout,
                 "real serve backend handshake")
        window.show()
        pump(application, 0.6)
        grab(window, out, "gui.png")

        # Files tab: real workspace tree, code and HTML previews.
        window.show_files()
        select_file(window.files, "robot.sql")
        pump(application, 0.3)
        grab(window, out, "gui-files.png")
        select_file(window.files, "page.html")
        pump(application, 0.3)
        grab(window, out, "gui-files-html.png")

        # Resources tab: bundled scripts/skills/robots.
        window.notebook.setCurrentWidget(window.resources)
        window.show_resources()
        wait_for(lambda: window.resources.loaded, application, 15, "resource index")
        pump(application, 0.4)
        grab(window, out, "gui-resources.png")

        wizard = ModelSetupDialog(window)
        wizard.provider.setCurrentIndex(1)
        wizard.model_name.setText("gpt-4o")
        wizard.show()
        pump(application, 0.2)
        grab(wizard, out, "gui-wizard.png")
        wizard.close()

        settings = gui_app.SettingsDialog(window, window.cfg, str(workspace),
                                          str(home / "settings.json"))
        settings.show()
        pump(application, 0.5)
        grab(settings, out, "gui-settings.png")
        settings.close()

        command = gui_app.CommandDialog(
            window, python=gui_app.resolve_python(str(workspace), window.cfg.python),
            cwd=str(workspace), robot=str(workspace / "robot.sql"),
            module_paths=window._module_paths(), scripts_dir=window._scripts_root(),
            timeout=window.cfg.timeout,
            confirm=lambda *_args: False)
        command.show()
        pump(application, 0.3)
        grab(command, out, "gui-command.png")
        command.close()

        sessions = SessionsDialog(window, root=home / "sessions")
        sessions.show()
        pump(application, 0.3)
        grab(sessions, out, "gui-sessions.png")
        sessions.close()

        mcp = McpConfigDialog(window, path=str(home / "mcp.json"))
        mcp.show()
        pump(application, 0.3)
        grab(mcp, out, "gui-mcp.png")
        mcp.close()

        doctor = DoctorDialog(window)  # the doctor checks run in the constructor
        doctor.show()
        pump(application, 0.4)
        assert doctor.table.rowCount() > 0, "doctor table stayed empty"
        grab(doctor, out, "gui-doctor.png")
        doctor.close()
    finally:
        window.shutdown()
        window.close()
        window.wait_for_shutdown()
        window.deleteLater()
        pump(application, 0.3)
    shutil.rmtree(home, ignore_errors=True)
    missing = [name for name in SCREENSHOTS if not (out / name).is_file()]
    if missing:
        raise RuntimeError(f"missing screenshots: {missing}")
    print(f"all {len(SCREENSHOTS)} screenshots regenerated in {out}")


if __name__ == "__main__":
    main()
