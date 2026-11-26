import json
import os
from pathlib import Path
import shlex

import pytest

from conftest import usable_symlink
from pymybot import paths
from pymybot.errors import ScriptError
from pymybot.robot import Robot
from pymybot.scaffold import create_robot


OUTPUTS = ("robots/probe.sql", "scripts/probe.mt", "modules/Probe.py")


@pytest.fixture
def skill_copy(tmp_path, monkeypatch):
    skill = tmp_path / "skill"
    package = skill / "scripts" / "pymybot"
    package.mkdir(parents=True)
    for kind in ("robots", "scripts", "modules"):
        (skill / "assets" / kind).mkdir(parents=True)
    monkeypatch.setattr(paths, "package_dir", lambda: package)
    monkeypatch.setattr(paths, "frozen", lambda: False)
    return skill


def tree_state(root):
    """Capture entries as well as contents: refusals must not even create dirs."""
    return {
        path.relative_to(root): ("link", str(path.readlink())) if path.is_symlink()
        else ("file", path.read_bytes()) if path.is_file() else ("directory",)
        for path in root.rglob("*")
    }


def test_new_robot_is_runnable_without_hardware(tmp_path):
    result = create_robot(tmp_path, "mybot-arm")

    assert result["robot"] == "robots/mybot-arm.sql"
    assert result["script"] == "scripts/mybot-arm.mt"
    assert result["driver"] == "modules/MybotArm.py"
    assert all((tmp_path / path).is_file() for path in
               (result["robot"], result["script"], result["driver"]))

    robot = Robot.from_file(tmp_path / result["robot"], module_paths=[tmp_path / "modules"])
    with robot:
        outputs = robot.run((tmp_path / result["script"]).read_text(encoding="utf-8"),
                            base_dir=str(tmp_path / "scripts"))
    assert outputs == [{"result": "OK", "ping": 1}]


def test_new_robot_refuses_partial_overwrite(tmp_path):
    create_robot(tmp_path, "probe")
    (tmp_path / "scripts" / "probe.mt").write_text("# keep me\n", encoding="utf-8")

    try:
        create_robot(tmp_path, "probe")
    except ScriptError as exc:
        assert "--force" in str(exc)
    else:
        raise AssertionError("expected a refusal")
    assert (tmp_path / "scripts" / "probe.mt").read_text(encoding="utf-8") == "# keep me\n"


def test_new_command_returns_json(tmp_path, capsys):
    from pymybot.cli import main

    code = main(["new", "desk", "--dir", str(tmp_path)])
    output = json.loads(capsys.readouterr().out)

    assert code == 0
    assert output["ok"] is True and output["command"] == "new"
    assert (tmp_path / "robots" / "desk.sql").is_file()
    assert (tmp_path / "modules" / "Desk.py").is_file()


def test_new_printed_commands_run_from_the_generated_root(tmp_path, monkeypatch, capsys):
    """The scaffold promises runnable follow-up commands; run them as printed."""
    from pymybot.cli import main

    assert main(["new", "desk", "--dir", str(tmp_path)]) == 0
    commands = json.loads(capsys.readouterr().out)["commands"]

    monkeypatch.chdir(tmp_path)
    for command in commands:
        argv = shlex.split(command)[1:]  # drop the "pymybot" executable name
        code = main(argv)
        output = json.loads(capsys.readouterr().out)
        assert code == 0 and output["ok"] is True, (command, output)


@pytest.mark.parametrize("with_pyproject", [False, True], ids=["skill-copy", "checkout"])
@pytest.mark.parametrize("relative", [".", "new/workspace", "scripts", "assets/robots"])
@pytest.mark.parametrize("force", [False, True])
def test_new_robot_refuses_skill_directories(tmp_path, skill_copy, relative, force, with_pyproject):
    if with_pyproject:
        (skill_copy / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
    else:
        assert not (skill_copy / "pyproject.toml").exists()
    before = tree_state(tmp_path)

    with pytest.raises(ScriptError, match="read-only"):
        create_robot(skill_copy / relative, "probe", force=force)

    assert tree_state(tmp_path) == before


@pytest.mark.parametrize("force", [False, True])
def test_new_robot_refuses_workspace_alias_into_skill(tmp_path, skill_copy, force):
    workspace = tmp_path / "workspace"
    if not usable_symlink(workspace, skill_copy):
        pytest.skip("symlinks are not usable on this platform")
    before = tree_state(tmp_path)

    with pytest.raises(ScriptError, match="read-only"):
        create_robot(workspace, "probe", force=force)

    assert tree_state(tmp_path) == before


@pytest.mark.parametrize("output", OUTPUTS)
@pytest.mark.parametrize("link_kind", ["directory", "file"])
@pytest.mark.parametrize("destination", ["skill", "outside"])
@pytest.mark.parametrize("force", [False, True])
def test_new_robot_preflights_output_symlinks(tmp_path, skill_copy, output, link_kind, destination, force):
    workspace = tmp_path / "workspace"
    relative = Path(output).parent if link_kind == "directory" else Path(output)
    link = workspace / relative
    target = (skill_copy if destination == "skill" else tmp_path / "outside") / relative
    link.parent.mkdir(parents=True, exist_ok=True)
    if link_kind == "directory":
        target.mkdir(parents=True, exist_ok=True)
        (target / Path(output).name).write_text("keep target\n", encoding="utf-8")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("keep target\n", encoding="utf-8")
    if not usable_symlink(link, target):
        pytest.skip("symlinks are not usable on this platform")
    before = tree_state(tmp_path)

    message = "read-only" if destination == "skill" else "escapes the workspace"
    with pytest.raises(ScriptError, match=message):
        create_robot(workspace, "probe", force=force)

    assert tree_state(tmp_path) == before


@pytest.mark.parametrize("location", ["relative", "absolute", "alias", "same-prefix"])
def test_new_robot_accepts_external_workspaces(tmp_path, monkeypatch, skill_copy, location):
    workspace = tmp_path / ("skill-workspace" if location == "same-prefix" else "workspace")
    monkeypatch.chdir(skill_copy)
    root = workspace
    if location == "relative":
        root = Path("..") / workspace.name
    elif location == "alias":
        workspace.mkdir()
        root = tmp_path / "alias"
        if not usable_symlink(root, workspace):
            pytest.skip("symlinks are not usable on this platform")
    before = tree_state(skill_copy)

    result = create_robot(root, "probe")

    assert result["root"] == str(workspace.resolve())
    assert result["created"] == [str(workspace.resolve() / output) for output in OUTPUTS]
    assert all((workspace / output).read_bytes() for output in OUTPUTS)
    assert tree_state(skill_copy) == before


@pytest.mark.parametrize("output", OUTPUTS)
@pytest.mark.parametrize("existing_peers", [False, True], ids=["missing-peers", "existing-peers"])
def test_new_robot_force_refuses_hard_links(tmp_path, skill_copy, output, existing_peers):
    workspace = tmp_path / "workspace"
    original = skill_copy / "original.txt"
    original.write_text("keep original\n", encoding="utf-8")
    target = workspace / output
    target.parent.mkdir(parents=True)
    try:
        os.link(original, target)
    except (OSError, NotImplementedError):
        pytest.skip("hard links are not usable on this platform")
    if not target.exists() or not target.samefile(original) or target.stat().st_nlink <= 1:
        pytest.skip("hard links are not usable on this platform")
    if existing_peers:
        for peer in OUTPUTS:
            if peer != output:
                path = workspace / peer
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("keep peer\n", encoding="utf-8")
    before = tree_state(tmp_path)
    links = original.stat().st_nlink

    with pytest.raises(ScriptError, match="hard-linked"):
        create_robot(workspace, "probe", force=True)

    assert tree_state(tmp_path) == before
    assert original.stat().st_nlink == target.stat().st_nlink == links
    assert target.samefile(original)


@pytest.mark.parametrize("output", OUTPUTS)
@pytest.mark.parametrize("force", [False, True])
def test_new_robot_refuses_non_file_targets(tmp_path, skill_copy, output, force):
    workspace = tmp_path / "workspace"
    (workspace / output).mkdir(parents=True)
    before = tree_state(tmp_path)

    with pytest.raises(ScriptError, match="not a regular file"):
        create_robot(workspace, "probe", force=force)

    assert tree_state(tmp_path) == before


def test_new_robot_force_overwrites_regular_files(tmp_path, skill_copy):
    workspace = tmp_path / "workspace"
    result = create_robot(workspace, "probe")
    expected = {output: (workspace / output).read_bytes() for output in OUTPUTS}
    for output in OUTPUTS:
        (workspace / output).write_text("replace me\n", encoding="utf-8")

    assert create_robot(workspace, "probe", force=True) == result
    assert {output: (workspace / output).read_bytes() for output in OUTPUTS} == expected
