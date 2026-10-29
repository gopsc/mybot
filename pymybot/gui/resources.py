"""Read-only resource index and content cache for the GUI preview pane.

This is an operator browser, not an execution path: action scripts still run
through ``serve`` and the agent executor. Listings mirror the backend rules
(regular files only, no links) and reads are bounded by ``security.read_file``.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import stat

from ..agent_skills import SkillsLibrary
from ..paths import source_root
from ..security import SecurityError, read_file

MAX_PREVIEW = 1024 * 1024
MAX_DOCS = 200
GROUPS = ("脚本", "技能", "文档")


@dataclass(frozen=True)
class Resource:
    group: str
    name: str
    path: str
    language: str
    size: int


def _walk_markdown(root):
    results = []
    if not root.is_dir():
        return results
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if not (Path(base) / name).is_symlink())
        for name in sorted(files):
            path = Path(base) / name
            if path.suffix == ".md" and not path.is_symlink() and stat.S_ISREG(path.stat().st_mode):
                results.append(path)
            if len(results) >= MAX_DOCS:
                return results
    return results


class ResourceIndex:
    """Snapshot of scripts, skills and source-tree docs plus a read-through cache."""

    def __init__(self, scripts_root, skills_root=None, docs_root=None):
        self.scripts_root = Path(scripts_root).absolute() if scripts_root else None
        self.skills_root = Path(skills_root).absolute() if skills_root else None
        self.docs_root = Path(docs_root).absolute() if docs_root else (source_root() / "docs")
        self._cache: dict[str, tuple[float, int, str]] = {}
        self.items: list[Resource] = []
        self.errors: list[str] = []

    def refresh(self):
        self.items, self.errors = [], []
        self._cache.clear()
        self._add_scripts()
        self._add_skills()
        self._add_docs()
        return self.items

    def _add_scripts(self):
        root = self.scripts_root
        if root is None or not root.is_dir():
            return
        found = []
        try:
            for base, dirs, files in os.walk(root, followlinks=False):
                dirs[:] = sorted(name for name in dirs if not (Path(base) / name).is_symlink())
                for name in sorted(files):
                    path = Path(base) / name
                    if (path.suffix == ".mt" and not path.is_symlink()
                            and stat.S_ISREG(path.stat().st_mode)):
                        found.append(path)
        except OSError as exc:
            self.errors.append(f"脚本目录：{exc}")
        for path in sorted(found):
            self._append("脚本", path, path.relative_to(root), "mt")

    def _add_skills(self):
        root = self.skills_root
        if root is None or not root.is_dir():
            return
        try:
            library = SkillsLibrary(root)
            for skill in library.index()["skills"]:
                for name in skill["files"]:
                    path = library.skills[skill["name"]]["directory"] / name
                    self._append("技能", path, Path(skill["name"]) / name, "markdown")
                if len(self.items) >= MAX_DOCS:
                    return
        except (OSError, SecurityError, ValueError) as exc:
            self.errors.append(f"技能目录：{exc}")

    def _add_docs(self):
        root = self.docs_root
        for path in _walk_markdown(root):
            self._append("文档", path, path.relative_to(root), "markdown")

    def _append(self, group, path, shown, language):
        if len(self.items) >= MAX_DOCS:
            return
        try:
            info = path.stat()
        except OSError:
            return
        self.items.append(Resource(group=group, name=shown.as_posix(), path=str(path),
                                   language=language, size=info.st_size))

    def read(self, resource):
        """Return cached UTF-8 text; any file change invalidates the entry."""
        path = Path(resource.path)
        try:
            info = path.stat()
        except OSError as exc:
            raise SecurityError(f"文件不可读：{type(exc).__name__}") from None
        if path.is_symlink() or not stat.S_ISREG(info.st_mode):
            raise SecurityError("只允许读取普通文件")
        if info.st_size > MAX_PREVIEW:
            raise SecurityError(f"文件超过 {MAX_PREVIEW} 字节的预览上限")
        cached = self._cache.get(str(path))
        if cached is not None and cached[0] == info.st_mtime and cached[1] == info.st_size:
            return cached[2]
        try:
            text = read_file(path, MAX_PREVIEW)
        except UnicodeDecodeError:
            raise SecurityError("文件不是 UTF-8 文本") from None
        self._cache[str(path)] = (info.st_mtime, info.st_size, text)
        return text
