"""Keep the agent-facing skills honest about their documented authority.

The agent reads skills/ and never docs/, so a reference may only summarise and
link to the docs page that owns a behaviour. Dead links, unregistered reference
files and a missing Source: declaration are failures. Verbatim duplication is
only reported: a shared code block or SQL example is legitimate, so a human
decides whether a long identical run is drift.
"""
from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

MAX_SKILL_LINES = 300
MAX_SKILL_BYTES = 16 * 1024
DUPLICATE_RUN = 6
MIN_DUPLICATE_LENGTH = 24
CHECKED_ROOTS = ("docs", "modules", "pymybot", "robots", "scripts", "skills", "tests", "tools")
PLACEHOLDERS = set("<>*?|$~ ")

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
INLINE_CODE = re.compile(r"`([^`\n]+)`")
BRACES = re.compile(r"\{([^{}]*)\}")


def _expand(value):
    """Expand a single `{a,b}` group so `pymybot/{sql,expr}.py` stays checkable."""
    match = BRACES.search(value)
    if match is None:
        return [value]
    return [value[:match.start()] + part + value[match.end():]
            for part in match.group(1).split(",") if part]


def _candidate_paths(text):
    for raw in INLINE_CODE.findall(text):
        value = raw.strip().rstrip("/")
        if PLACEHOLDERS & set(value) or not value.startswith(tuple(name + "/" for name in CHECKED_ROOTS)):
            continue
        yield from _expand(value)


def _links(text):
    for target in LINK.findall(text):
        target = target.split("#", 1)[0]
        if not target or "://" in target or target.startswith(("mailto:", "/")):
            continue
        yield target


def _normalised(path):
    """Line list with source numbers, keeping only lines worth comparing."""
    kept = []
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        text = " ".join(line.split())
        if len(text) >= MIN_DUPLICATE_LENGTH and set(text) - set("-|= "):
            kept.append((number, text))
    return kept


def _duplication(skill_file, docs_file):
    left, right = _normalised(skill_file), _normalised(docs_file)
    matcher = difflib.SequenceMatcher(None, [text for _, text in left], [text for _, text in right], autojunk=False)
    for start_left, start_right, size in matcher.get_matching_blocks():
        if size >= DUPLICATE_RUN:
            yield left[start_left][0], right[start_right][0], size


def audit(root):
    root = Path(root).resolve()
    skills, docs = root / "skills", root / "docs"
    problems, warnings = [], []
    if not skills.is_dir() or not docs.is_dir():
        return [f"{root}: expected both skills/ and docs/ directories"], warnings

    skill_files = sorted(path for path in skills.rglob("*.md") if path.is_file())
    docs_files = sorted(path for path in docs.rglob("*.md") if path.is_file())

    for path in skill_files:
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        for target in _links(text):
            if not (path.parent / target).resolve().exists():
                problems.append(f"{relative}: link target does not exist: {target}")
        for candidate in _candidate_paths(text):
            if not (root / candidate).exists():
                problems.append(f"{relative}: referenced path does not exist: {candidate}")
        if path.name == "SKILL.md":
            lines = text.count("\n") + 1
            size = len(text.encode("utf-8"))
            if lines > MAX_SKILL_LINES or size > MAX_SKILL_BYTES:
                problems.append(f"{relative}: {lines} lines / {size} bytes exceeds"
                                f" {MAX_SKILL_LINES} lines / {MAX_SKILL_BYTES} bytes; split or trim it")

    index = skills / "README.md"
    registered = set()
    if index.is_file():
        for target in _links(index.read_text(encoding="utf-8")):
            registered.add((index.parent / target).resolve())
    else:
        problems.append("skills/README.md is missing; it maps every topic to its authority")

    for path in skill_files:
        if path.parent.name != "references":
            continue
        relative = path.relative_to(root).as_posix()
        if not any(line.startswith("Source:") for line in path.read_text(encoding="utf-8").split("\n")):
            problems.append(f"{relative}: needs a 'Source:' line naming the authority it summarises")
        if path.resolve() not in registered:
            problems.append(f"{relative}: not registered in the skills/README.md mapping table")

    for skill_file in skill_files:
        for docs_file in docs_files:
            for skill_line, docs_line, size in _duplication(skill_file, docs_file):
                warnings.append(f"{skill_file.relative_to(root).as_posix()}:{skill_line}: {size} lines also in"
                                f" {docs_file.relative_to(root).as_posix()}:{docs_line}; summarise and link instead")
    return problems, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent,
                        help="repository root holding docs/ and skills/")
    options = parser.parse_args(argv)
    problems, warnings = audit(options.root)
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"docs/skill sync: {len(problems)} problem(s), {len(warnings)} warning(s)")
        return 1
    print(f"docs/skill sync: ok, {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
