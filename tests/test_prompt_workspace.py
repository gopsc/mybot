"""Opt-in prompt protection uses temporary roots, never the operator's prompts."""
import asyncio
import os
from pathlib import Path
import shlex
import time
from types import SimpleNamespace

import pytest

from pymybot import sandbox
from pymybot import agent_workspace as workspace_module
from pymybot.agent_executor import RobotExecutor
from pymybot.agent_workspace import Workspace
from pymybot.security import SecurityError


ASSETS = ("0-system.md", "100-safety.md", "97-memory.md", "98-user.md", "99-policy.md",
          ".backup/97-old.md", "manifest.json", ".manifest.json", "other.txt")


def invoke(workspace, name, arguments=None, *, starts=None):
    starts = [] if starts is None else starts
    end = time.monotonic() + 10

    def check():
        if time.monotonic() >= end:
            raise TimeoutError("Test tool deadline expired")

    return workspace.call(name, arguments or {}, check, lambda: starts.append(True))


def file_arguments(tool, path):
    if tool == "write_file":
        return {"path": path, "content": "changed", "overwrite": True}
    if tool == "edit_file":
        return {"path": path, "old_string": "private", "new_string": "changed"}
    return {"path": path}


@pytest.fixture
def assets(tmp_path):
    workspace = tmp_path / "workspace"
    home = workspace / "runtime" / "prompts"
    defaults = workspace / "source" / "prompts"
    for root in (home, defaults):
        (root / ".backup").mkdir(parents=True)
        for name in ASSETS:
            (root / name).write_text("private", encoding="utf-8")
    return SimpleNamespace(workspace=workspace, home=home, defaults=defaults,
                           roots=(home, defaults))


@pytest.mark.parametrize("tool", ["read_file", "write_file", "edit_file"])
@pytest.mark.parametrize("root_name", ["home", "defaults"])
@pytest.mark.parametrize("asset", ASSETS)
def test_generic_file_tools_cannot_access_any_prompt_asset(assets, tool, root_name, asset):
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    target = getattr(assets, root_name) / asset
    relative = target.relative_to(assets.workspace).as_posix()
    starts = []
    with pytest.raises(SecurityError, match="read_prompt"):
        invoke(workspace, tool, file_arguments(tool, relative), starts=starts)
    assert not starts
    assert target.read_text(encoding="utf-8") == "private"


@pytest.mark.parametrize("root_name", ["home", "defaults"])
@pytest.mark.parametrize("suffix", ["", ".backup", ".backup/missing", "missing"])
def test_listing_prompt_directories_is_private(assets, root_name, suffix):
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    path = (getattr(assets, root_name) / suffix).relative_to(assets.workspace).as_posix()
    with pytest.raises(SecurityError, match="read_prompt"):
        invoke(workspace, "list_files", {"path": path})


def test_protected_roots_can_be_named_but_not_opened_and_siblings_work(assets):
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    assert {entry["name"] for entry in invoke(workspace, "list_files")["entries"]} == {"runtime", "source"}
    assert invoke(workspace, "list_files", {"path": "runtime"})["entries"] == [
        {"name": "prompts", "type": "directory"}]
    for relative in ("ordinary.txt", "runtime/note.txt", "source/prompts-other.txt"):
        invoke(workspace, "write_file", {"path": relative, "content": "private"})
        invoke(workspace, "edit_file", file_arguments("edit_file", relative))
        assert invoke(workspace, "read_file", {"path": relative})["content"] == "changed"
    with pytest.raises(SecurityError, match="read_prompt"):
        invoke(workspace, "write_file", {"path": "runtime/prompts/new.txt", "content": "bad"})
    assert not (assets.home / "new.txt").exists()


@pytest.mark.parametrize("relative", ["runtime", "runtime/prompts", "source", "source/prompts"])
@pytest.mark.parametrize("tool", ["write_file", "edit_file"])
def test_generic_writes_cannot_replace_prompt_roots_or_ancestors(assets, relative, tool):
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    with pytest.raises(SecurityError, match="protected"):
        invoke(workspace, tool, file_arguments(tool, relative))


@pytest.mark.parametrize("nested", [False, True])
def test_workspace_cannot_be_or_be_inside_a_protected_root(assets, nested):
    target = assets.home / ".backup" if nested else assets.home
    with pytest.raises(SecurityError, match="inside a protected"):
        Workspace(target, protected_paths=assets.roots)


def test_protected_roots_must_exist_and_be_directories(assets, tmp_path):
    with pytest.raises(FileNotFoundError):
        Workspace(assets.workspace, protected_paths=[tmp_path / "missing"])
    with pytest.raises(SecurityError, match="directories"):
        Workspace(assets.workspace, protected_paths=[assets.home / ASSETS[0]])


def test_protected_paths_are_an_immutable_canonical_snapshot(assets):
    paths = [assets.home / ".backup" / "..", assets.defaults, assets.home]
    workspace = Workspace(assets.workspace, protected_paths=paths)
    paths.clear()
    assert workspace.protected_paths == assets.roots
    with pytest.raises(AttributeError):
        workspace.protected_paths = ()


@pytest.mark.parametrize("fallback", [False, True])
def test_protected_roots_and_file_aliases_reject_links(assets, monkeypatch, fallback):
    from conftest import usable_symlink

    if fallback:
        monkeypatch.setattr(workspace_module, "_DIR_FD", False)
    linked = assets.workspace / "alias"
    if not usable_symlink(linked, assets.home.parent):
        pytest.skip("Symlinks unavailable")
    with pytest.raises(SecurityError, match="Linked"):
        Workspace(assets.workspace, protected_paths=[linked / "prompts"])
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    for tool in ("read_file", "write_file", "edit_file"):
        with pytest.raises(SecurityError):
            invoke(workspace, tool, file_arguments(tool, "alias/prompts/97-memory.md"))
    assert "alias" not in {entry["name"] for entry in invoke(workspace, "list_files")["entries"]}


@pytest.mark.parametrize("fallback", [False, True])
@pytest.mark.parametrize("tool", ["read_file", "write_file", "edit_file"])
def test_prompt_hardlink_aliases_are_denied_even_when_created_after_setup(assets, monkeypatch, fallback, tool):
    if fallback:
        monkeypatch.setattr(workspace_module, "_DIR_FD", False)
    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    target = assets.home / "97-memory.md"
    try:
        os.link(target, assets.workspace / "alias.txt")
    except OSError:
        pytest.skip("Hardlinks unavailable")
    starts = []
    with pytest.raises(SecurityError, match="Hardlinked"):
        invoke(workspace, tool, file_arguments(tool, "alias.txt"), starts=starts)
    assert not starts
    assert target.read_text(encoding="utf-8") == "private"
    assert "alias.txt" not in {entry["name"] for entry in invoke(workspace, "list_files")["entries"]}


@pytest.mark.parametrize("replacement", ["directory", "symlink"])
def test_changed_protected_roots_fail_closed(assets, replacement):
    from conftest import usable_symlink

    workspace = Workspace(assets.workspace, protected_paths=assets.roots)
    moved = assets.home.with_name("moved")
    assets.home.rename(moved)
    if replacement == "directory":
        assets.home.mkdir()
    elif not usable_symlink(assets.home, moved):
        pytest.skip("Symlinks unavailable")
    starts = []
    with pytest.raises(SecurityError):
        invoke(workspace, "write_file", {"path": "ordinary.txt", "content": "x"}, starts=starts)
    assert not starts
    assert not (assets.workspace / "ordinary.txt").exists()


def test_protected_shell_mounts_override_workspace_and_pin_ancestors(assets, tmp_path, monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", True)
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/bwrap")
    packaged = tmp_path / "installed" / "prompts"
    packaged.mkdir(parents=True)
    roots = (assets.home / ".backup", packaged, *assets.roots)
    command = ["/bin/sh", "-c", "exit 0"]
    argv, backend = sandbox.wrap_shell(command, mode="auto", workspace=assets.workspace,
                                        cwd=assets.workspace, protected_paths=roots)
    assert backend == "bwrap"
    writable = argv.index("--bind")
    assert argv[writable:writable + 3] == ["--bind", str(assets.workspace), str(assets.workspace)]
    readonly = []
    for index, value in enumerate(argv):
        if value == "--ro-bind" and argv[index + 1] != "/":
            assert index > writable
            readonly.append(Path(argv[index + 1]))
            assert argv[index + 1] == argv[index + 2]
    assert set(readonly) == set(roots)
    assert readonly.index(assets.home) < readonly.index(assets.home / ".backup")
    for parent in (assets.home.parent, assets.defaults.parent):
        index = argv.index(str(parent))
        assert argv[index - 1:index + 2] == ["--bind", str(parent), str(parent)]
        assert writable < index < argv.index(str(assets.home))
    assert argv[-4:] == ["--", *command]


@pytest.mark.parametrize("mode,usable", [("off", False), ("off", True), ("auto", False), ("bwrap", False)])
def test_protected_shell_never_launches_an_unisolated_fallback(assets, monkeypatch, mode, usable):
    monkeypatch.setattr(sandbox, "_USABLE", usable)
    monkeypatch.setattr(workspace_module.subprocess, "Popen", lambda *a, **kw: pytest.fail("Shell must not launch"))
    workspace = Workspace(assets.workspace, enable_shell=True, sandbox=mode, protected_paths=assets.roots)
    starts = []
    with pytest.raises(SecurityError, match="bubblewrap"):
        invoke(workspace, "shell", {"command": "exit 0"}, starts=starts)
    assert not starts


@pytest.mark.parametrize("mode", ["off", "auto"])
def test_workspace_without_protected_paths_keeps_legacy_behavior(assets, monkeypatch, mode):
    monkeypatch.setattr(sandbox, "_USABLE", False)
    workspace = Workspace(assets.workspace, enable_shell=True, sandbox=mode)
    assert workspace.protected_paths == ()
    assert invoke(workspace, "read_file", {"path": "runtime/prompts/0-system.md"})["content"] == "private"
    result = invoke(workspace, "shell", {"command": "exit 0"})
    assert result["sandbox"] == "workspace" and result["exit_code"] == 0


def test_protected_shell_passes_roots_to_wrapper(assets, monkeypatch):
    workspace = Workspace(assets.workspace, enable_shell=True, sandbox="auto", protected_paths=assets.roots)
    seen = []

    def wrapped(argv, **kwargs):
        seen.append(kwargs)
        raise SecurityError("Stop before launch")

    monkeypatch.setattr(workspace_module, "wrap_shell", wrapped)
    with pytest.raises(SecurityError, match="Stop before launch"):
        invoke(workspace, "shell", {"command": "exit 0"})
    assert seen == [{"mode": "auto", "workspace": assets.workspace, "cwd": assets.workspace,
                     "protected_paths": assets.roots}]


def test_protected_shell_rejects_preexisting_hardlinks_outside_mounts(assets, monkeypatch):
    workspace = Workspace(assets.workspace, enable_shell=True, sandbox="bwrap", protected_paths=assets.roots)
    try:
        os.link(assets.home / "97-memory.md", assets.workspace / "alias.txt")
    except OSError:
        pytest.skip("Hardlinks unavailable")
    monkeypatch.setattr(workspace_module.subprocess, "Popen", lambda *a, **kw: pytest.fail("Shell must not launch"))
    with pytest.raises(SecurityError, match="Hardlinked"):
        invoke(workspace, "shell", {"command": "exit 0"})


class StaticRobot:
    """No drivers, native runtime, hardware, or external services."""
    tables = ()

    def __init__(self, *args, **kwargs):
        pass

    def _validate(self, tables):
        pass

    def _rows(self, tables):
        return {}

    def deactivate(self):
        pass


@pytest.mark.parametrize("mode", ["off", "auto", "bwrap"])
def test_executor_opt_in_is_frozen_and_denials_are_not_executed(assets, tmp_path, monkeypatch, mode):
    monkeypatch.setattr(sandbox, "_USABLE", False)
    robot = tmp_path / "robot.sql"
    robot.write_text("", encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()

    async def scenario():
        executor = RobotExecutor(robot, scripts_dir=scripts, workspace_dir=assets.workspace,
                                 enable_shell=True, sandbox=mode, robot_factory=StaticRobot)
        paths = list(assets.roots)
        executor.protect_prompts(paths)
        paths.clear()
        try:
            assert "robot" in await executor.start()
            assert executor._workspace.protected_paths == assets.roots
            for replacement in ([], assets.roots):
                with pytest.raises(SecurityError, match="before executor startup"):
                    executor.protect_prompts(replacement)
            for tool, args in (("shell", {"command": "exit 0"}),
                               ("read_file", {"path": "runtime/prompts/0-system.md"}),
                               ("write_file", file_arguments("write_file", "source/prompts/100-safety.md")),
                               ("edit_file", file_arguments("edit_file", "runtime/prompts/97-memory.md")),
                               ("list_files", {"path": "runtime/prompts"})):
                result = await executor.call(tool, args)
                assert not result["ok"] and not result["executed"]
                assert result["state"] == "not_executed"
                expected = "bubblewrap" if tool == "shell" else "read_prompt"
                assert expected in result["error"]["message"]
                assert not executor.faulted
            assert (await executor.call("write_file", {"path": "ordinary.txt", "content": "ok"}))["ok"]
        finally:
            await executor.close()

    asyncio.run(scenario())


def test_real_bwrap_prevents_prompt_mutation_but_allows_ordinary_writes(assets, tmp_path, monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", None)
    if not sandbox.bwrap_usable():
        pytest.skip("bubblewrap cannot create a namespace on this host")
    packaged = tmp_path / "installed" / "prompts"
    packaged.mkdir(parents=True)
    (packaged / "100-safety.md").write_text("private", encoding="utf-8")
    roots = (*assets.roots, packaged)
    workspace = Workspace(assets.workspace, enable_shell=True, sandbox="auto", protected_paths=roots)
    commands = []
    originals = {path: path.read_bytes() for root in roots for path in root.rglob("*") if path.is_file()}
    for target in (*originals, *(root / "new.txt" for root in roots)):
        commands.append(f"if printf changed > {shlex.quote(str(target))}; then exit 41; fi")
    ancestor = shlex.quote(str(assets.home.parent))
    moved = shlex.quote(str(assets.home.parent.with_name("moved")))
    commands.append(f"if mv {ancestor} {moved}; then exit 42; fi")
    for relative in ("ordinary.txt", "runtime/note.txt", "source/note.txt"):
        commands.append(f"printf ordinary > {shlex.quote(relative)} || exit 43")
    result = invoke(workspace, "shell", {"command": "; ".join(commands)})
    assert result["exit_code"] == 0, result
    assert result["sandbox"] == "bwrap"
    for path, content in originals.items():
        assert path.read_bytes() == content
    for root in roots:
        assert not (root / "new.txt").exists()
    for relative in ("ordinary.txt", "runtime/note.txt", "source/note.txt"):
        assert (assets.workspace / relative).read_text(encoding="utf-8") == "ordinary"
