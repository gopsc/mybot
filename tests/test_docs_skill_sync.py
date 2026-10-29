import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("check_docs_skill_sync", ROOT / "tools" / "check_docs_skill_sync.py")
sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync)

SHARED = "\n".join(f"a documented sentence number {index} that is long enough to compare" for index in range(8))


def build(root, *, body="", source=True, register=True, skill="# Skill\n", docs="# Architecture\n"):
    (root / "docs").mkdir()
    (root / "docs" / "architecture.md").write_text(docs, encoding="utf-8")
    skills = root / "skills"
    references = skills / "pymybot-scripting" / "references"
    references.mkdir(parents=True)
    (skills / "README.md").write_text(
        "# Skills\n\n" + ("[sql](pymybot-scripting/references/sql.md)\n" if register else ""), encoding="utf-8")
    (skills / "pymybot-scripting" / "SKILL.md").write_text(skill, encoding="utf-8")
    header = "Source: [docs/architecture.md](../../../docs/architecture.md)\n" if source else "# sql\n"
    (references / "sql.md").write_text(header + body, encoding="utf-8")
    return references / "sql.md"


def test_repository_is_in_sync():
    problems, _ = sync.audit(ROOT)
    assert problems == []


def test_dead_link_is_a_problem(tmp_path):
    build(tmp_path, body="见 [docs/missing.md](../../../docs/missing.md)\n")
    problems, _ = sync.audit(tmp_path)
    assert problems == ["skills/pymybot-scripting/references/sql.md: link target does not exist: ../../../docs/missing.md"]


def test_missing_repository_path_is_a_problem(tmp_path):
    build(tmp_path, body="驱动 `modules/NoSuchDriver.lua` 与占位符 `modules/<表名>.py`\n")
    problems, _ = sync.audit(tmp_path)
    assert problems == ["skills/pymybot-scripting/references/sql.md:"
                        " referenced path does not exist: modules/NoSuchDriver.lua"]


def test_brace_groups_are_expanded(tmp_path):
    build(tmp_path, body="实现 `docs/{architecture,missing}.md`\n")
    problems, _ = sync.audit(tmp_path)
    assert problems == ["skills/pymybot-scripting/references/sql.md: referenced path does not exist: docs/missing.md"]


def test_reference_needs_a_source_declaration(tmp_path):
    build(tmp_path, source=False)
    problems, _ = sync.audit(tmp_path)
    assert any("needs a 'Source:' line" in problem for problem in problems)


def test_reference_must_be_registered_in_the_index(tmp_path):
    build(tmp_path, register=False)
    problems, _ = sync.audit(tmp_path)
    assert any("not registered in the skills/README.md mapping table" in problem for problem in problems)


def test_oversized_skill_md_is_a_problem(tmp_path):
    build(tmp_path, skill="# Skill\n" + "line\n" * sync.MAX_SKILL_LINES)
    problems, _ = sync.audit(tmp_path)
    assert any("exceeds" in problem for problem in problems)


def test_verbatim_run_only_warns(tmp_path):
    build(tmp_path, body=SHARED, docs="# Architecture\n" + SHARED)
    problems, warnings = sync.audit(tmp_path)
    assert problems == []
    assert any("docs/architecture.md" in warning and "summarise and link" in warning for warning in warnings)


def test_main_reports_the_repository_as_clean(capsys):
    assert sync.main([]) == 0
    assert "ok" in capsys.readouterr().out
