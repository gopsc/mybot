"""Workspace tools use real temporary files/subprocesses, never hardware/network."""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

import pytest

import pymybot.agent_workspace as workspace_module
from pymybot.agent_workspace import MAX_FILE_BYTES, MAX_OUTPUT_BYTES, WORKSPACE_TOOLS, Workspace


class Interrupted(RuntimeError):
    pass


def deadline(seconds=5):
    end = time.monotonic() + seconds

    def check():
        if time.monotonic() >= end:
            raise Interrupted("Deadline expired")
    return check


def invoke(workspace, name, arguments=None, *, check=None, starts=None):
    starts = [] if starts is None else starts
    return workspace.call(name, arguments or {}, check or deadline(), lambda: starts.append(True))


def python_command(code):
    args = [sys.executable, "-c", code]
    return subprocess.list2cmdline(args) if os.name == "nt" else shlex.join(args)


@pytest.fixture
def workspace(tmp_path):
    return Workspace(tmp_path)


def test_interface_and_constructor(workspace, tmp_path):
    assert workspace.path == tmp_path
    assert workspace.path.is_absolute()
    assert workspace.enable_shell is False
    assert WORKSPACE_TOOLS == {
        "list_files": (set(), {"path"}),
        "read_file": ({"path"}, {"path", "offset", "limit"}),
        "write_file": ({"path", "content"}, {"path", "content", "overwrite"}),
        "edit_file": ({"path", "old_string", "new_string"},
                      {"path", "old_string", "new_string", "replace_all"}),
        "shell": ({"command"}, {"command", "cwd"}),
    }
    with pytest.raises(FileNotFoundError):
        Workspace(tmp_path / "missing")
    (tmp_path / "file").touch()
    with pytest.raises(ValueError):
        Workspace(tmp_path / "file")
    with pytest.raises(ValueError):
        Workspace(tmp_path, enable_shell=1)


@pytest.mark.parametrize("name,args", [
    ("no_tool", {}), ("read_file", {}), ("list_files", {"extra": True}),
    ("read_file", {"path": "file", "offset": 0}),
    ("read_file", {"path": "file", "offset": True}),
    ("read_file", {"path": "file", "limit": 1001}),
    ("read_file", {"path": "file", "limit": 0}),
    ("read_file", {"path": "file", "limit": 1.5}),
    ("write_file", {"path": "file", "content": b"bytes"}),
    ("write_file", {"path": "file", "content": "text", "overwrite": 1}),
    ("write_file", {"path": "file", "content": "\ud800"}),
    ("write_file", {"path": "file", "content": "界" * (MAX_FILE_BYTES // 3 + 1)}),
    ("edit_file", {"path": "file", "old_string": "", "new_string": ""}),
    ("edit_file", {"path": "file", "old_string": "x", "new_string": "y", "replace_all": "yes"}),
    ("shell", {"command": ""}), ("shell", {"command": "  "}),
    ("shell", {"command": "a\0b"}), ("shell", {"command": 1}),
    ("shell", {"command": "x" * (workspace_module.MAX_COMMAND_BYTES + 1)}),
    ("shell", {"command": "exit", "cwd": None}),
])
def test_invalid_arguments_before_started(workspace, name, args):
    starts = []
    with pytest.raises(ValueError):
        invoke(workspace, name, args, starts=starts)
    assert starts == []


@pytest.mark.parametrize("path", [
    "", "/etc/passwd", "..", "../outside", "sub/../file", "./file", "sub//file",
    "file/", "C:/file", "C:file", "\\\\host\\share", "sub\\file", "file:stream",
    "file\0", "CON", "aux.txt", "sub/NUL", "COM1.log", "LPT³", "CONIN$",
    "name.", "name ", "a?b", "a*b", "a\nb", "a|b", "\ud800",
])
def test_bad_paths(workspace, path):
    for tool, args in (("read_file", {"path": path}),
                       ("list_files", {"path": path}),
                       ("shell", {"command": "exit", "cwd": path})):
        with pytest.raises(ValueError):
            invoke(workspace, tool, args)


def test_unicode_roundtrip_and_pagination(workspace, tmp_path):
    starts = []
    text = "第一行\r\nsecond\nlast"
    result = invoke(workspace, "write_file", {"path": "中文.txt", "content": text}, starts=starts)
    assert result == {"path": "中文.txt", "bytes_written": len(text.encode("utf-8"))}
    assert starts == [True]
    starts.clear()
    result = invoke(workspace, "read_file", {"path": "中文.txt", "offset": 2, "limit": 1}, starts=starts)
    assert result == {"path": "中文.txt", "content": "second\n", "offset": 2,
                      "total_lines": 3, "truncated": True}
    result = invoke(workspace, "read_file", {"path": "中文.txt", "offset": 10})
    assert result["content"] == "" and result["total_lines"] == 3 and not result["truncated"]
    assert invoke(workspace, "read_file", {"path": "中文.txt"})["content"] == text
    assert starts == []
    assert (tmp_path / "中文.txt").read_bytes() == text.encode("utf-8")


def test_empty_and_default_read_limits(workspace, tmp_path):
    (tmp_path / "file").write_text("", encoding="utf-8")
    result = invoke(workspace, "read_file", {"path": "file"})
    assert result["content"] == "" and result["total_lines"] == 0
    (tmp_path / "file").write_text("a\n" * 250, encoding="utf-8")
    result = invoke(workspace, "read_file", {"path": "file"})
    assert result["content"] == "a\n" * 200 and result["truncated"]


def test_overwrite_is_explicit_and_atomic(workspace, tmp_path):
    file = tmp_path / "file"
    file.write_text("original", encoding="utf-8")
    original_inode = file.stat().st_ino
    starts = []
    with pytest.raises(FileExistsError):
        invoke(workspace, "write_file", {"path": "file", "content": "new"}, starts=starts)
    assert starts == [] and file.read_text() == "original"
    invoke(workspace, "write_file", {"path": "file", "content": "new", "overwrite": True}, starts=starts)
    assert starts == [True] and file.read_text() == "new"
    assert file.stat().st_ino != original_inode
    assert sorted(p.name for p in tmp_path.iterdir()) == ["file"]


@pytest.mark.skipif(os.name == "nt", reason="POSIX executable mode")
@pytest.mark.parametrize("tool", ["write_file", "edit_file"])
def test_edits_preserve_executable_mode(workspace, tmp_path, tool):
    file = tmp_path / "run.sh"
    file.write_text("old", encoding="utf-8")
    file.chmod(0o750)
    args = ({"path": "run.sh", "content": "new", "overwrite": True} if tool == "write_file"
            else {"path": "run.sh", "old_string": "old", "new_string": "new"})
    invoke(workspace, tool, args)
    assert file.stat().st_mode & 0o777 == 0o750


@pytest.mark.parametrize("tool", ["write_file", "edit_file"])
def test_hardlinks_never_written_through(workspace, tmp_path, tool):
    original = tmp_path / "original"
    original.write_text("old", encoding="utf-8")
    try:
        os.link(original, tmp_path / "alias")
    except OSError:
        pytest.skip("Hardlinks unavailable")
    args = ({"path": "alias", "content": "new", "overwrite": True} if tool == "write_file"
            else {"path": "alias", "old_string": "old", "new_string": "new"})
    invoke(workspace, tool, args)
    assert original.read_text() == "old"
    assert (tmp_path / "alias").read_text() == "new"


def test_precise_edit_and_preflight(workspace, tmp_path):
    file = tmp_path / "file"
    file.write_text("one one\n中文", encoding="utf-8")
    starts = []
    for old in ("absent", "one"):
        with pytest.raises(ValueError):
            invoke(workspace, "edit_file", {"path": "file", "old_string": old, "new_string": "two"}, starts=starts)
    assert not starts and file.read_text() == "one one\n中文"
    result = invoke(workspace, "edit_file", {"path": "file", "old_string": "one", "new_string": "two",
                                          "replace_all": True}, starts=starts)
    assert result["replacements"] == 2 and starts == [True]
    invoke(workspace, "edit_file", {"path": "file", "old_string": "\n中文", "new_string": ""})
    assert file.read_text() == "two two"


def test_edit_final_size_preflight(workspace, tmp_path):
    file = tmp_path / "file"
    file.write_text("x" * 2000, encoding="utf-8")
    starts = []
    with pytest.raises(ValueError, match="exceed"):
        invoke(workspace, "edit_file", {"path": "file", "old_string": "x", "new_string": "y" * 1000,
                                       "replace_all": True}, starts=starts)
    assert starts == [] and file.read_text() == "x" * 2000


def test_file_size_and_encoding_limits(workspace, tmp_path):
    file = tmp_path / "file"
    file.write_bytes(b"\xff")
    starts = []
    with pytest.raises(ValueError, match="UTF-8"):
        invoke(workspace, "read_file", {"path": "file"}, starts=starts)
    file.write_bytes(b"x" * (MAX_FILE_BYTES + 1))
    with pytest.raises(ValueError, match="1 MiB"):
        invoke(workspace, "read_file", {"path": "file"}, starts=starts)
    file.write_bytes(b"x" * MAX_FILE_BYTES)
    assert len(invoke(workspace, "read_file", {"path": "file"})["content"]) == MAX_FILE_BYTES
    invoke(workspace, "write_file", {"path": "max", "content": "x" * MAX_FILE_BYTES})
    assert (tmp_path / "max").stat().st_size == MAX_FILE_BYTES
    assert not starts


def test_listing_nonrecursive_and_bounded(workspace, tmp_path):
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "nested").touch()
    (tmp_path / "file").write_bytes(b"123")
    starts = []
    result = invoke(workspace, "list_files", starts=starts)
    assert result == {"path": ".", "entries": [{"name": "file", "type": "file", "size_bytes": 3},
                                              {"name": "sub", "type": "directory"}],
                      "truncated": False, "skipped": 0}
    assert not starts
    assert invoke(workspace, "list_files", {"path": "sub"})["entries"][0]["name"] == "nested"
    for index in range(1001):
        (tmp_path / str(index)).touch()
    result = invoke(workspace, "list_files")
    assert len(result["entries"]) == 1000 and result["truncated"]


def test_parent_must_exist_and_file_must_be_regular(workspace, tmp_path):
    (tmp_path / "directory").mkdir()
    starts = []
    for args in ({"path": "missing/file", "content": "x"}, {"path": "directory", "content": "x"}):
        with pytest.raises((ValueError, FileNotFoundError)):
            invoke(workspace, "write_file", args, starts=starts)
    with pytest.raises(ValueError):
        invoke(workspace, "read_file", {"path": "directory"}, starts=starts)
    with pytest.raises(FileNotFoundError):
        invoke(workspace, "edit_file", {"path": "missing", "old_string": "x", "new_string": "y"}, starts=starts)
    assert not starts


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="POSIX FIFOs")
def test_fifo_rejected_without_blocking(workspace, tmp_path):
    os.mkfifo(tmp_path / "pipe")
    for name, args in (("read_file", {"path": "pipe"}),
                       ("write_file", {"path": "pipe", "content": "x", "overwrite": True}),
                       ("edit_file", {"path": "pipe", "old_string": "x", "new_string": "y"})):
        with pytest.raises(ValueError, match="regular"):
            invoke(workspace, name, args)
    assert invoke(workspace, "list_files")["skipped"] == 1


def symlink(link, target):
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except OSError:
        pytest.skip("Symlinks unavailable")


@pytest.mark.parametrize("fallback", [False, True])
def test_links_and_linked_ancestors_rejected(workspace, tmp_path, monkeypatch, fallback):
    if fallback:
        monkeypatch.setattr(workspace_module, "_DIR_FD", False)
    (tmp_path / "dir").mkdir()
    (tmp_path / "dir" / "file").write_text("safe", encoding="utf-8")
    symlink(tmp_path / "link", tmp_path / "dir" / "file")
    symlink(tmp_path / "linked-dir", tmp_path / "dir")
    starts = []
    for path in ("link", "linked-dir/file"):
        for tool, args in (("read_file", {"path": path}),
                           ("write_file", {"path": path, "content": "bad", "overwrite": True}),
                           ("edit_file", {"path": path, "old_string": "safe", "new_string": "bad"})):
            with pytest.raises(ValueError):
                invoke(workspace, tool, args, starts=starts)
    with pytest.raises(ValueError):
        Workspace(tmp_path / "linked-dir")
    (tmp_path / "dir" / "sub").mkdir()
    with pytest.raises(ValueError):
        Workspace(tmp_path / "linked-dir" / "sub")
    assert not starts
    assert invoke(workspace, "list_files")["skipped"] == 2


@pytest.mark.parametrize("fallback", [False, True])
def test_normal_operations_with_portable_fallback(workspace, tmp_path, monkeypatch, fallback):
    if fallback:
        monkeypatch.setattr(workspace_module, "_DIR_FD", False)
    (tmp_path / "dir").mkdir()
    invoke(workspace, "write_file", {"path": "dir/file", "content": "old"})
    invoke(workspace, "edit_file", {"path": "dir/file", "old_string": "old", "new_string": "new"})
    assert invoke(workspace, "read_file", {"path": "dir/file"})["content"] == "new"
    assert invoke(workspace, "list_files", {"path": "dir"})["entries"][0]["name"] == "file"


def test_reparse_point_rejected(workspace, tmp_path, monkeypatch):
    (tmp_path / "dir").mkdir()
    original = Path.lstat

    def lstat(path, *args, **kwargs):
        info = original(path, *args, **kwargs)
        if path == tmp_path / "dir":
            return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400)
        return info
    monkeypatch.setattr(Path, "lstat", lstat)
    with pytest.raises(ValueError):
        invoke(workspace, "list_files", {"path": "dir"})
    with pytest.raises(ValueError):
        Workspace(tmp_path / "dir")


@pytest.mark.parametrize("replacement", ["directory", "link"])
def test_root_replacement(workspace, tmp_path, replacement):
    old = tmp_path.with_name(tmp_path.name + "-old")
    tmp_path.rename(old)
    if replacement == "directory":
        tmp_path.mkdir()
    else:
        symlink(tmp_path, old)
    starts = []
    for tool, args in (("list_files", {}), ("write_file", {"path": "file", "content": "x"})):
        with pytest.raises(ValueError):
            invoke(workspace, tool, args, starts=starts)
    assert not starts and not (old / "file").exists()


@pytest.mark.skipif(os.name == "nt", reason="Windows refuses to rename a directory holding an open file")
def test_parent_replaced_during_staging(workspace, tmp_path, monkeypatch):
    parent = tmp_path / "dir"
    parent.mkdir()
    original = os.write

    def write(fd, data):
        result = original(fd, data)
        parent.rename(tmp_path / "moved")
        parent.mkdir()
        return result
    monkeypatch.setattr(os, "write", write)
    starts = []
    with pytest.raises(ValueError, match="directory changed"):
        invoke(workspace, "write_file", {"path": "dir/file", "content": "x"}, starts=starts)
    assert not starts and not (parent / "file").exists()
    remaining = list((tmp_path / "moved").iterdir())
    if workspace_module._DIR_FD:
        assert remaining == []
    else:
        assert len(remaining) == 1 and remaining[0].name.startswith(".agent-")


def test_create_only_race_does_not_overwrite(workspace, tmp_path, monkeypatch):
    if not workspace_module._DIR_FD:
        pytest.skip("Descriptor-relative hardlink installation")
    original = os.link

    def link(src, dst, **kwargs):
        (tmp_path / "file").write_text("competitor", encoding="utf-8")
        return original(src, dst, **kwargs)
    monkeypatch.setattr(os, "link", link)
    starts = []
    with pytest.raises(FileExistsError):
        invoke(workspace, "write_file", {"path": "file", "content": "ours"}, starts=starts)
    assert starts == [True]  # Unpredictable race after the commit boundary.
    assert (tmp_path / "file").read_text() == "competitor"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["file"]


def test_final_target_link_check_before_started(workspace, tmp_path, monkeypatch):
    (tmp_path / "file").write_text("safe", encoding="utf-8")
    (tmp_path / "outside").write_text("outside", encoding="utf-8")
    original = os.write

    def write(fd, data):
        result = original(fd, data)
        (tmp_path / "file").unlink()
        symlink(tmp_path / "file", tmp_path / "outside")
        return result
    monkeypatch.setattr(os, "write", write)
    starts = []
    with pytest.raises(ValueError, match="Linked"):
        invoke(workspace, "write_file", {"path": "file", "content": "new", "overwrite": True}, starts=starts)
    assert not starts and (tmp_path / "outside").read_text() == "outside"
    assert not list(tmp_path.glob(".agent-*.tmp"))


def test_read_detects_concurrent_change(workspace, tmp_path, monkeypatch):
    (tmp_path / "file").write_text("safe", encoding="utf-8")
    original = os.read

    def read(fd, size):
        data = original(fd, size)
        if data == b"safe":
            (tmp_path / "file").write_text("different", encoding="utf-8")
        return data
    monkeypatch.setattr(os, "read", read)
    with pytest.raises(ValueError, match="changed"):
        invoke(workspace, "read_file", {"path": "file"})


def test_file_checks_cancel_staging_and_preserve_original(workspace, tmp_path, monkeypatch):
    (tmp_path / "file").write_text("old", encoding="utf-8")
    written = []
    original = os.write

    def write(fd, data):
        written.append(True)
        return original(fd, data)

    def check():
        if written:
            raise Interrupted("Stop requested")
    monkeypatch.setattr(os, "write", write)
    starts = []
    with pytest.raises(Interrupted):
        invoke(workspace, "write_file", {"path": "file", "content": "x" * MAX_FILE_BYTES,
                                         "overwrite": True}, check=check, starts=starts)
    assert not starts and (tmp_path / "file").read_text() == "old"
    assert not list(tmp_path.glob(".agent-*.tmp"))


def test_cancel_before_dispatch_and_after_mutation(workspace, tmp_path):
    def stop():
        raise Interrupted("Stop requested")
    starts = []
    with pytest.raises(Interrupted):
        invoke(workspace, "list_files", check=stop, starts=starts)
    assert not starts

    def check():
        if starts:
            stop()
    with pytest.raises(Interrupted):
        invoke(workspace, "write_file", {"path": "file", "content": "done"}, check=check, starts=starts)
    assert starts == [True] and (tmp_path / "file").read_text() == "done"


def test_shell_disabled_in_backend(workspace, tmp_path):
    starts = []
    with pytest.raises(PermissionError, match="disabled"):
        invoke(workspace, "shell", {"command": python_command("raise SystemExit(0)")}, starts=starts)
    assert not starts


def test_shell_pipeline_cwd_environment_and_stdin(tmp_path, monkeypatch):
    workspace = Workspace(tmp_path, enable_shell=True)
    (tmp_path / "sub").mkdir()
    monkeypatch.setenv("WORKSPACE_TEST", "inherited")
    code = "import os,sys; print(os.getcwd()); print(os.environ['WORKSPACE_TEST']); print(repr(sys.stdin.read()))"
    starts = []
    result = invoke(workspace, "shell", {"command": python_command(code), "cwd": "sub"}, starts=starts)
    assert result["exit_code"] == 0 and not result["truncated"]
    assert result["stdout"].splitlines() == [str(tmp_path / "sub"), "inherited", "''"]
    assert result["stderr"] == "" and result["interpreter"] and starts == [True]
    pipeline = python_command("print('hello')") + " | " + python_command("import sys; print(sys.stdin.read().upper(), end='')")
    result = invoke(workspace, "shell", {"command": pipeline})
    assert result["stdout"].strip() == "HELLO" and result["exit_code"] == 0
    result = invoke(workspace, "shell", {"command": python_command("import os; print(os.getcwd())")})
    assert result["stdout"].strip() == str(tmp_path)


def test_shell_multiline_command_is_platform_dependent(tmp_path):
    workspace = Workspace(tmp_path, enable_shell=True)
    command = python_command("print('a', end='')") + "\n" + python_command("print('b', end='')")
    starts = []
    if os.name == "nt":
        with pytest.raises(ValueError, match="single line"):
            invoke(workspace, "shell", {"command": command}, starts=starts)
        assert not starts
    else:
        result = invoke(workspace, "shell", {"command": command}, starts=starts)
        assert result["stdout"] == "ab" and result["exit_code"] == 0


def test_shell_nonzero_and_bounded_output(tmp_path):
    workspace = Workspace(tmp_path, enable_shell=True)
    code = "import os; os.write(1,b'x'*200000); os.write(2,b'y'*200000); raise SystemExit(7)"
    result = invoke(workspace, "shell", {"command": python_command(code)})
    assert result["exit_code"] == 7 and result["truncated"]
    assert result["stdout"] == "x" * MAX_OUTPUT_BYTES
    assert result["stderr"] == "y" * MAX_OUTPUT_BYTES


def test_shell_invalid_cwd_and_spawn_failure_not_started(tmp_path, monkeypatch):
    workspace = Workspace(tmp_path, enable_shell=True)
    starts = []
    with pytest.raises(FileNotFoundError):
        invoke(workspace, "shell", {"command": "exit", "cwd": "missing"}, starts=starts)
    (tmp_path / "file").touch()
    with pytest.raises(ValueError):
        invoke(workspace, "shell", {"command": "exit", "cwd": "file"}, starts=starts)
    symlink(tmp_path / "linked", tmp_path)
    with pytest.raises(ValueError):
        invoke(workspace, "shell", {"command": "exit", "cwd": "linked"}, starts=starts)

    def fail(*args, **kwargs):
        raise OSError("spawn failed")
    monkeypatch.setattr(subprocess, "Popen", fail)
    with pytest.raises(OSError, match="spawn failed"):
        invoke(workspace, "shell", {"command": "exit"}, starts=starts)
    assert not starts


@pytest.mark.parametrize("kind", ["timeout", "cancel"])
def test_shell_interrupt_kills_and_reaps_child(tmp_path, monkeypatch, kind):
    workspace = Workspace(tmp_path, enable_shell=True)
    processes = []
    real_popen = subprocess.Popen

    def popen(*args, **kwargs):
        process = real_popen(*args, **kwargs)
        if kwargs.get("stdout") == subprocess.PIPE:
            processes.append(process)
        return process
    monkeypatch.setattr(subprocess, "Popen", popen)
    stop = threading.Event()
    bounded = deadline(0.25 if kind == "timeout" else 5)

    def check():
        bounded()
        if (tmp_path / "ready").exists():
            stop.set()
        if kind == "cancel" and stop.is_set():
            raise Interrupted("Stop requested")
    starts = []
    code = "from pathlib import Path; import time; Path('ready').touch(); time.sleep(30)"
    began = time.monotonic()
    with pytest.raises(Interrupted):
        invoke(workspace, "shell", {"command": python_command(code)}, check=check, starts=starts)
    assert time.monotonic() - began < 5
    assert starts == [True] and len(processes) == 1
    assert processes[0].poll() is not None
    assert processes[0].stdout.closed and processes[0].stderr.closed


def test_shell_started_callback_failure_still_cleans_up(tmp_path, monkeypatch):
    workspace = Workspace(tmp_path, enable_shell=True)
    processes = []
    original = subprocess.Popen

    def popen(*args, **kwargs):
        process = original(*args, **kwargs)
        if kwargs.get("stdout") == subprocess.PIPE:
            processes.append(process)
        return process

    def started():
        raise Interrupted("Stop immediately after launch")
    monkeypatch.setattr(subprocess, "Popen", popen)
    with pytest.raises(Interrupted):
        workspace.call("shell", {"command": python_command("import time; time.sleep(30)")}, deadline(), started)
    assert processes[0].poll() is not None and processes[0].stdout.closed


@pytest.mark.skipif(os.name != "posix", reason="POSIX process groups")
def test_shell_parent_exit_does_not_wait_for_background_pipe_holders(tmp_path):
    workspace = Workspace(tmp_path, enable_shell=True)
    background = python_command("import time; time.sleep(30)")
    began = time.monotonic()
    result = invoke(workspace, "shell", {"command": background + " & echo $!; exit 0"})
    assert result["exit_code"] == 0
    assert time.monotonic() - began < 3
    pid = int(result["stdout"].strip())
    # A killed orphan can remain a zombie until the host's init reaps it.
    status = Path(f"/proc/{pid}/stat")
    if status.exists():
        assert status.read_text().split(") ", 1)[1].split()[0] == "Z"
    else:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


@pytest.mark.skipif(os.name != "posix", reason="POSIX pipe cleanup")
def test_escaped_pipe_holder_does_not_leave_reader_threads(tmp_path):
    workspace = Workspace(tmp_path, enable_shell=True)
    # Deliberately escaping the process group is outside the shell containment
    # guarantee, but must not leave blocked readers or hang the executor.
    code = ("import subprocess,sys; from pathlib import Path; "
            "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], start_new_session=True); "
            "Path('pid').write_text(str(child.pid)); print('done',flush=True)")
    before = {thread.ident for thread in threading.enumerate()}
    began = time.monotonic()
    try:
        result = invoke(workspace, "shell", {"command": python_command(code)})
        assert result["stdout"].strip() == "done" and result["truncated"]
        assert time.monotonic() - began < 3
        assert {thread.ident for thread in threading.enumerate()} == before
    finally:
        if (tmp_path / "pid").exists():
            try:
                os.kill(int((tmp_path / "pid").read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_overlapping_edit_matches_are_ambiguous(workspace, tmp_path):
    (tmp_path / "file").write_text("aaa", encoding="utf-8")
    starts = []
    with pytest.raises(ValueError, match="ambiguous"):
        invoke(workspace, "edit_file", {"path": "file", "old_string": "aa", "new_string": "b"}, starts=starts)
    assert not starts
    result = invoke(workspace, "edit_file", {"path": "file", "old_string": "aa", "new_string": "b",
                                          "replace_all": True})
    assert result["replacements"] == 1
    assert (tmp_path / "file").read_text() == "ba"


def test_read_budget_checked_between_chunks(workspace, tmp_path, monkeypatch):
    (tmp_path / "file").write_bytes(b"x" * MAX_FILE_BYTES)
    reads = []
    original = os.read

    def read(fd, size):
        reads.append(size)
        return original(fd, size)

    def check():
        if reads:
            raise Interrupted("Stop after first read")
    monkeypatch.setattr(os, "read", read)
    with pytest.raises(Interrupted):
        invoke(workspace, "read_file", {"path": "file"}, check=check)
    assert reads == [65536]


def test_cancel_shell_with_continuous_output(tmp_path):
    workspace = Workspace(tmp_path, enable_shell=True)
    starts = []
    command = python_command("import os; [(os.write(1,b'x'*65536), os.write(2,b'y'*65536)) for _ in iter(int, 1)]")
    with pytest.raises(Interrupted):
        invoke(workspace, "shell", {"command": command}, check=deadline(0.25), starts=starts)
    assert starts == [True]
