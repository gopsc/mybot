"""Release metadata must agree before a tag can be published."""
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_package_version_is_available_standalone():
    from pymybot import __version__ as root_version

    # pymybot/__init__.py is the single version source now; reading it via runpy
    # must work without importing any runtime module.
    package_init = ROOT / "pymybot" / "__init__.py"
    assert runpy.run_path(str(package_init))["__version__"] == root_version


def test_version_sources_and_changelog_agree():
    check = runpy.run_path(str(ROOT / "tools" / "check_release_metadata.py"))["check"]
    result = check()
    assert result["version"]
    assert result["changelog"] == f"[{result['version']}]"
