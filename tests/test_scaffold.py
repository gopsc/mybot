import json

from pymybot.errors import ScriptError
from pymybot.robot import Robot
from pymybot.scaffold import create_robot


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
