"""Skills library and agent skill tools: shape checks, sandboxed reads, wiring."""
import asyncio
import os
from pathlib import Path
import sys

import pytest

from pymybot.agent_executor import RobotExecutor
from pymybot.agent_skills import SkillsLibrary
from pymybot.cli import parse_args
from pymybot.security import SecurityError

ROOT = Path(__file__).resolve().parents[1]
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


def test_create_skill_refreshes_empty_library(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    library = SkillsLibrary(root)
    assert not library.enabled
    created = library.create("relay-guide", "Operate relays safely.", "# Relay\n\nUse the approved script.")
    assert created == {"name": "relay-guide", "file": "SKILL.md",
                       "description": "Operate relays safely."}
    assert library.enabled
    assert library.index()["skills"][0]["name"] == "relay-guide"
    content = library.read("relay-guide", "SKILL.md")
    assert "name: relay-guide" in content and "# Relay" in content
    with pytest.raises(SecurityError, match="already exists"):
        library.create("relay-guide", "Duplicate.", "Body")


@pytest.mark.parametrize("name, description, content", [
    ("Bad Name", "Description.", "Body"),
    ("demo-skill", "two\nlines", "Body"),
    ("demo-skill", "Description.", "   "),
])
def test_create_skill_rejects_invalid_documents(tmp_path, name, description, content):
    library = SkillsLibrary(make_root(tmp_path))
    with pytest.raises(SecurityError):
        library.create(name, description, content)


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
        executor = RobotExecutor(robot, module_paths=[ROOT / "modules"], scripts_dir=scripts,
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


def test_executor_creates_skill_in_empty_root(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    robot = tmp_path / "robot.sql"
    robot.write_text(SQL, encoding="utf-8")
    scripts = tmp_path / "scripts"
    scripts.mkdir()

    async def scenario():
        executor = RobotExecutor(robot, module_paths=[ROOT / "modules"], scripts_dir=scripts,
                                 skills=SkillsLibrary(root))
        try:
            created = await executor.call("create_skill", {
                "name": "new-skill", "description": "Created by the agent.", "content": "# New\n\nBody."})
            read = await executor.call("read_skill", {"name": "new-skill"})
            listed = await executor.call("list_skills", {})
        finally:
            await executor.close()
        return created, read, listed

    created, read, listed = asyncio.run(scenario())
    assert created["ok"] is True and created["executed"] is True
    assert read["ok"] is True and "# New" in read["data"]["content"]
    assert [item["name"] for item in listed["data"]["skills"]] == ["new-skill"]


def test_real_repository_skill_loads():
    library = SkillsLibrary(ROOT / "skills")
    assert "pymybot-scripting" in library.skills
    content = library.read("pymybot-scripting", "references/driver-lua.md")
    assert "require_driver" in content
    assert len(library.index()["skills"][0]["files"]) == 7


def test_cli_accepts_skills_dir(tmp_path):
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi", "--skills-dir", str(tmp_path)])
    assert args.skills_dir == str(tmp_path)
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi"])
    assert args.skills_dir is None


def test_make_agent_wires_skills_into_instructions_and_tools():
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.models.test import TestModel

    from pymybot.agent import AgentSession

    library = SkillsLibrary(ROOT / "skills")

    async def scenario(skills):
        executor = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=ROOT / "scripts", skills=skills)
        session = AgentSession(executor, TestModel(custom_output_text="done"), skills=skills)
        try:
            await session.ask("hello")
            return session.prompt_snapshot.text, session.agent
        finally:
            await session.close()

    instructions, agent = asyncio.run(scenario(library))
    without, plain = asyncio.run(scenario(None))
    assert "- pymybot-scripting:" in instructions
    assert "Operator-provided reference skills" in instructions
    assert "Operator-provided reference skills" not in without
    base_tools = ["list_hardware", "list_action_scripts", "query_sql", "run_action_script", "read_prompt", "update_prompt"]
    assert sorted(agent._function_toolset.tools) == sorted(base_tools + ["list_skills", "read_skill", "create_skill"])
    assert sorted(plain._function_toolset.tools) == sorted(base_tools)


def test_create_skill_requires_host_approval(tmp_path):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.models.test import TestModel

    from pymybot.agent import AgentSession

    root = tmp_path / "skills"
    root.mkdir()
    library = SkillsLibrary(root)

    async def scenario():
        executor = RobotExecutor(ROOT / "robots" / "relay-test.sql", scripts_dir=ROOT / "scripts", skills=library)

        async def confirm(name, _arguments):
            return name == "create_skill" and _arguments["name"] == "approved-skill"

        session = AgentSession(executor, TestModel(custom_output_text="done"), skills=library, confirm=confirm)
        try:
            denied = await session.dispatch("create_skill", {
                "name": "denied-skill", "description": "Denied.", "content": "Body"})
            approved = await session.dispatch("create_skill", {
                "name": "approved-skill", "description": "Approved.", "content": "Body"})
        finally:
            await session.close()
        return denied, approved

    denied, approved = asyncio.run(scenario())
    assert denied["ok"] is False and denied["state"] == "not_executed"
    assert approved["ok"] is True and approved["executed"] is True
    assert not (root / "denied-skill").exists()
    assert (root / "approved-skill" / "SKILL.md").is_file()
