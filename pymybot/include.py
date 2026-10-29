"""Sandboxed content inclusion and phase-based .mt matrix merging."""
from __future__ import annotations

import logging
import re
import stat
from pathlib import Path, PureWindowsPath

from .errors import ScriptError
from .matrix import Matrix, is_control, parse_matrices, reflex_name, split_action_column, struct_name

MAX_INCLUDES = 32
MAX_INCLUDE_DEPTH = 32
MAX_INCLUDE_BYTES = 8 * 1024 * 1024
MAX_PHASE = 100_000
MAX_MERGED_ROWS = 20_000
MAX_MERGED_CELLS = 200_000
_LOG = logging.getLogger(__name__)


def _scalar_merge(a: Matrix, b: Matrix) -> Matrix:
    if a.header != b.header:
        raise ScriptError(f"{a.name} matrix header differs across merged scripts")
    index = a.require_col("name")
    seen: set[str] = set()
    rows = [a.header[:]]
    for row in a.data + b.data:
        if row[index] in seen:
            raise ScriptError(f"duplicate {a.name} name {row[index]!r} across merged scripts")
        seen.add(row[index])
        rows.append(row[:])
    return Matrix(a.name, rows)


def _fold(matrices: list[Matrix], name: str) -> Matrix | None:
    result = None
    for matrix in matrices:
        if matrix.name.strip() == name:
            result = matrix if result is None else _scalar_merge(result, matrix)
    return result


def _merge(a: Matrix, b: Matrix, phase: int) -> Matrix:
    if a.children or b.children or is_control(a.name) or is_control(b.name):
        raise ScriptError("Cannot merge a control block; operands must be plain matrix tables")
    devices = {split_action_column(head)[0] for head in a.header}
    for head in b.header:
        device = split_action_column(head)[0]
        if device in devices:
            raise ScriptError(f"device '{device}' appears in both scripts")
    na, nb = len(a.data), len(b.data)
    if phase < 0 and nb and -phase >= nb:
        raise ScriptError(f"phase {phase} drops all {nb} rows of merged input")
    if phase < 0 and nb:
        _LOG.warning("Merge phase %s drops the first %s rows of @%s", phase, -phase, b.name)
    total, width = max(na, nb + phase), len(a.header) + len(b.header)
    if total > MAX_MERGED_ROWS or total * width > MAX_MERGED_CELLS:
        raise ScriptError("Merged output exceeds the row/cell limit")
    rows = [a.header + b.header]
    for r in range(1, total + 1):
        left = a.rows[r] if r <= na else ["-"] * len(a.header)
        right = b.rows[r - phase] if 1 <= r - phase <= nb else ["-"] * len(b.header)
        if phase < 0 and nb and r == 1:
            # Seed the first retained row before its inherited sources are lost.
            right = [b.inherited(r - phase, col) for col in range(len(b.header))]
        rows.append(left + right)
    return Matrix(a.name, rows)


def _specs(matrix: Matrix) -> list[tuple[str, int]]:
    if not matrix.rows:
        return []
    name = matrix.name.strip()
    allowed = {"path", "phase"} if name == "Merge" else {"path"}
    if any(head not in allowed for head in matrix.header):
        raise ScriptError(f"@{name} columns not supported; only {', '.join(sorted(allowed))}")
    if len(set(matrix.header)) != len(matrix.header):
        raise ScriptError(f"@{name} contains duplicate columns")
    path_col = matrix.require_col("path")
    phase_col = matrix.header.index("phase") if "phase" in matrix.header else None
    specs = []
    for row in range(1, len(matrix.rows)):
        phase = 0
        if phase_col is not None:
            raw = matrix.inherited(row, phase_col).strip()
            if raw != "-":
                if not re.fullmatch(r"[+-]?[0-9]+", raw):
                    raise ScriptError(f"@Merge phase is not an integer (row {row})")
                # Avoid Python's unbounded integer parsing and digit-limit exceptions.
                digits = raw.lstrip("+-").lstrip("0")
                if len(digits) > 6:
                    raise ScriptError(f"@Merge phase out of range +/-{MAX_PHASE}")
                phase = int(("-" if raw.startswith("-") else "") + (digits or "0"))
                if abs(phase) > MAX_PHASE:
                    raise ScriptError(f"@Merge phase out of range +/-{MAX_PHASE}")
        specs.append((matrix.rows[row][path_col].strip(), phase))
    return specs


class _Expander:
    def __init__(self, base: Path):
        try:
            self.root = base.resolve(strict=True)
        except (OSError, RuntimeError, ValueError):
            raise ScriptError("Include base directory does not exist") from None
        if not self.root.is_dir():
            raise ScriptError("Include base must be a directory")
        self.count = 0
        self.total_bytes = 0
        self.visited: set[Path] = set()

    def path(self, base: Path, requested: str, depth: int) -> Path:
        self.count += 1
        if self.count > MAX_INCLUDES or depth > MAX_INCLUDE_DEPTH:
            raise ScriptError(f"Include/Merge exceeds the row/depth limit of {MAX_INCLUDES}")
        # Reject Windows roots, drive-relative paths and separators on *all*
        # hosts, so a script cannot gain traversal powers when moved to Windows.
        win = PureWindowsPath(requested)
        if not requested or "\0" in requested or "\\" in requested or ":" in requested:
            raise ScriptError("Include path must be a relative .mt path without NUL, ':' or backslashes")
        if requested.startswith("/") or win.drive or win.root:
            raise ScriptError("Include absolute path rejected")
        if any(part in {"", ".", ".."} for part in requested.split("/")):
            raise ScriptError("Include path must not traverse outside its base or contain empty/dot segments")
        if not requested.endswith(".mt"):
            raise ScriptError("Include/Merge only accepts .mt scripts")
        path = base.joinpath(*requested.split("/"))
        self.check_path(path)
        return path

    def check_path(self, path: Path) -> None:
        try:
            relative = path.relative_to(self.root)
            current = self.root
            for part in relative.parts:
                current = current / part
                if current.is_symlink() or getattr(current, "is_junction", lambda: False)():
                    raise ScriptError("Include rejected: symbolic link or junction")
            if not path.resolve(strict=True).is_relative_to(self.root):
                raise ScriptError("Include path escapes sandbox")
            if not stat.S_ISREG(path.stat().st_mode):
                raise ScriptError("Include target must be a regular file")
        except ScriptError:
            raise
        except (OSError, RuntimeError, ValueError):
            raise ScriptError(f"Cannot open include file {str(path)[-180:]!r}") from None

    def read(self, path: Path) -> list[Matrix]:
        # Read at most the remaining budget plus one byte, never an unbounded
        # read followed by a size check. No O_NOFOLLOW or other POSIX dependency.
        remaining = min(MAX_INCLUDE_BYTES, MAX_INCLUDE_BYTES - self.total_bytes)
        try:
            before = path.stat()
            with path.open("rb") as stream:
                import os
                opened = os.fstat(stream.fileno())
                self.check_path(path)
                if not stat.S_ISREG(opened.st_mode) or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                    raise ScriptError("Include file changed while opening")
                data = stream.read(remaining + 1)
        except OSError:
            raise ScriptError(f"Cannot read include file {str(path)[-180:]!r}") from None
        if len(data) > remaining:
            raise ScriptError("Included scripts exceed the byte limit")
        self.total_bytes += len(data)
        try:
            return parse_matrices(data.decode("utf-8"))
        except (UnicodeError, ScriptError):
            # Content of local files must not be disclosed through parse errors.
            raise ScriptError(f"Cannot parse included script {str(path)[-180:]!r}") from None

    def splice(self, seq: list[Matrix], base: Path, depth: int = 0,
               active: frozenset[Path] = frozenset()) -> list[Matrix]:
        out = []
        for matrix in seq:
            if matrix.name.strip() != "Include":
                out.append(matrix)
                continue
            for relative, _ in _specs(matrix):
                path = self.path(base, relative, depth + 1)
                # Include is textual copy even for *.once.mt; only Merge has
                # once semantics. Repeated non-recursive copies remain legal.
                if path in active:
                    raise ScriptError("Include cycle detected")
                out.extend(self.splice(self.read(path), path.parent, depth + 1, active | {path}))
        return out

    def nested(self, seq: list[Matrix], base: Path) -> list[Matrix]:
        pending: list[Matrix] = []
        out = []
        for matrix in seq:
            name = matrix.name.strip()
            if name == "Include":
                raise ScriptError("@Include may only appear at the outermost level")
            if name == "Merge":
                pending.append(matrix)
                continue
            if pending:
                if (is_control(name) or matrix.children or name in {"Alias", "Vars"}
                        or reflex_name(name) is not None or struct_name(name) is not None):
                    raise ScriptError("Nested @Merge must be followed by a plain matrix table")
                for directive in pending:
                    for relative, phase in _specs(directive):
                        path = self.path(base, relative, 1)
                        targets = self.read(path)
                        if not targets:
                            raise ScriptError("Nested @Merge target has no matrix")
                        for target in targets:
                            if (target.name.strip() in {"Alias", "Vars", "Include", "Merge"}
                                    or reflex_name(target.name) is not None or struct_name(target.name) is not None):
                                raise ScriptError("Nested @Merge target must contain only plain matrix tables")
                            matrix = _merge(matrix, target, phase)
                pending.clear()
            children = self.nested(matrix.children, base) if matrix.children else []
            out.append(Matrix(matrix.name, matrix.rows, children, matrix.json_text))
        if pending:
            raise ScriptError("Nested @Merge has no following table to merge into")
        return out

    def fragment(self, path: Path, depth: int) -> dict[str, Matrix | list[Matrix] | None]:
        if path in self.visited:
            if path.name.endswith(".once.mt"):
                _LOG.info("%s already included, skipped (include-once)", path)
                return {}
            raise ScriptError(f"{path.name!r} included more than once (or cycle); use *.once.mt for shared fragments")
        self.visited.add(path)
        seq = self.read(path)
        if not seq:
            raise ScriptError(f"{path.name!r}: no matrix found")
        for matrix in seq:
            if (matrix.name.strip() not in {"Alias", "Vars", "Action", "Merge"}
                    and struct_name(matrix.name) is None):
                raise ScriptError(f"@{matrix.name[:100]} is not supported in @Merge fragments; "
                                  "use @Include for content copying")
        return self.accumulate(seq, path.parent, depth)

    def accumulate(self, seq: list[Matrix], base: Path, depth: int) -> dict[str, Matrix | list[Matrix] | None]:
        acc = {name: _fold(seq, name) for name in ("Alias", "Vars")}
        acc["Struct"] = [matrix for matrix in seq if struct_name(matrix.name) is not None]
        if any(matrix.name.strip() == "Action" and matrix.children for matrix in seq):
            raise ScriptError("Top-level @Merge requires a plain @Action matrix, not a nested block")
        acc["Action"] = next((m for m in seq if m.name.strip() == "Action"), None)
        owned: dict[str, set[str]] = {}
        for kind in ("Alias", "Vars"):
            m = acc[kind]
            owned[kind] = {row[m.require_col("name")] for row in m.data} if m else set()
        actions = sum(m.name.strip() == "Action" for m in seq)
        if actions > 1:
            # The MT merge retains only the first Action; surface that lossy rule
            # rather than silently losing a copied action.
            _LOG.warning("Top-level @Merge uses only the first @Action; %s later "
                         "@Action block(s) are discarded", actions - 1)
        for matrix in seq:
            if matrix.name.strip() != "Merge":
                continue
            for relative, phase in _specs(matrix):
                path = self.path(base, relative, depth + 1)
                parts = self.fragment(path, depth + 1)
                acc["Struct"].extend(parts.get("Struct", []))
                for kind in ("Alias", "Vars"):
                    child = parts.get(kind)
                    if child is None:
                        continue
                    index = child.require_col("name")
                    rows = [row[:] for row in child.data if row[index] not in owned[kind]]
                    if len(rows) != len(child.data):
                        _LOG.info("%s: definitions closer to the main script win", path)
                    if rows:
                        filtered = Matrix(kind, [child.header[:]] + rows)
                        acc[kind] = filtered if acc[kind] is None else _scalar_merge(acc[kind], filtered)
                child = parts.get("Action")
                if child is not None:
                    acc["Action"] = child if acc["Action"] is None else _merge(acc["Action"], child, phase)
        return acc

    def run(self, matrices: list[Matrix]) -> list[Matrix]:
        seq = self.splice(matrices, self.root)
        seq = [Matrix(m.name, m.rows, self.nested(m.children, self.root), m.json_text) for m in seq]
        if not any(m.name.strip() == "Merge" for m in seq):
            return seq
        acc = self.accumulate(seq, self.root, 0)
        out = [acc[k] for k in ("Alias", "Vars") if acc[k] is not None] + acc["Struct"]
        action = acc["Action"]
        if action is not None and not any(m.name.strip() == "Action" for m in seq):
            out.append(action)
            action = None
        for matrix in seq:
            if matrix.name.strip() in {"Alias", "Vars", "Merge"} or struct_name(matrix.name) is not None:
                continue
            if matrix.name.strip() == "Action":
                if action is not None:
                    out.append(action)
                    action = None
            else:
                out.append(matrix)
        return out


def expand_includes(matrices: list[Matrix], base_dir: Path) -> list[Matrix]:
    """Expand Include copies, local nested Merges, then top-level Merge trees."""
    pending = list(matrices)
    while pending:
        matrix = pending.pop()
        if matrix.name.strip() in {"Include", "Merge"}:
            return _Expander(Path(base_dir)).run(matrices)
        pending.extend(matrix.children)
    return matrices  # No file directives: no filesystem access or reordering.
