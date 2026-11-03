"""Frozen bundles must include every runtime asset, not just the demo files."""
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from bundle_assets import asset_datas  # noqa: E402
from ci_smoke import asset_manifest  # noqa: E402


def test_asset_plan_covers_all_runtime_roots():
    datas = asset_datas(ROOT)
    destinations = {Path(destination).as_posix() for _, destination in datas}
    sources = {Path(source) for source, _ in datas}

    assert "pymybot/assets/prompts" in destinations
    assert "pymybot/assets/modules" in destinations
    assert "pymybot/assets/robots" in destinations
    assert "pymybot/assets/scripts" in destinations
    assert "pymybot/assets/skills" in destinations
    assert "pymybot/gui/assets" in destinations
    assert all(source.is_file() for source in sources)
    assert any(source.name == "skill.json" and "hardware-controller" in source.parts for source in sources)

    suffixes = {source.suffix for source in sources}
    assert {".py", ".lua", ".sql", ".mt", ".md", ".json", ".svg"} <= suffixes
    assert not any(source.name.endswith(".pyc") for source in sources)


def test_ci_manifest_supports_source_and_bundled_layouts(tmp_path):
    source = tmp_path / "source"
    controller = source / "skills" / "hardware-controller" / "assets"
    for directory, filename in (("modules", "demo.lua"), ("robots", "demo.sql"), ("scripts", "demo.mt")):
        (controller / directory).mkdir(parents=True)
        (controller / directory / filename).write_text("return 1", encoding="utf-8")
    (source / "skills" / "demo").mkdir(parents=True)
    (source / "skills" / "demo" / "SKILL.md").write_text("# demo", encoding="utf-8")
    (source / "prompts").mkdir()
    (source / "prompts" / "000.md").write_text("# prompt", encoding="utf-8")

    bundled = tmp_path / "assets"
    shutil.copytree(controller, bundled)
    shutil.copytree(source / "skills" / "demo", bundled / "skills" / "demo")
    shutil.copytree(source / "prompts", bundled / "prompts")

    expected = asset_manifest(source, source_tree=True)
    assert expected == asset_manifest(bundled)
    assert "modules/demo.lua" in expected
    assert "robots/demo.sql" in expected
    assert "scripts/demo.mt" in expected


def test_source_manifest_includes_all_controller_assets():
    manifest = asset_manifest(ROOT, source_tree=True)

    assert any(name.startswith("modules/") and name.endswith(".lua") for name in manifest)
    assert any(name.startswith("robots/") and name.endswith(".sql") for name in manifest)
    assert any(name.startswith("scripts/") and name.endswith(".mt") for name in manifest)
    assert "skills/hardware-controller/skill.json" in manifest