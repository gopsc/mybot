import asyncio
import json
from pathlib import Path
import sys

import pytest

from pymybot.agent_skill_runner import SkillRunner
from pymybot.agent_skills import SkillsLibrary
from pymybot.agent_executor import RobotExecutor
from pymybot.errors import BudgetExceeded
from pymybot.security import SecurityError

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"

SKILL_MD = "---\nname: demo-skill\ndescription: Demo runnable skill.\n---\n\n# Demo\n"


def make_skill(tmp_path, *, argv=None, params=None, hardware_flag=None, entry=None, effect="read"):
    root = tmp_path / "skills"
    skill = root / "demo-skill"
    scripts = skill / "scripts"
    scripts.mkdir(parents=True)
    (skill / "SKILL.md").write_text(SKILL_MD, encoding="utf-8")
    data = skill / "assets" / "data.txt"
    data.parent.mkdir(parents=True)
    data.write_text("ok", encoding="utf-8")
    (scripts / "task.py").write_text(entry or (
        "import json, os, sys\n"
        "print(json.dumps({'argv': sys.argv[1:], 'secret': os.environ.get('OPENAI_API_KEY')}))\n"
    ), encoding="utf-8")
    action = {"effect": effect, "output": "json", "argv": argv or [],
              "params": params or {}}
    if hardware_flag:
        action["hardwareFlag"] = hardware_flag
    (skill / "skill.json").write_text(json.dumps({
        "version": 1,
        "run": {"entrypoint": "scripts/task.py", "actions": {"echo": action}},
    }), encoding="utf-8")
    return SkillsLibrary(root)


def test_runner_executes_fixed_action_with_minimal_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-leak")
    library = make_skill(tmp_path, argv=["{value}"], params={
        "value": {"type": "number", "min": 0, "max": 10}})

    result = SkillRunner(library).run("demo-skill", "echo", {"value": 3})

    assert result["exit_code"] == 0 and result["output_error"] is None
    assert result["output"] == {"argv": ["3"], "secret": None}
    assert result["stderr"] == ""


def test_runner_resolves_declared_path_scope(tmp_path):
    library = make_skill(tmp_path, argv=["{file}"], params={
        "file": {"type": "path", "scope": ["skill_assets"], "suffix": ".txt", "required": True}})

    result = SkillRunner(library).run(
        "demo-skill", "echo", {"file": {"scope": "skill_assets", "path": "data.txt"}})

    assert Path(result["output"]["argv"][0]).name == "data.txt"


@pytest.mark.parametrize("arguments", [
    {"file": {"scope": "skill_assets", "path": "../outside.txt"}},
    {"file": {"scope": "other", "path": "data.txt"}},
    {"file": {"scope": "skill_assets", "path": "data.txt", "extra": "no"}},
])
def test_runner_allows_paths_outside_declared_scopes(tmp_path, arguments):
    library = make_skill(tmp_path, argv=["{file}"], params={
        "file": {"type": "path", "scope": ["skill_assets"], "suffix": ".txt", "required": True}})
    result = SkillRunner(library).run("demo-skill", "echo", arguments)
    assert result["exit_code"] == 0 and result["output"]["argv"]


def test_runner_allows_manifest_hardware_flag(tmp_path):
    library = make_skill(tmp_path, argv=["--allow-hardware"], hardware_flag=None)
    result = SkillRunner(library).run("demo-skill", "echo", {})
    assert result["output"]["argv"] == ["--allow-hardware"]


def test_runner_adds_hardware_flag_only_from_host_grant(tmp_path):
    library = make_skill(tmp_path, argv=["run"], hardware_flag="--allow-hardware", effect="execute")

    without = SkillRunner(library).run("demo-skill", "echo", {}, allow_hardware=False)
    with_hardware = SkillRunner(library).run("demo-skill", "echo", {}, allow_hardware=True)

    assert without["output"]["argv"] == ["run"]
    assert with_hardware["output"]["argv"] == ["run", "--allow-hardware"]


def test_runner_uses_cli_fallback_for_packaged_skill(tmp_path):
    root = tmp_path / "skills"
    skill = root / "packaged-skill"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text(
        "---\nname: packaged-skill\ndescription: Packaged fallback.\n---\n\n# Packaged\n",
        encoding="utf-8")
    (skill / "skill.json").write_text(json.dumps({
        "version": 1,
        "run": {"entrypoint": "scripts/missing.py", "packaged": "cli",
                "actions": {"doctor": {"effect": "read", "output": "json",
                                        "argv": ["doctor"], "params": {}}}},
    }), encoding="utf-8")

    result = SkillRunner(SkillsLibrary(root)).run("packaged-skill", "doctor")

    assert result["exit_code"] == 0
    assert result["output"]["command"] == "doctor"


def test_runner_does_not_accept_unknown_action(tmp_path):
    library = make_skill(tmp_path)
    with pytest.raises(SecurityError):
        SkillRunner(library).run("demo-skill", "missing", {})


def test_executor_runs_hardware_controller_virtual_action():
    async def scenario():
        executor = RobotExecutor(
            ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
            skills=SkillsLibrary(ROOT / "skills"), allow_hardware=False)
        try:
            result = await executor.call("run_skill", {
                "skill": "hardware-controller", "action": "run",
                "arguments": {
                    "command": "run",
                    "args": ["--robot", "assets/robots/relay-test.sql",
                             "--input", "assets/scripts/relay-test.mt"],
                },
            }, timeout=30)
        finally:
            await executor.close()
        return result

    result = asyncio.run(scenario())
    assert result["ok"] and result["executed"] and result["state"] == "completed"
    assert result["data"]["output"]["outputs"][-1]["slept"] == 1
    assert "argv" not in result["data"]


def test_executor_timeout_after_skill_start_is_unknown(tmp_path):
    root = tmp_path / "skills"
    skill = root / "slow-skill"
    scripts = skill / "scripts"
    scripts.mkdir(parents=True)
    (skill / "SKILL.md").write_text(
        "---\nname: slow-skill\ndescription: Slow test skill.\n---\n\n# Slow\n", encoding="utf-8")
    (scripts / "slow.py").write_text("import time\ntime.sleep(30)\n")
    (skill / "skill.json").write_text(json.dumps({
        "version": 1,
        "run": {"entrypoint": "scripts/slow.py",
                "actions": {"wait": {"effect": "execute", "output": "json", "argv": ["wait"], "params": {}}}},
    }), encoding="utf-8")

    async def scenario():
        executor = RobotExecutor(
            ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
            skills=SkillsLibrary(root), allow_hardware=False)
        try:
            return await executor.call("run_skill", {
                "skill": "slow-skill", "action": "wait", "arguments": {}}, timeout=0.5)
        finally:
            await executor.close()

    result = asyncio.run(scenario())
    assert not result["ok"] and result["executed"] and result["state"] == "unknown"

def test_executor_grants_hardware_to_trusted_skills(tmp_path):
    library = make_skill(tmp_path, argv=["run"], hardware_flag="--allow-hardware", effect="execute")

    async def scenario():
        executor = RobotExecutor(None, skills=library, workspace_dir=str(tmp_path))
        try:
            return await executor.call(
                "run_skill", {"skill": "demo-skill", "action": "echo"}, timeout=10)
        finally:
            await executor.close()

    result = asyncio.run(scenario())
    assert result["ok"] is True
    assert result["data"]["output"]["argv"] == ["run", "--allow-hardware"]


def test_repository_runnable_skills_declare_existing_entrypoints():
    library = SkillsLibrary(ROOT / "skills", required=True)
    for skill in library.index()["skills"]:
        if not skill["runnable"]:
            continue
        skill_dir = ROOT / "skills" / skill["name"]
        manifest = skill_dir / "skill.json"
        if manifest.is_file():
            document = json.loads(manifest.read_text(encoding="utf-8"))
            run = document["run"]
            entrypoint = Path(run["entrypoint"])
            assert not entrypoint.is_absolute()
            if run.get("packaged") != "cli":
                assert (skill_dir / entrypoint).is_file(), skill["name"]
        else:
            scripts_dir = skill_dir / "scripts"
            assert scripts_dir.is_dir(), f"{skill['name']} has no scripts/ directory"
            py_files = list(scripts_dir.glob("*.py"))
            assert py_files, f"{skill['name']} has no Python scripts"


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="i2c-dev is Linux-only")
def test_i2c_skill_lists_buses_without_hardware():
    result = SkillRunner(SkillsLibrary(ROOT / "skills")).run("i2c-address-probe", "run", {"list": True, "json": True})

    assert result["exit_code"] == 0 and result["output_error"] is None
    assert isinstance(result["output"]["adapters"], list)


def test_hardware_controller_assets_read_and_list():
    runner = SkillRunner(SkillsLibrary(ROOT / "skills"))
    listed = runner.run("hardware-controller", "run",
                        {"command": "assets", "args": ["list", "--kind", "robots"]})
    assert listed["exit_code"] == 0 and listed["output_error"] is None
    assert "relay-test.sql" in listed["output"]["files"]
    read = runner.run("hardware-controller", "run",
                      {"command": "assets",
                       "args": ["read", "--kind", "robots", "--path", "relay-test.sql"]})
    assert read["exit_code"] == 0 and read["output_error"] is None
    assert read["output"]["path"] == "relay-test.sql" and "content" in read["output"]
