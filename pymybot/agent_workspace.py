"""Bounded workspace file tools and an approval-gated shell.

Without protected paths, the shell retains its legacy workspace cwd (not OS
isolation); `sandbox="auto"` upgrades to bubblewrap when usable. Prompt-protected
workspaces deny generic file access to those roots and require bubblewrap for
shell writes to be isolated. Shell mounts are read-only, not a confidentiality
boundary; dedicated prompt reads provide the file-tool privacy/audit boundary.
"""
from __future__ import annotations

from contextlib import contextmanager
import os
from pathlib import Path, PureWindowsPath
import secrets
import stat
import subprocess
import time

from .process import kill_tree, read_pipe, shell_command
from .sandbox import SANDBOX_MODES, wrap_shell
from .security import SecurityError, dumps

MAX_FILE_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 16 * 1024
MAX_COMMAND_BYTES = 16 * 1024
MAX_ENTRIES = 1000
WORKSPACE_TOOLS = {
    "list_files": (set(), {"path"}),
    "read_file": ({"path"}, {"path", "offset", "limit"}),
    "write_file": ({"path", "content"}, {"path", "content", "overwrite"}),
    "edit_file": ({"path", "old_string", "new_string"},
                  {"path", "old_string", "new_string", "replace_all"}),
    "shell": ({"command"}, {"command", "cwd"}),
}
_DIR_FD = (os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd
           and os.unlink in os.supports_dir_fd and os.rename in os.supports_dir_fd
           and os.link in os.supports_dir_fd and os.scandir in os.supports_fd
           and hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"))
_RESERVED = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"}
_RESERVED |= {prefix + digit for prefix in ("COM", "LPT") for digit in "123456789¹²³"}


def _text(value, cap, field, *, nonempty=False, no_nul=False):
    if not isinstance(value, str):
        raise SecurityError(f"{field} must be UTF-8 text")
    try:
        size = len(value.encode("utf-8")) if len(value) <= cap else cap + 1
    except UnicodeEncodeError:
        raise SecurityError(f"{field} must be valid UTF-8 text") from None
    if size > cap or (nonempty and not value) or (no_nul and "\0" in value):
        raise SecurityError(f"{field} is empty, invalid, or exceeds its {cap}-byte limit")


def _relative(value, *, directory=False):
    _text(value, 4096, "path", nonempty=True, no_nul=True)
    if directory and value == ".":
        return ()
    win = PureWindowsPath(value)
    parts = value.split("/")
    if (win.drive or win.root or "\\" in value or ":" in value
            or any(p in {"", ".", ".."} or p.endswith((" ", "."))
                   or p.split(".")[0].rstrip(" ").upper() in _RESERVED
                   or any(ord(c) < 32 or c in '<>"|?*' for c in p) for p in parts)):
        raise SecurityError("Use a workspace-relative path without links, traversal, or Windows special names")
    return tuple(parts)


def _identity(info):
    return info.st_dev, info.st_ino


def _version(info):
    return _identity(info), info.st_size, info.st_mtime_ns


def _linked(info):
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def _no_links(path):
    for part in (*reversed(path.parents), path):
        if _linked(part.lstat()):
            raise SecurityError("Linked paths and Windows reparse points are not allowed")


def _stat_at(parent, fd, name):
    try:
        info = (os.stat(name, dir_fd=fd, follow_symlinks=False) if fd is not None
                else (parent / name).lstat())
    except FileNotFoundError:
        return None
    if _linked(info):
        raise SecurityError("Linked files and Windows reparse points are not allowed")
    if not stat.S_ISREG(info.st_mode):
        raise SecurityError("Expected a regular file")
    return info


def _open_at(parent, fd, name, flags, mode=0o600):
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    return (os.open(name, flags, mode, dir_fd=fd) if fd is not None
            else os.open(parent / name, flags, mode))


def _unlink_at(parent, fd, name):
    if fd is not None:
        os.unlink(name, dir_fd=fd)
    else:
        os.unlink(parent / name)


class Workspace:
    def __init__(self, directory, *, enable_shell=False, sandbox="off", protected_paths=()):
        if type(enable_shell) is not bool:
            raise SecurityError("enable_shell must be a boolean")
        if sandbox not in SANDBOX_MODES:
            raise SecurityError("sandbox must be one of off, auto or bwrap")
        # Check before resolving: resolve() alone would hide linked ancestors.
        candidate = Path(directory).absolute()
        _no_links(candidate)
        self.path = candidate.resolve(strict=True)
        info = self.path.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise SecurityError("Workspace must be an existing directory")
        self._identity = _identity(info)
        self.enable_shell = enable_shell
        self.sandbox = sandbox
        protected = {}
        for value in protected_paths:
            candidate = Path(value).absolute()
            _no_links(candidate)
            root = candidate.resolve(strict=True)
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise SecurityError("Protected prompt roots must be existing directories")
            if self.path.is_relative_to(root):
                raise SecurityError("Workspace cannot be inside a protected prompt directory")
            protected[root] = _identity(info)
        self._protected = tuple(protected.items())

    @property
    def protected_paths(self):
        return tuple(root for root, _ in self._protected)

    def _check_protected_path(self, path, *, writing=False):
        for root, _ in self._protected:
            if path.is_relative_to(root) or (writing and root.is_relative_to(path)):
                raise SecurityError("Prompt assets are protected; use read_prompt or approved prompt tools")

    def _check_hardlinks(self, info):
        # A second name need not live below a protected root. Conservatively
        # reject multiply linked files only for opt-in protected workspaces.
        if self._protected and info is not None and info.st_nlink > 1:
            raise SecurityError("Hardlinked files are unavailable with prompt protection; use read_prompt")

    def _check_protected_shell(self, check):
        # Read-only mounts cannot protect an existing writable hardlink outside
        # the mount. Fail closed for linked assets rather than inspect commands.
        def failed(error):
            raise error

        for root, _ in self._protected:
            for base, dirs, files in os.walk(root, followlinks=False, onerror=failed):
                check()
                for name in (*dirs, *files):
                    check()
                    info = (Path(base) / name).lstat()
                    if _linked(info):
                        raise SecurityError("Linked prompt assets cannot be protected by the shell sandbox")
                    if stat.S_ISREG(info.st_mode):
                        self._check_hardlinks(info)

    @staticmethod
    def validate(name, arguments):
        if not isinstance(name, str) or name not in WORKSPACE_TOOLS or type(arguments) is not dict:
            raise SecurityError("Unknown workspace tool or invalid arguments")
        required, allowed = WORKSPACE_TOOLS[name]
        if not required <= arguments.keys() or not arguments.keys() <= allowed:
            raise SecurityError("Missing or unsupported workspace tool arguments")
        if name == "shell":
            _text(arguments["command"], MAX_COMMAND_BYTES, "command", nonempty=True, no_nul=True)
            if not arguments["command"].strip():
                raise SecurityError("command must not be blank")
            if os.name == "nt" and ("\n" in arguments["command"] or "\r" in arguments["command"]):
                raise SecurityError("cmd.exe runs a single line; join commands with && instead of newlines")
            _relative(arguments.get("cwd", "."), directory=True)
        else:
            _relative(arguments.get("path", "."), directory=name == "list_files")
        if name == "read_file":
            for field, default, maximum in (("offset", 1, None), ("limit", 200, 1000)):
                value = arguments.get(field, default)
                if type(value) is not int or value < 1 or (maximum is not None and value > maximum):
                    raise SecurityError(f"{field} must be a positive integer" + (" no greater than 1000" if maximum else ""))
        elif name == "write_file":
            _text(arguments["content"], MAX_FILE_BYTES, "content")
            if type(arguments.get("overwrite", False)) is not bool:
                raise SecurityError("overwrite must be a boolean")
        elif name == "edit_file":
            _text(arguments["old_string"], MAX_FILE_BYTES, "old_string", nonempty=True)
            _text(arguments["new_string"], MAX_FILE_BYTES, "new_string")
            if type(arguments.get("replace_all", False)) is not bool:
                raise SecurityError("replace_all must be a boolean")

    def _check_root(self):
        _no_links(self.path)
        info = self.path.lstat()
        if not stat.S_ISDIR(info.st_mode) or _identity(info) != self._identity:
            raise SecurityError("Workspace root was replaced; configure the workspace again")
        for root, identity in self._protected:
            _no_links(root)
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode) or _identity(info) != identity:
                raise SecurityError("Protected prompt root was replaced; configure the workspace again")

    @contextmanager
    def _directory(self, parts, check):
        """Hold parent descriptors until the operation and its final checks finish."""
        check()
        self._check_root()
        path, fd, opened, identities = self.path, None, [], []
        try:
            if _DIR_FD:
                flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                # Walk from the filesystem anchor, not an absolute open that can
                # follow a concurrently substituted ancestor of the workspace.
                fd = os.open(self.path.anchor, flags)
                opened.append(fd)
                for component in self.path.parts[1:]:
                    check()
                    child = os.open(component, flags, dir_fd=fd)
                    os.close(opened.pop())
                    fd = child
                    opened.append(fd)
                if _identity(os.fstat(fd)) != self._identity:
                    raise SecurityError("Workspace root changed while opening")
            identities.append((path, self._identity))
            for component in parts:
                check()
                path = path / component
                info = path.lstat()
                if _linked(info) or not stat.S_ISDIR(info.st_mode):
                    raise SecurityError("Expected an existing, non-linked directory")
                if fd is not None:
                    fd = os.open(component, flags, dir_fd=fd)
                    opened.append(fd)
                    if _identity(info) != _identity(os.fstat(fd)):
                        raise SecurityError("Directory changed while opening")
                identities.append((path, _identity(info)))

            def guard():
                self._check_root()
                for directory, identity in identities:
                    info = directory.lstat()
                    if _linked(info) or not stat.S_ISDIR(info.st_mode) or _identity(info) != identity:
                        raise SecurityError("Workspace parent directory changed; retry after inspection")
                if fd is not None and _identity(os.fstat(fd)) != identities[-1][1]:
                    raise SecurityError("Workspace parent directory changed")

            guard()
            yield path, fd, guard
        finally:
            for descriptor in reversed(opened):
                os.close(descriptor)

    def call(self, name, arguments, check, started):
        check()
        self.validate(name, arguments)
        if name == "shell" and not self.enable_shell:
            raise PermissionError("Shell is disabled; explicitly enable shell access first")
        directory = name in {"list_files", "shell"}
        relative = arguments.get("cwd" if name == "shell" else "path", ".")
        parts = _relative(relative, directory=directory)
        self._check_protected_path(self.path.joinpath(*parts), writing=name in {"write_file", "edit_file"})
        with self._directory(parts if directory else parts[:-1], check) as (parent, fd, guard):
            if name == "shell":
                self._check_protected_shell(check)
                result = self._shell(arguments["command"], parent, fd, guard, check, started,
                                     sandbox=self.sandbox, workspace=self.path,
                                     protected_paths=self.protected_paths)
            elif name == "list_files":
                result = self._listing(relative, parent, fd, check)
            elif name == "read_file":
                content, _ = self._read(parent, fd, parts[-1], guard, check)
                lines = content.splitlines(keepends=True)
                offset, limit = arguments.get("offset", 1), arguments.get("limit", 200)
                result = {"path": relative, "content": "".join(lines[offset - 1:offset - 1 + limit]),
                          "offset": offset, "total_lines": len(lines),
                          "truncated": offset - 1 + limit < len(lines)}
            else:
                before = _stat_at(parent, fd, parts[-1])
                self._check_hardlinks(before)
                if name == "write_file":
                    if before is not None and not arguments.get("overwrite", False):
                        raise FileExistsError("File already exists; set overwrite=true to replace it")
                    content = arguments["content"]
                    replacements = None
                else:
                    content, before = self._read(parent, fd, parts[-1], guard, check)
                    old, new = arguments["old_string"], arguments["new_string"]
                    first = content.find(old)
                    if first < 0:
                        raise SecurityError("old_string was not found; read the file before editing")
                    if content.find(old, first + 1) >= 0 and not arguments.get("replace_all", False):
                        raise SecurityError("old_string is ambiguous; use a unique match or replace_all=true")
                    replacements = content.count(old)  # replace_all uses non-overlapping matches.
                    # Bound the result before allocating a potentially huge replacement.
                    final_size = len(content.encode("utf-8")) + replacements * (len(new.encode("utf-8")) - len(old.encode("utf-8")))
                    if final_size > MAX_FILE_BYTES:
                        raise SecurityError("Edited file would exceed the 1 MiB limit")
                    content = content.replace(old, new)
                data = content.encode("utf-8")
                self._write(parent, fd, parts[-1], data, before, guard, check, started)
                result = {"path": relative, "bytes_written": len(data)}
                if replacements is not None:
                    result["replacements"] = replacements
            check()
            guard()
            return result

    def _listing(self, relative, parent, fd, check):
        entries, skipped, truncated = [], 0, False
        with os.scandir(fd if fd is not None else parent) as iterator:
            for entry in iterator:
                check()
                if len(entries) == MAX_ENTRIES:
                    truncated = True
                    break
                try:
                    _relative(entry.name)
                except ValueError:
                    skipped += 1
                    continue
                info = entry.stat(follow_symlinks=False)
                if self._protected and stat.S_ISREG(info.st_mode):
                    # DirEntry.stat() caches a link count of 1 on Windows, which would hide hardlinks.
                    try:
                        info = (os.stat(entry.name, dir_fd=fd, follow_symlinks=False) if fd is not None
                                else (parent / entry.name).lstat())
                    except FileNotFoundError:
                        skipped += 1
                        continue
                if (_linked(info) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))
                        or (self._protected and stat.S_ISREG(info.st_mode) and info.st_nlink > 1)):
                    skipped += 1
                    continue
                item = {"name": entry.name, "type": "directory" if stat.S_ISDIR(info.st_mode) else "file"}
                if item["type"] == "file":
                    item["size_bytes"] = info.st_size
                entries.append(item)
        return {"path": relative, "entries": sorted(entries, key=lambda item: item["name"]),
                "truncated": truncated, "skipped": skipped}

    def _read(self, parent, fd, name, guard, check):
        check()
        guard()
        before = _stat_at(parent, fd, name)
        if before is None:
            raise FileNotFoundError("File does not exist; list the parent directory first")
        self._check_hardlinks(before)
        if before.st_size > MAX_FILE_BYTES:
            raise SecurityError("File exceeds the 1 MiB limit")
        descriptor = _open_at(parent, fd, name, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or _version(before) != _version(opened):
                raise SecurityError("File changed while opening")
            self._check_hardlinks(opened)
            data = bytearray()
            while True:
                check()
                chunk = os.read(descriptor, min(65536, MAX_FILE_BYTES + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > MAX_FILE_BYTES:
                    raise SecurityError("File exceeds the 1 MiB limit")
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        check()
        guard()
        current = _stat_at(parent, fd, name)
        if (current is None or _version(before) != _version(current)
                or _version(opened) != _version(after)
                or opened.st_ctime_ns != after.st_ctime_ns
                or before.st_ctime_ns != current.st_ctime_ns):
            raise SecurityError("File changed while reading; retry after inspection")
        try:
            return data.decode("utf-8"), current
        except UnicodeDecodeError:
            raise SecurityError("File is not UTF-8 text") from None

    def _write(self, parent, fd, name, data, before, guard, check, started):
        check()
        guard()
        temporary = ".agent-" + secrets.token_hex(16) + ".tmp"
        descriptor = _open_at(parent, fd, temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        try:
            try:
                created = os.fstat(descriptor)
                view = memoryview(data)
                while view:
                    check()
                    count = os.write(descriptor, view[:65536])
                    if count <= 0:
                        raise OSError("Could not write temporary file")
                    view = view[count:]
                if before is not None and hasattr(os, "fchmod"):
                    os.fchmod(descriptor, stat.S_IMODE(before.st_mode) & 0o777)
                staged = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            check()
            guard()
            current = _stat_at(parent, fd, name)
            self._check_hardlinks(current)
            if before is None:
                if current is not None:
                    raise FileExistsError("File appeared before creation; no existing file was replaced")
            elif (current is None or _version(current) != _version(before)
                  or current.st_ctime_ns != before.st_ctime_ns):
                raise SecurityError("File changed before replacement; retry after inspection")
            temp_info = _stat_at(parent, fd, temporary)
            if (temp_info is None or _identity(temp_info) != _identity(created)
                    or _version(temp_info) != _version(staged)
                    or temp_info.st_size != len(data) or temp_info.st_nlink != 1):
                raise SecurityError("Temporary file changed before replacement")
            # Staging above is reversible. Only installing the new file marks
            # execution, after all predictable argument/match/path errors.
            started()
            if before is None:
                if fd is not None:
                    os.link(temporary, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                elif os.name == "nt":
                    os.rename(parent / temporary, parent / name)  # Windows: never clobbers.
                else:
                    os.link(parent / temporary, parent / name, follow_symlinks=False)
            elif fd is not None:
                os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
            else:
                os.replace(parent / temporary, parent / name)
        finally:
            cleanup_safe = True
            if fd is None:
                try:
                    guard()
                except (OSError, ValueError):
                    # Without a pinned parent handle, leave private staging in
                    # the moved directory rather than unlink through a new path.
                    cleanup_safe = False
            if cleanup_safe:
                try:
                    _unlink_at(parent, fd, temporary)
                except FileNotFoundError:
                    pass  # Successful replace/Windows rename consumed the staging name.

    @staticmethod
    def _shell(command, cwd, fd, guard, check, started, sandbox="off", workspace=None, protected_paths=()):
        argv, options, interpreter = shell_command(command)
        backend = "workspace"
        if sandbox != "off" or protected_paths:
            argv, backend = wrap_shell(argv, mode=sandbox, workspace=workspace, cwd=cwd,
                                       protected_paths=protected_paths)
        # Linux procfs provides descriptor-pinned cwd without preexec_fn (unsafe
        # in the executor's multithreaded process). Other platforms use checks.
        if backend == "workspace" and fd is not None and Path("/proc/self/fd").is_dir():
            options["pass_fds"] = (fd,)
            launch_cwd = f"/proc/self/fd/{fd}"
        else:
            # A bubblewrap child gets a private /proc, so fd paths do not survive;
            # bwrap itself chdirs into the pinned path after mounting.
            launch_cwd = cwd if backend == "workspace" else str(workspace)
        check()
        guard()
        tree_killed = False
        process = subprocess.Popen(argv, cwd=launch_cwd, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, **options)
        try:
            started()  # Popen failures must never be reported as executed.
            pipes = [process.stdout, process.stderr]
            if os.name != "nt":
                for pipe in pipes:
                    os.set_blocking(pipe.fileno(), False)
            buffers = [bytearray(), bytearray()]
            truncated = False
            active = {0, 1}
            exited_at = None
            while True:
                check()
                for index in tuple(active):
                    chunk = read_pipe(pipes[index])
                    if chunk == b"":
                        active.remove(index)
                    elif chunk:
                        room = MAX_OUTPUT_BYTES - len(buffers[index])
                        buffers[index].extend(chunk[:room])
                        truncated |= len(chunk) > room
                exit_code = process.poll()
                if exit_code is not None:
                    if exited_at is None:
                        exited_at = time.monotonic()
                        kill_tree(process)
                        tree_killed = True
                    if not active:
                        break
                    if time.monotonic() - exited_at >= 0.25:
                        truncated = True  # Escaped descendant retained a pipe.
                        break
                # Short bounded wait, not communicate(): output remains bounded
                # while both streams are drained, including after the shell exits.
                if exit_code is None:
                    try:
                        process.wait(timeout=0.01)
                    except subprocess.TimeoutExpired:
                        pass
                else:
                    time.sleep(0.001)
            check()
            result = {"exit_code": exit_code, "stdout": buffers[0].decode("utf-8", errors="replace"),
                      "stderr": buffers[1].decode("utf-8", errors="replace"),
                      "truncated": truncated, "interpreter": interpreter, "sandbox": backend}
            # JSON escaping must not force the executor to discard structured exit status.
            while len(dumps(result).encode("utf-8")) > 48 * 1024:
                for key in ("stdout", "stderr"):
                    result[key] = result[key][:len(result[key]) // 2]
                result["truncated"] = True
            return result
        finally:
            try:
                if not tree_killed:
                    kill_tree(process)
                process.wait(timeout=3)
            finally:
                process.stdout.close()
                process.stderr.close()
