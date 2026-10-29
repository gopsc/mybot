"""Sandbox backend selection and command construction."""
from __future__ import annotations

from pathlib import Path

import pytest

from pymybot import sandbox
from pymybot.agent_workspace import Workspace
from pymybot.security import SecurityError


@pytest.fixture(autouse=True)
def _reset_probe(monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", None)


def test_off_keeps_the_workspace_jail():
    argv, backend = sandbox.wrap_shell(["/bin/sh", "-c", "echo hi"], mode="off",
                                       workspace=Path("/tmp"), cwd="/tmp")
    assert backend == "workspace" and argv == ["/bin/sh", "-c", "echo hi"]
    assert sandbox.resolve_backend("off") == "workspace"


def test_auto_falls_back_when_bubblewrap_is_unusable(monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", False)
    argv, backend = sandbox.wrap_shell(["/bin/sh", "-c", "echo hi"], mode="auto",
                                       workspace=Path("/tmp"), cwd="/tmp")
    assert backend == "workspace" and argv[0] == "/bin/sh"
    status = sandbox.backend_status()
    assert status["status"] == "warning" and status["optional"] is True


def test_explicit_bwrap_fails_instead_of_running_unsandboxed(monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", False)
    with pytest.raises(SecurityError, match="bubblewrap"):
        sandbox.wrap_shell(["/bin/sh", "-c", "echo hi"], mode="bwrap",
                           workspace=Path("/tmp"), cwd="/tmp")


def test_bwrap_argv_has_isolation_and_cleared_environment(monkeypatch, tmp_path):
    monkeypatch.setattr(sandbox, "_USABLE", True)
    monkeypatch.setattr(sandbox.shutil, "which", lambda name: "/usr/bin/bwrap")
    argv, backend = sandbox.wrap_shell(["/bin/sh", "-c", "echo hi"], mode="bwrap",
                                       workspace=tmp_path, cwd=tmp_path)
    assert backend == "bwrap" and argv[0] == "/usr/bin/bwrap"
    for flag in ("--unshare-net", "--unshare-pid", "--clearenv", "--die-with-parent"):
        assert flag in argv
    assert "--ro-bind" in argv and argv[argv.index("--ro-bind") + 1] == "/"
    assert "--bind" in argv and str(tmp_path) in argv
    assert argv[argv.index("--chdir") + 1] == str(tmp_path)
    assert argv[-4:] == ["--", "/bin/sh", "-c", "echo hi"]


def test_workspace_rejects_unknown_sandbox(tmp_path):
    with pytest.raises(SecurityError, match="sandbox"):
        Workspace(tmp_path, enable_shell=True, sandbox="container")


def test_workspace_auto_shell_reports_active_backend(tmp_path, monkeypatch):
    monkeypatch.setattr(sandbox, "_USABLE", False)
    workspace = Workspace(tmp_path, enable_shell=True, sandbox="auto")
    started = []
    result = workspace.call("shell", {"command": "echo hi"},
                            lambda: None, lambda: started.append(True))
    assert result["sandbox"] == "workspace"
    assert result["stdout"].strip() == "hi" and started == [True]


def test_agent_config_validates_sandbox_mode():
    pytest.importorskip("pydantic_ai")
    from pymybot.agent import AgentConfig, AgentConfigurationError

    assert AgentConfig(sandbox_mode="BWRAP").sandbox_mode == "bwrap"
    with pytest.raises(AgentConfigurationError):
        AgentConfig(sandbox_mode="docker")
