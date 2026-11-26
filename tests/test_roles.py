import asyncio
import json
import threading

import pytest

from pymybot.agent_skills import SkillsLibrary
from pymybot.cli import UsageError, parse_args
from pymybot.mcp_client import load_servers
from pymybot.prompts import PromptLibrary
from pymybot.roles import (clear_role_history, create_role, list_roles, load_role,
                           read_history, write_history)
from pymybot.security import SecurityError


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
    assert [item["name"] for item in list_roles(root)] == [role.name]


def test_role_imports_skills_and_mcp(tmp_path):
    skills = tmp_path / "source-skills"
    (skills / "demo" / "references").mkdir(parents=True)
    (skills / "demo" / "SKILL.md").write_text(
        "---\nname: demo\ndescription: Demo skill\n---\n# Demo\n", encoding="utf-8")
    (skills / "demo" / "references" / "guide.md").write_text("guide", encoding="utf-8")
    mcp = tmp_path / "mcp.json"
    mcp.write_text(json.dumps({"mcpServers": {"demo": {
        "command": "python", "args": ["server.py"],
    }}}), encoding="utf-8")

    role = create_role("researcher", skills_from=skills, mcp_from=mcp, root=tmp_path / "roles")
    assert SkillsLibrary(role.skills_dir, required=True).read("demo", "references/guide.md") == "guide"
    assert load_servers(role.mcp_config)[0].name == "demo"
    assert role.info()["skills"] == ["demo"]


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


def test_role_cli_flags():
    args = parse_args(["agent", "--robot", "robot.sql", "--task", "hi", "--role", "demo"])
    assert args.role == "demo"
    args = parse_args(["roles", "create", "demo", "--description", "test"])
    assert args.role_action == "create" and args.name == "demo"
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
    pydantic_ai = pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart, UserPromptPart
    from pydantic_ai.models.function import FunctionModel
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
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.models.function import FunctionModel
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
