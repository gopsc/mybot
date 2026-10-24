"""Operator-curated reference skills for the optional agent frontend.

A skills root holds one directory per skill. Each skill carries a SKILL.md
with a '---'-delimited frontmatter block (name, description) plus optional
markdown reference files. Skills are trusted operator content with the same
standing as the scripts root: this loader enforces shape and sandboxed reads,
never content. A missing root only disables skills when it was not explicitly
requested; an explicit root that cannot be loaded is an operator error.
"""
from __future__ import annotations

import os
import re
from pathlib import Path, PureWindowsPath
import stat

from .security import SecurityError, checked_text, read_file

MAX_SKILL_FILE = 256 * 1024
MAX_DESCRIPTION = 1024
MAX_LIST = 1000
_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")


def default_skills_root():
    """Packaged assets first, else the source tree next to the package."""
    package = Path(__file__).resolve().parent
    packaged = package / "assets" / "skills"
    return packaged if packaged.is_dir() else package.parent / "skills"


def _relative_markdown(value):
    checked_text(value)
    win = PureWindowsPath(value)
    if (not value or win.drive or win.root or value.startswith("/")
            or "\\" in value or ":" in value
            or any(part in {"", ".", ".."} for part in value.split("/"))
            or not value.endswith(".md")):
        raise SecurityError("Expected a relative .md path inside the skill")
    return value


def _no_links(path, root):
    # Same rule as the scripts root, checked for every segment down to the
    # skill directory. FILE_ATTRIBUTE_REPARSE_POINT also catches junctions.
    try:
        for part in (path, *path.parents):
            if part == root.parent:
                break
            info = part.lstat()
            if (stat.S_ISLNK(info.st_mode)
                    or getattr(info, "st_file_attributes", 0) & 0x400
                    or getattr(part, "is_junction", lambda: False)()):
                raise SecurityError("Linked paths are not allowed")
    except OSError as exc:
        raise SecurityError("Cannot inspect skill path") from exc


class SkillsLibrary:
    """Static snapshot of one skills root; reads stay inside a skill directory."""

    def __init__(self, directory, *, required=False):
        self.root = None
        self.skills: dict[str, dict] = {}
        path = Path(directory) if directory is not None else None
        if path is None:
            return
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError):
            if required:
                raise SecurityError("Skills root does not exist") from None
            return
        if not resolved.is_dir():
            raise SecurityError("Skills root must be a directory")
        _no_links(resolved, resolved)
        self.root = resolved
        self._scan()

    @property
    def enabled(self):
        return bool(self.skills)

    def _scan(self):
        def walk_error(error):
            raise error

        for entry in sorted(self.root.iterdir(), key=lambda item: item.name):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            _no_links(entry, self.root)
            description = self._frontmatter(entry / "SKILL.md", entry.name)
            files = []
            for base, dirs, names in os.walk(entry, followlinks=False, onerror=walk_error):
                dirs[:] = sorted(name for name in dirs if not (Path(base) / name).is_symlink())
                for name in sorted(names):
                    path = Path(base) / name
                    if (path.suffix == ".md" and not path.is_symlink()
                            and stat.S_ISREG(path.stat().st_mode)):
                        files.append(path.relative_to(entry).as_posix())
                    if len(files) > MAX_LIST:
                        raise SecurityError("Skill exceeds the file count limit")
            if not files:
                raise SecurityError(f"Skill '{entry.name}' has no SKILL.md")
            self.skills[entry.name] = {"description": description,
                                       "directory": entry, "files": sorted(files)}
            if len(self.skills) > MAX_LIST:
                raise SecurityError("Skills root exceeds the skill count limit")

    def _frontmatter(self, path, expected):
        try:
            text = read_file(path, MAX_SKILL_FILE)
        except OSError as exc:
            raise SecurityError(f"Skill '{expected}' has no readable SKILL.md") from exc
        except UnicodeDecodeError as exc:
            raise SecurityError(f"Skill '{expected}': SKILL.md is not UTF-8") from exc
        except SecurityError as exc:
            raise SecurityError(f"Skill '{expected}': {exc}") from exc
        lines = text.split("\n")
        if not lines or lines[0].strip() != "---":
            raise SecurityError(f"Skill '{expected}': SKILL.md must start with frontmatter")
        fields = {}
        for index, line in enumerate(lines[1:], 1):
            if line.strip() == "---":
                break
            key, separator, value = line.partition(":")
            if separator and not line.startswith((" ", "\t")):
                fields.setdefault(key.strip(), value.strip())
        else:
            raise SecurityError(f"Skill '{expected}': frontmatter is not closed")
        name = fields.get("name", "")
        if name != expected or not _NAME.fullmatch(name):
            raise SecurityError(f"Skill '{expected}': frontmatter name must match the directory")
        description = fields.get("description", "")
        if not description or "\n" in description or len(description) > MAX_DESCRIPTION:
            raise SecurityError(f"Skill '{expected}': needs a single-line description"
                                f" of 1..{MAX_DESCRIPTION} characters")
        return description

    def index(self):
        skills = [{"name": name, "description": item["description"], "files": item["files"]}
                  for name, item in sorted(self.skills.items())]
        return {"skills": skills, "truncated": len(skills) == MAX_LIST}

    def read(self, name, file):
        checked_text(name)
        entry = self.skills.get(name)
        if entry is None:
            raise SecurityError(f"Unknown skill '{name[:120]}'")
        relative = _relative_markdown(file)
        path = entry["directory"].joinpath(*relative.split("/"))
        _no_links(path, entry["directory"])
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError):
            raise SecurityError("Skill file does not exist") from None
        if not resolved.is_relative_to(entry["directory"]) or not stat.S_ISREG(resolved.stat().st_mode):
            raise SecurityError("Skill file must be a regular file inside the skill")
        if relative not in entry["files"]:
            raise SecurityError("Skill file was not part of the scanned skill")
        return read_file(resolved, MAX_SKILL_FILE)
