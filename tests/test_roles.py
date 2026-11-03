import asyncio
import json
import shutil
import threading
from pathlib import Path

import pytest

from pymybot.agent_skills import SkillsLibrary
from pymybot.cli import UsageError, parse_args
from pymybot.mcp_client import load_servers
from pymybot.prompts import PromptLibrary
from pymybot.roles import (clear_role_history, create_role, list_roles, load_role,
                           read_history, repair_role_skills, write_history)
from pymybot.security import SecurityError

ROOT = Path(__file__).resolve().parents[1]


def test_role_uses_bundled_prompt_baseline_without_touching_global(tmp_path):
    root = tmp_path / "roles"
    role = create_role("维修工程师", description="现场诊断", root=root)
    assert role.root == root / "维修工程师"
    assert role.prompt_library().compose().text == PromptLibrary(
        home=tmp_path / "global", defaults=role.prompt_library().defaults).compose().text

    role.prompt_library().update("97", "# SOUL\n\n谨慎、先诊断。", actor="operator")
    global_library = PromptLibrary(home=tmp_path / "global", defaults=role.prompt_library().defaults)
    global_library.ensure_home()
    assert global_library.read("97")["content"] == ""
    assert "谨慎、先诊断" in role.prompt_library().read("97")["content"]

    info = load_role(role.name, root).info()
    assert info["description"] == "现场诊断"
    assert info["history_turns"] == 0 and info["mcp_config"] is None
    assert role.workspace_dir.is_dir() and info["workspace_dir"] == str(role.workspace_dir)
    assert [item["name"] for item in list_roles(root)] == [role.name]


def test_role_imports_skills_and_mcp(tmp_path):
    skills = tmp_path / "source-skills"
    (skills / "demo" / "references").mkdir(parents=True)
    (skills / "demo" / "SKILL.md").write_text(
        "---\nname: demo\ndescription: Demo skill\n---\n# Demo\n", encoding="utf-8")
    (skills / "demo" / "references" / "guide.md").write_text("guide", encoding="utf-8")
    (skills / "demo" / "skill.json").write_text(json.dumps({
        "version": 1, "run": {"entrypoint": "scripts/run.py", "actions": {
            "echo": {"effect": "read", "output": "json", "argv": []}}}}), encoding="utf-8")
    (skills / "demo" / "scripts").mkdir()
    (skills / "demo" / "scripts" / "run.py").write_text("print(1)\n", encoding="utf-8")
    (skills / "demo" / "assets").mkdir()
    (skills / "demo" / "assets" / "data.txt").write_text("data", encoding="utf-8")
    mcp = tmp_path / "mcp.json"
    mcp.write_text(json.dumps({"mcpServers": {"demo": {
        "command": "python", "args": ["server.py"],
    }}}), encoding="utf-8")

    role = create_role("researcher", skills_from=skills, mcp_from=mcp, root=tmp_path / "roles")
    copied = SkillsLibrary(role.skills_dir, required=True)
    assert copied.read("demo", "references/guide.md") == "guide"
    assert copied.skills["demo"]["runnable"] is True
    assert (role.skills_dir / "demo" / "scripts" / "run.py").is_file()
    assert (role.skills_dir / "demo" / "assets" / "data.txt").read_text(encoding="utf-8") == "data"
    assert load_servers(role.mcp_config)[0].name == "demo"
    assert role.info()["skills"] == ["demo"]


def test_load_role_repairs_a_missing_workspace(tmp_path):
    root = tmp_path / "roles"
    role = create_role("legacy", root=root)
    role.workspace_dir.rmdir()
    loaded = load_role("legacy", root)
    assert loaded.workspace_dir.is_dir()


def test_role_validation_and_history_clear(tmp_path):
    root = tmp_path / "roles"
    role = create_role("demo", root=root)
    with pytest.raises(SecurityError):
        create_role("demo", root=root)
    with pytest.raises(SecurityError):
        create_role("../escape", root=root)

    write_history(role.history_file, [{"serialized": "turn"}])
    assert read_history(role.history_file) == [{"serialized": "turn"}]
    assert clear_role_history("demo", root)["history_turns"] == 0
    assert read_history(role.history_file) == []


def test_legacy_pydanticai_history_is_ignored(tmp_path):
    role = create_role("legacy", root=tmp_path / "roles")
    role.history_file.write_text(
        json.dumps({"version": 1, "turns": [[{"kind": "request"}]]}), encoding="utf-8")
    assert read_history(role.history_file) == []
    role.history_file.write_text(
        json.dumps({"version": 3, "turns": []}), encoding="utf-8")
    with pytest.raises(SecurityError):
        read_history(role.history_file)


def test_role_cli_flags():
    args = parse_args(["agent", "--robot", "robot.sql", "--task", "hi", "--role", "demo"])
    assert args.role == "demo"
    args = parse_args(["roles", "create", "demo", "--description", "test"])
    assert args.role_action == "create" and args.name == "demo"
    args = parse_args(["roles", "repair", "demo", "--yes"])
    assert args.role_action == "repair" and args.yes is True
    with pytest.raises(UsageError):
        parse_args(["agent", "--robot", "robot.sql", "--task", "hi",
                    "--role", "demo", "--skills-dir", "skills"])


class _Executor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.events = []

    async def start(self, *, deadline=None):
        return {"robot": "test", "hardware": []}

    async def call(self, name, arguments, *, timeout):
        raise AssertionError("No tool expected")

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        pass


def test_role_history_reopens_and_clears(tmp_path):
    pytest.importorskip("langchain")
    from agent_fakes import ModelResponse, TextPart, UserPromptPart
    from agent_fakes import FunctionModel
    from pymybot.agent import AgentConfig, AgentSession

    role = create_role("memory", root=tmp_path / "roles")
    role.prompt_library().update("97", "# SOUL\n\nROLE-PERSONA", actor="operator")

    async def first_model(messages, info):
        assert "ROLE-PERSONA" in str(info.instructions)
        return ModelResponse(parts=[TextPart("first answer")])

    async def first_turn():
        session = AgentSession(_Executor(), FunctionModel(first_model),
                               AgentConfig(auto_stats=False), role=role)
        try:
            assert (await session.ask("remember this"))["role"] == "memory"
        finally:
            await session.close()

    asyncio.run(first_turn())
    assert len(read_history(role.history_file)) == 1
    seen = []

    async def second_model(messages, info):
        seen.extend(messages)
        return ModelResponse(parts=[TextPart("second answer")])

    async def second_turn():
        session = AgentSession(_Executor(), FunctionModel(second_model),
                               AgentConfig(auto_stats=False), role=role)
        try:
            await session.ask("continue")
            assert len(session.turns) == 2
            session.clear_history()
            assert read_history(role.history_file) == []
        finally:
            await session.close()

    asyncio.run(second_turn())
    prompts = [part.content for message in seen for part in message.parts
               if isinstance(part, UserPromptPart) and isinstance(part.content, str)]
    assert prompts.count("remember this") == 1 and prompts.count("continue") == 1


def test_corrupt_or_failed_role_history_does_not_reach_model(tmp_path):
    pytest.importorskip("langchain")
    from agent_fakes import FunctionModel
    from pymybot.agent import AgentConfigurationError, AgentSession

    role = create_role("broken", root=tmp_path / "roles")
    role.history_file.write_text("not-json", encoding="utf-8")
    called = []

    async def model(messages, info):
        called.append(True)
        raise AssertionError("Must not request model")

    with pytest.raises(AgentConfigurationError):
        AgentSession(_Executor(), FunctionModel(model), role=role)
    assert called == []


def test_role_info_flags_and_repair_restores_incomplete_skills(tmp_path):
    root = tmp_path / "roles"
    role = create_role("broken", skills_from=ROOT / "skills", root=root)
    controller = role.skills_dir / "hardware-controller"
    marker = controller / "SKILL.md"
    marker.write_text(marker.read_text(encoding="utf-8") + "\n<!-- operator edit -->\n",
                      encoding="utf-8")
    (controller / "skill.json").unlink()
    shutil.rmtree(controller / "scripts")

    info = load_role("broken", root).info()
    assert "hardware-controller" not in info["runnable"]
    assert "hardware-controller" in info["incomplete"]

    result = repair_role_skills("broken", source=ROOT / "skills", root=root)
    assert "hardware-controller" in result["repaired"]
    assert (controller / "skill.json").is_file()
    assert (controller / "scripts" / "hardware_controller.py").is_file()
    assert "<!-- operator edit -->" in marker.read_text(encoding="utf-8")
    fixed = load_role("broken", root).info()
    assert "hardware-controller" in fixed["runnable"] and not fixed["incomplete"]


def test_create_role_rejects_manifest_without_entrypoint(tmp_path):
    source = tmp_path / "source" / "demo"
    source.mkdir(parents=True)
    (source / "SKILL.md").write_text(
        "---\nname: demo\ndescription: Demo.\n---\n", encoding="utf-8")
    (source / "skill.json").write_text(json.dumps({
        "version": 1,
        "run": {"entrypoint": "scripts/run.py", "actions": {"go": {"argv": []}}},
    }), encoding="utf-8")

    with pytest.raises(SecurityError, match="entrypoint"):
        create_role("bad", skills_from=source.parent, root=tmp_path / "roles")
