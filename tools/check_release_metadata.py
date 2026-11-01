"""Fail when version sources disagree or the changelog has no current section."""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def check(root=ROOT):
    root = Path(root)
    project = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))
    version = project["project"]["version"]
    module = re.search(r'^__version__ = "([^"]+)"', (root / "pymybot" / "__init__.py").read_text(encoding="utf-8"),
                       re.MULTILINE)
    citation = re.search(r"^version:\s*([^\s]+)\s*$", (root / "CITATION.cff").read_text(encoding="utf-8"),
                         re.MULTILINE)
    if module is None or citation is None:
        raise AssertionError("Cannot read pymybot.__version__ or CITATION.cff version")
    if module.group(1) != version:
        raise AssertionError(f"pymybot.__version__ {module.group(1)} != pyproject {version}")
    if citation.group(1) != version:
        raise AssertionError(f"CITATION.cff {citation.group(1)} != pyproject {version}")

    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    if re.search(r"^## \[Unreleased\]\s*$", changelog, re.MULTILINE) is None:
        raise AssertionError("CHANGELOG.md has no [Unreleased] section")
    if re.search(rf"^## \[{re.escape(version)}\](?:\s|$)", changelog, re.MULTILINE) is None:
        raise AssertionError(f"CHANGELOG.md has no section for {version}")
    return {"version": version, "changelog": f"[{version}]"}


def main():
    try:
        result = check()
    except (AssertionError, OSError, KeyError, tomllib.TOMLDecodeError) as exc:
        print(f"release metadata: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
