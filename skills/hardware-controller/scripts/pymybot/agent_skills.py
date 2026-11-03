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
import secrets
import shutil
import stat

from .paths import asset_path
from .security import SecurityError, checked_text, read_file

MAX_SKILL_FILE = 256 * 1024
MAX_DESCRIPTION = 1024
MAX_LIST = 1000
MAX_SKILL_BYTES = 64 * 1024 * 1024
_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")
_BLOCK_MARKERS = {"|", "|-", "|+", ">", ">-", ">+"}


def default_skills_root():
    """Packaged assets first, else the source tree next to the package."""
    return asset_path("skills")


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
            manifest = entry / "skill.json"
            runnable = (manifest.is_file() and not manifest.is_symlink()
                        and stat.S_ISREG(manifest.stat().st_mode))
            self.skills[entry.name] = {"description": description,
                                       "directory": entry, "files": sorted(files),
                                       "runnable": runnable}
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
        blocks = {}
        active = None
        for index, line in enumerate(lines[1:], 1):
            if line.strip() == "---":
                break
            if not line.strip():
                if active is not None:
                    blocks[active].append("")
                continue
            if line.startswith((" ", "\t")):
                if active is not None:
                    blocks[active].append(line.strip())
                continue
            active = None
            key, separator, value = line.partition(":")
            if not separator:
                continue
            key = key.strip()
            value = value.strip()
            if value in _BLOCK_MARKERS:
                active = key
                blocks.setdefault(key, [])
                continue
            fields.setdefault(key, value)
        else:
            raise SecurityError(f"Skill '{expected}': frontmatter is not closed")
        # The contract keeps name and description on one line, so YAML block
        # scalars are folded instead of rejected.
        for key, parts in blocks.items():
            fields.setdefault(key, " ".join(part for part in parts if part))
        name = fields.get("name", "")
        if name != expected or not _NAME.fullmatch(name):
            raise SecurityError(
                f"Skill '{expected}': frontmatter name '{name}' must match the directory name")
        description = fields.get("description", "")
        if not description or "\n" in description or len(description) > MAX_DESCRIPTION:
            raise SecurityError(f"Skill '{expected}': needs a single-line description"
                                f" of 1..{MAX_DESCRIPTION} characters")
        return description

    def index(self):
        skills = [{"name": name, "description": item["description"], "files": item["files"],
                   "runnable": item["runnable"]}
                  for name, item in sorted(self.skills.items())]
        return {"skills": skills, "truncated": len(skills) == MAX_LIST}

    def install(self, source, *, started=None):
        """Copy one workspace-authored skill tree into this skills root."""
        if self.root is None:
            raise SecurityError("Skills root does not exist")
        source = Path(source)
        try:
            source = source.resolve(strict=True)
        except (OSError, RuntimeError):
            raise SecurityError("Skill source does not exist") from None
        if not source.is_dir():
            raise SecurityError("Skill source must be a directory")
        _no_links(source, source)
        name = source.name
        if not _NAME.fullmatch(name):
            raise SecurityError("Skill name must be 1..64 lowercase letters, digits, '.', '_' or '-'")
        self._frontmatter(source / "SKILL.md", name)
        _no_links(self.root, self.root)
        destination = self.root / name
        if destination.exists():
            raise SecurityError(f"Skill '{name}' already exists")
        staging = self.root / f".{name}.{secrets.token_hex(8)}.tmp"
        try:
            staging.mkdir(mode=0o700)
            files = total = 0
            for base, dirs, names in os.walk(source, followlinks=False):
                base_path = Path(base)
                keep = []
                for item in sorted(dirs):
                    child = base_path / item
                    if item in {"__pycache__", ".git"}:
                        continue
                    if child.is_symlink():
                        raise SecurityError("Linked Skill paths are not allowed")
                    keep.append(item)
                dirs[:] = keep
                for filename in sorted(names):
                    if filename.endswith(".pyc"):
                        continue
                    source_file = base_path / filename
                    info = source_file.lstat()
                    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                        raise SecurityError("Skill files must be regular files")
                    files += 1
                    total += info.st_size
                    if files > MAX_LIST or total > MAX_SKILL_BYTES:
                        raise SecurityError("Skill exceeds the install size limit")
                    target = staging / source_file.relative_to(source)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source_file, target)
                    os.chmod(target, 0o600)
            # Copying into the staging directory is invisible to the skills root;
            # the replace is the first mutation a failed install can leave behind,
            # so report the operation as dispatched only at that point.
            if started is not None:
                started()
            os.replace(staging, destination)
            self._scan()
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        entry = self.skills.get(name)
        return {"name": name, "files": sorted(entry["files"]) if entry else [],
                "runnable": bool(entry and entry["runnable"])}

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
