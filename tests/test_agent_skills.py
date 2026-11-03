"""Skills library and agent skill tools: shape checks, sandboxed reads, wiring."""
import asyncio
import json
import os
from pathlib import Path
import sys

import pytest

from pymybot.agent_executor import RobotExecutor
from pymybot.agent_skills import SkillsLibrary
from pymybot.cli import parse_args
from pymybot.security import SecurityError

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "hardware-controller" / "assets"
SQL = "CREATE TABLE Relay(name String); INSERT INTO Relay(name) VALUES('r0');\n"
SKILL_MD = "---\nname: demo-skill\ndescription: Demo skill for tests.\n---\n\n# Demo\n\nBody text.\n"
IS_WINDOWS = sys.platform.startswith("win")


def make_root(tmp_path, skill_md=SKILL_MD, extra=None):
    skill = tmp_path / "skills" / "demo-skill"
    (skill / "references").mkdir(parents=True)
    (skill / "SKILL.md").write_text(skill_md, encoding="utf-8")
    (skill / "references" / "a.md").write_text("Reference A", encoding="utf-8")
    if extra:
        extra(skill)
    return tmp_path / "skills"


def test_missing_root_disables_skills(tmp_path):
    library = SkillsLibrary(tmp_path / "nope")
    assert library.enabled is False
    assert library.index() == {"skills": [], "truncated": False}
    with pytest.raises(SecurityError):
        library.read("demo-skill", "SKILL.md")


def test_explicit_missing_root_is_an_error(tmp_path):
    with pytest.raises(SecurityError):
        SkillsLibrary(tmp_path / "nope", required=True)


def test_index_and_read(tmp_path):
    library = SkillsLibrary(make_root(tmp_path))
    assert library.enabled
    index = library.index()
    assert [skill["name"] for skill in index["skills"]] == ["demo-skill"]
    assert index["skills"][0]["files"] == ["SKILL.md", "references/a.md"]
    assert "Body text." in library.read("demo-skill", "SKILL.md")
    assert library.read("demo-skill", "references/a.md") == "Reference A"


def test_install_skill_copies_workspace_tree(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    source = tmp_path / "workspace" / "relay-guide"
    (source / "references").mkdir(parents=True)
    (source / "scripts").mkdir()
    (source / "assets").mkdir()
    (source / "SKILL.md").write_text(
        "---\nname: relay-guide\ndescription: Operate relays safely.\n---\n\n# Relay\n",
        encoding="utf-8")
    (source / "references" / "guide.md").write_text("guide", encoding="utf-8")
    (source / "scripts" / "run.py").write_text("print(1)\n", encoding="utf-8")
    (source / "assets" / "data.txt").write_text("data", encoding="utf-8")
    (source / "skill.json").write_text(json.dumps({
        "version": 1, "run": {"entrypoint": "scripts/run.py", "actions": {
            "echo": {"effect": "read", "output": "json", "argv": []}}}}), encoding="utf-8")
    library = SkillsLibrary(root)
    installed = library.install(source)
    assert installed["name"] == "relay-guide" and installed["runnable"] is True
    assert library.read("relay-guide", "references/guide.md") == "guide"
    assert (root / "relay-guide" / "scripts" / "run.py").is_file()
    assert (root / "relay-guide" / "assets" / "data.txt").read_text(encoding="utf-8") == "data"
    with pytest.raises(SecurityError, match="already exists"):
        library.install(source)


def test_install_skill_rejects_name_mismatch(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    source = tmp_path / "workspace" / "wrong-name"
    source.mkdir(parents=True)
    (source / "SKILL.md").write_text(
        "---\nname: other-name\ndescription: Demo.\n---\n", encoding="utf-8")
    with pytest.raises(SecurityError, match="must match the directory"):
        SkillsLibrary(root).install(source)


def test_frontmatter_rejects_name_mismatch(tmp_path):
    bad = "---\nname: other-skill\ndescription: x.\n---\n"
    with pytest.raises(SecurityError, match="must match the directory"):
        SkillsLibrary(make_root(tmp_path, skill_md=bad))


@pytest.mark.parametrize("skill_md, pattern", [
    ("---\nname: demo-skill\n---\n", "description"),
    ("---\nname: demo-skill\ndescription: " + "x" * 1025 + "\n---\n", "description"),
    ("no frontmatter here\n", "frontmatter"),
    ("---\nname: demo-skill\ndescription: x.\n", "not closed"),
])
def test_frontmatter_validation(tmp_path, skill_md, pattern):
    with pytest.raises(SecurityError, match=pattern):
        SkillsLibrary(make_root(tmp_path, skill_md=skill_md))


def test_frontmatter_uses_bounded_reader(tmp_path, monkeypatch):
    import pymybot.agent_skills as skills_module

    calls = []
    real = skills_module.read_file

    def spy(path, cap=skills_module.MAX_SKILL_FILE):
        calls.append((Path(path), cap))
        return real(path, cap)

    monkeypatch.setattr(skills_module, "read_file", spy)
    assert SkillsLibrary(make_root(tmp_path)).enabled
    assert calls == [(tmp_path / "skills" / "demo-skill" / "SKILL.md",
                      skills_module.MAX_SKILL_FILE)]


def test_skill_md_size_is_bounded(tmp_path):
    import pymybot.agent_skills as skills_module

    root = make_root(tmp_path)
    with (root / "demo-skill" / "SKILL.md").open("ab") as stream:
        stream.write(b"x" * skills_module.MAX_SKILL_FILE)
    with pytest.raises(SecurityError, match="limit"):
        SkillsLibrary(root)


def test_directory_without_skill_md_is_an_error(tmp_path):
    root = tmp_path / "skills"
    (root / "empty-skill").mkdir(parents=True)
    with pytest.raises(SecurityError, match="no readable SKILL.md"):
        SkillsLibrary(root)


def test_hidden_directories_are_skipped(tmp_path):
    root = make_root(tmp_path)
    (root / ".hidden").mkdir()
    (root / ".hidden" / "SKILL.md").write_text("---\nname: hidden\ndescription: x.\n---\n", encoding="utf-8")
    assert [skill["name"] for skill in SkillsLibrary(root).index()["skills"]] == ["demo-skill"]


@pytest.mark.parametrize("file", ["../escape.md", "/etc/passwd.md", "a/../../x.md",
                                  "back\\slash.md", "col:on.md", "SKILL.txt", "", ".md"])
def test_read_rejects_unsafe_paths(tmp_path, file):
    library = SkillsLibrary(make_root(tmp_path))
    with pytest.raises(SecurityError):
        library.read("demo-skill", file)


def test_read_rejects_unknown_skill_and_unscanned_file(tmp_path):
    library = SkillsLibrary(make_root(tmp_path, extra=lambda skill: (skill / "notes.txt").write_text("x", encoding="utf-8")))
    with pytest.raises(SecurityError, match="Unknown skill"):
        library.read("nope", "SKILL.md")
    with pytest.raises(SecurityError):
        library.read("demo-skill", "notes.txt")


@pytest.mark.skipif(IS_WINDOWS, reason="symlink permission")
def test_read_rejects_symlinked_reference(tmp_path):
    def extra(skill):
        (skill / "linked.md").symlink_to(skill / "references" / "a.md")
    library = SkillsLibrary(make_root(tmp_path, extra=extra))
    with pytest.raises(SecurityError):
        library.read("demo-skill", "linked.md")


@pytest.mark.skipif(IS_WINDOWS, reason="symlink permission")
def test_scan_rejects_symlinked_skill_directory(tmp_path):
    root = make_root(tmp_path)
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "elsewhere" / "SKILL.md").write_text("---\nname: linked\ndescription: x.\n---\n", encoding="utf-8")
    (root / "linked-skill").symlink_to(tmp_path / "elsewhere")
    with pytest.raises(SecurityError, match="Linked paths"):
        SkillsLibrary(root)


def executor_case(tmp_path, skills):
    robot = tmp_path / "robot.sql"
    robot.write_text(SQL, encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()

    async def scenario():
        executor = RobotExecutor(robot, module_paths=[ASSETS / "modules"], scripts_dir=scripts,
                                 skills=skills)
        try:
            listed = await executor.call("list_skills", {})
            read = await executor.call("read_skill", {"name": "demo-skill"})
            read_ref = await executor.call("read_skill", {"name": "demo-skill", "file": "references/a.md"})
            escape = await executor.call("read_skill", {"name": "demo-skill", "file": "../x.md"})
            unknown = await executor.call("read_skill", {"name": "ghost"})
        finally:
            await executor.close()
        return listed, read, read_ref, escape, unknown

    return asyncio.run(scenario())


def test_executor_skill_tools(tmp_path):
    listed, read, read_ref, escape, unknown = executor_case(tmp_path, SkillsLibrary(make_root(tmp_path)))
    assert listed["ok"] is True and listed["executed"] is False
    assert listed["data"]["skills"][0]["name"] == "demo-skill"
    assert read["ok"] is True and "Body text." in read["data"]["content"]
    assert read_ref["data"]["content"] == "Reference A"
    assert escape["ok"] is False and escape["state"] == "not_executed"
    assert unknown["ok"] is False and unknown["state"] == "not_executed"


def test_executor_skills_disabled(tmp_path):
    listed, read = executor_case(tmp_path, None)[:2]
    assert listed["ok"] is False and listed["state"] == "not_executed"
    assert read["ok"] is False and read["state"] == "not_executed"


def test_executor_installs_workspace_skill(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    robot = tmp_path / "robot.sql"
    robot.write_text(SQL, encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    source = tmp_path / "new-skill"
    source.mkdir()
    (source / "SKILL.md").write_text(
        "---\nname: new-skill\ndescription: Created by the agent.\n---\n\n# New\n\nBody.\n",
        encoding="utf-8")

    async def scenario():
        executor = RobotExecutor(robot, module_paths=[ASSETS / "modules"], scripts_dir=scripts,
                                 skills=SkillsLibrary(root), workspace_dir=tmp_path)
        try:
            created = await executor.call("install_skill", {"path": "new-skill"}, timeout=5)
            read = await executor.call("read_skill", {"name": "new-skill"})
            listed = await executor.call("list_skills", {})
        finally:
            await executor.close()
        return created, read, listed

    created, read, listed = asyncio.run(scenario())
    assert created["ok"] is True and created["executed"] is True
    assert created["data"]["runnable"] is False
    assert read["ok"] is True and "# New" in read["data"]["content"]
    assert [item["name"] for item in listed["data"]["skills"]] == ["new-skill"]


def test_real_repository_skill_loads():
    library = SkillsLibrary(ROOT / "skills")
    assert "pymybot-scripting" in library.skills
    content = library.read("pymybot-scripting", "references/driver-lua.md")
    assert "require_driver" in content
    entries = {item["name"]: item for item in library.index()["skills"]}
    assert len(entries["pymybot-scripting"]["files"]) == 7
    assert len(entries["hardware-controller"]["files"]) == 6


def test_cli_accepts_skills_dir(tmp_path):
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi", "--skills-dir", str(tmp_path)])
    assert args.skills_dir == str(tmp_path)
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi"])
    assert args.skills_dir is None


def test_make_agent_wires_skills_into_instructions_and_tools(tmp_path):
    pytest.importorskip("langchain")
    from agent_fakes import TestModel

    from pymybot.agent import AgentSession

    library = SkillsLibrary(ROOT / "skills")

    async def scenario(skills):
        executor = RobotExecutor(ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
                                 skills=skills, workspace_dir=tmp_path)
        session = AgentSession(executor, TestModel(custom_output_text="done"), skills=skills,
                               workspace=True)
        try:
            await session.ask("hello")
            return session.prompt_snapshot.text, session.tools
        finally:
            await session.close()

    instructions, tools = asyncio.run(scenario(library))
    without, plain = asyncio.run(scenario(None))
    assert "- pymybot-scripting:" in instructions
    assert "- skill-authoring:" in instructions
    assert "Operator-provided reference skills" in instructions
    assert "Operator-provided reference skills" not in without
    assert "install_skill(path)" in instructions
    assert "install_skill(path)" in without
    assert "Skills are trusted operator content" in instructions
    assert "run_skill executes declared actions without approval" in instructions
    assert "runnable via run_skill" in instructions
    names = {tool.name for tool in tools}
    assert {"list_skills", "read_skill", "install_skill", "run_skill"} <= names
    assert "install_skill" not in {tool.name for tool in plain}


def test_skill_authoring_reads_reference_before_install(tmp_path):
    pytest.importorskip("langchain")
    from agent_fakes import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
    from agent_fakes import FunctionModel

    from pymybot.agent import AgentConfig, AgentSession

    root = tmp_path / "skills"
    meta = root / "skill-authoring"
    meta.mkdir(parents=True)
    (meta / "SKILL.md").write_text(
        "---\nname: skill-authoring\ndescription: Create reusable skills.\n---\n\n"
        "Read the references before creating a skill.\n", encoding="utf-8")
    source = tmp_path / "created-by-agent"
    source.mkdir()
    (source / "SKILL.md").write_text(
        "---\nname: created-by-agent\ndescription: Created.\n---\n\nBody.\n",
        encoding="utf-8")
    library = SkillsLibrary(root)
    seen, approvals = [], []

    async def confirm(name, arguments):
        approvals.append((name, arguments["path"]))
        return name == "install_skill"

    async def respond(messages, info):
        seen.append(str(info.instructions))
        returns = [part for message in messages for part in message.parts
                   if isinstance(part, ToolReturnPart)]
        if not returns:
            return ModelResponse(parts=[ToolCallPart("list_skills", {})])
        if len(returns) == 1:
            return ModelResponse(parts=[ToolCallPart("read_skill", {"name": "skill-authoring"})])
        if len(returns) == 2:
            return ModelResponse(parts=[ToolCallPart("install_skill", {"path": "created-by-agent"})])
        return ModelResponse(parts=[TextPart("done")])

    async def scenario():
        executor = RobotExecutor(ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
                                 skills=library, workspace_dir=tmp_path)
        session = AgentSession(executor, FunctionModel(respond),
                               AgentConfig(intent_mode="author"), skills=library,
                               workspace=True, confirm=confirm)
        try:
            return await session.ask("创建一个技能")
        finally:
            await session.close()

    result = asyncio.run(scenario())
    assert result["output"] == "done"
    assert "install_skill(path)" in seen[0]
    assert "- skill-authoring:" in seen[0]
    assert approvals == [("install_skill", "created-by-agent")]
    assert (root / "created-by-agent" / "SKILL.md").is_file()


def test_workspace_authors_and_installs_a_skill(tmp_path):
    pytest.importorskip("langchain")

    workspace = tmp_path / "workspace"
    workspace.mkdir()
    skills = tmp_path / "skills"
    skills.mkdir()
    (workspace / "approved" / "references").mkdir(parents=True)

    async def scenario():
        executor = RobotExecutor(ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
                                 skills=SkillsLibrary(skills), workspace_dir=workspace)
        try:
            written = await executor.call("write_file", {
                "path": "approved/SKILL.md",
                "content": "---\nname: approved\ndescription: Approved.\n---\n\nBody."}, timeout=5)
            reference = await executor.call("write_file", {
                "path": "approved/references/guide.md", "content": "guide"}, timeout=5)
            installed = await executor.call("install_skill", {"path": "approved"}, timeout=5)
        finally:
            await executor.close()
        return written, reference, installed

    written, reference, installed = asyncio.run(scenario())
    assert written["ok"] and reference["ok"]
    assert (workspace / "approved" / "references" / "guide.md").read_text(encoding="utf-8") == "guide"
    assert installed["ok"] is True and installed["executed"] is True
    assert (skills / "approved" / "SKILL.md").is_file()
    assert (skills / "approved" / "references" / "guide.md").read_text(encoding="utf-8") == "guide"


def test_install_skill_requires_host_approval(tmp_path):
    pytest.importorskip("langchain")
    from agent_fakes import TestModel

    from pymybot.agent import AgentSession

    root = tmp_path / "skills"
    root.mkdir()
    library = SkillsLibrary(root)
    workspace = tmp_path / "workspace"
    for name in ("denied-skill", "approved-skill"):
        target = workspace / name
        target.mkdir(parents=True)
        (target / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: Demo.\n---\n\nBody.\n", encoding="utf-8")

    async def scenario():
        executor = RobotExecutor(ASSETS / "robots" / "relay-test.sql", scripts_dir=ASSETS / "scripts",
                                 skills=library, workspace_dir=workspace)

        async def confirm(name, arguments):
            return name == "install_skill" and arguments["path"] == "approved-skill"

        session = AgentSession(executor, TestModel(custom_output_text="done"), skills=library,
                               workspace=True, confirm=confirm)
        try:
            denied = await session.dispatch("install_skill", {"path": "denied-skill"})
            approved = await session.dispatch("install_skill", {"path": "approved-skill"})
        finally:
            await session.close()
        return denied, approved

    denied, approved = asyncio.run(scenario())
    assert denied["ok"] is False and denied["state"] == "not_executed"
    assert approved["ok"] is True and approved["executed"] is True
    assert not (root / "denied-skill").exists()
    assert (root / "approved-skill" / "SKILL.md").is_file()


def test_skill_runner_string_arguments_are_bounded(tmp_path):
    from pymybot.agent_skill_runner import SkillRunner

    root = tmp_path / "skills"
    skill = root / "echo"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text(
        "---\nname: echo\ndescription: Echo text.\n---\n\n# Echo\n", encoding="utf-8")
    (skill / "skill.json").write_text(json.dumps({
        "version": 1,
        "run": {
            "entrypoint": "run.py",
            "actions": {
                "echo": {"effect": "read", "output": "json", "argv": ["{text}"],
                         "params": {"text": {"type": "string", "max": 8, "required": True}}},
                "default": {"effect": "read", "output": "json", "argv": ["{text}"],
                            "params": {"text": {"type": "string", "max": 8, "default": "fallback"}}},
            },
        },
    }), encoding="utf-8")
    (skill / "run.py").write_text(
        "import json, sys\nprint(json.dumps({'text': sys.argv[1]}))\n", encoding="utf-8")
    runner = SkillRunner(SkillsLibrary(root))
    assert runner.run("echo", "echo", {"text": "hello"})["output"] == {"text": "hello"}
    assert runner.run("echo", "default", {})["output"] == {"text": "fallback"}
    assert runner.run("echo", "echo", {"text": "123456789"})["output"] == {"text": "123456789"}


def test_robotless_executor_runs_generic_and_skill_tools(tmp_path):
    skills = SkillsLibrary(ROOT / "skills")

    async def scenario():
        executor = RobotExecutor(None, skills=skills, workspace_dir=str(tmp_path))
        try:
            context = await executor.start()
            assert "robot" not in context and context["hardware"] == []
            scripts = await executor.call(
                "run_skill", {"skill": "hardware-controller", "action": "scripts"}, timeout=60)
            assert scripts["ok"] and scripts["data"]["output"]["scripts"]
            hardware = await executor.call("run_skill", {
                "skill": "hardware-controller", "action": "hardware",
                "arguments": {"robot": {"scope": "skill_assets", "path": "robots/relay-test.sql"}},
            }, timeout=60)
            assert hardware["ok"] and hardware["data"]["output"]["hardware"]
            query = await executor.call("run_skill", {
                "skill": "hardware-controller", "action": "query",
                "arguments": {"robot": {"scope": "skill_assets", "path": "robots/relay-test.sql"},
                              "sql": "SHOW TABLES;"},
            }, timeout=60)
            assert query["ok"] and "SHOW TABLES" in query["data"]["output"]["output"]
            listing = await executor.call("list_files", {"path": "."}, timeout=10)
            assert listing["state"] == "completed"
            blocked = await executor.call("query_sql", {"sql": "SHOW TABLES;"}, timeout=10)
            assert blocked["state"] == "not_executed"
        finally:
            await executor.close()

    asyncio.run(scenario())
