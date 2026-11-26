"""Frozen bundles must include every runtime asset, not just the demo files."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from bundle_assets import asset_datas  # noqa: E402


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

    suffixes = {source.suffix for source in sources}
    assert {".py", ".lua", ".sql", ".mt", ".md", ".json", ".svg"} <= suffixes
    assert not any(source.name.endswith(".pyc") for source in sources)
