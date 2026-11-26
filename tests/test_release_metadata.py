"""Release metadata must agree before a tag can be published."""
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_version_sources_and_changelog_agree():
    check = runpy.run_path(str(ROOT / "tools" / "check_release_metadata.py"))["check"]
    result = check()
    assert result["version"]
    assert result["changelog"] == f"[{result['version']}]"
