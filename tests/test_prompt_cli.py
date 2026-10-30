"""Prompt management integration: real JSON CLI, isolated home, no model or robot."""
import asyncio
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
from types import SimpleNamespace

import pytest

from pymybot import cli, paths, serve

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    home = tmp_path / "operator-home"
    monkeypatch.setenv("MYBOT_HOME", str(home))
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")
    monkeypatch.setenv("MYBOT_MODEL", "invalid:no-model-may-be-created")
    return home


def command(*arguments, code=0):
    result = subprocess.run([sys.executable, "-m", "pymybot", *arguments], cwd=ROOT,
                            env=os.environ.copy(), input="", capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    assert result.returncode == code, result.stderr + result.stdout
    # json.loads rejects extra envelopes, progress output and stray diagnostics.
    payload = json.loads(result.stdout)
    assert payload["ok"] is (code == 0)
    if code == 0:
        assert payload["command"] in {"prompts", "doctor"}
    return payload


def layer_path(listing, *, editable=True):
    layer = next(item for item in listing["layers"] if bool(item["editable"]) is editable)
    return Path(listing["root"]) / layer["file"], layer


def test_first_use_list_copies_defaults_without_model_or_robot(isolated_home):
    assert not isolated_home.exists()
    listing = command("prompts", "list")
    assert Path(listing["root"]) == isolated_home / "prompts"
    assert listing["layers"]
    for layer in listing["layers"]:
        data = (Path(listing["root"]) / layer["file"]).read_bytes()
        assert data == (paths.asset_path("prompts") / layer["file"]).read_bytes()
        assert layer["sha256"] == hashlib.sha256(data).hexdigest()
        assert layer["bytes"] == len(data)
        assert not layer["missing"] and not layer["modified"]
        assert {"id", "file", "editable", "max_bytes", "mtime"} <= layer.keys()


def test_prompt_command_does_not_construct_robot(monkeypatch, capsys):
    def forbidden(*args, **kwargs):
        pytest.fail("Prompt management must not construct a robot")

    monkeypatch.setattr(cli, "Robot", forbidden)
    monkeypatch.setitem(sys.modules, "pymybot.agent", None)
    assert cli.main(["--no-agent", "prompts", "list"]) == 0
    assert json.loads(capsys.readouterr().out)["command"] == "prompts"


@pytest.mark.parametrize("arguments", [
    ("prompts",), ("prompts", "restore", "--all", "--missing-only"),
    ("prompts", "restore", "--all"), ("prompts", "restore", "--unknown"),
])
def test_bad_or_unapproved_commands_are_single_json_usage_errors(arguments, isolated_home):
    result = command(*arguments, code=2)
    assert result["error"]["type"] == "UsageError"
    assert not isolated_home.exists()


def test_missing_only_preserves_edits_and_refills_missing_layer():
    listing = command("prompts", "list")
    edited, entry = layer_path(listing)
    edited.write_text("Operator customization\n", encoding="utf-8")
    missing_entry = next(item for item in listing["layers"] if item["id"] != entry["id"])
    missing = Path(listing["root"]) / missing_entry["file"]
    missing.unlink()
    command("prompts", "restore", "--missing-only")
    assert edited.read_text(encoding="utf-8") == "Operator customization\n"
    assert missing.read_bytes() == (paths.asset_path("prompts") / missing.name).read_bytes()
    after = command("prompts", "list")
    assert next(item for item in after["layers"] if item["id"] == entry["id"])["modified"]


def test_default_restore_is_missing_only():
    listing = command("prompts", "list")
    edited, _ = layer_path(listing)
    edited.write_text("Keep this edit\n", encoding="utf-8")
    command("prompts", "restore")
    assert edited.read_text(encoding="utf-8") == "Keep this edit\n"


def test_list_reports_missing_without_repairing_existing_home():
    listing = command("prompts", "list")
    target, entry = layer_path(listing)
    target.unlink()
    after = command("prompts", "list")
    assert next(item for item in after["layers"] if item["id"] == entry["id"])["missing"]
    assert not target.exists()


@pytest.mark.parametrize("corruption", ["safety", "manifest"])
def test_listing_remains_available_for_corrupt_runtime(corruption):
    listing = command("prompts", "list")
    target, entry = layer_path(listing, editable=False)
    if corruption == "manifest":
        target = Path(listing["root"]) / "manifest.json"
    target.write_text("damaged runtime\n", encoding="utf-8")
    after = command("prompts", "list")
    assert len(after["layers"]) == len(listing["layers"])
    if corruption == "safety":
        assert next(item for item in after["layers"] if item["id"] == entry["id"])["modified"]
    assert target.read_text(encoding="utf-8") == "damaged runtime\n"
    failed = command("prompts", "restore", "--missing-only", code=1)
    assert failed["error"]["type"] == "SecurityError"
    assert target.read_text(encoding="utf-8") == "damaged runtime\n"


@pytest.mark.parametrize("corruption", ["editable", "safety", "manifest"])
def test_restore_all_backs_up_and_recovers_even_corrupt_runtime(corruption):
    listing = command("prompts", "list")
    target, _ = layer_path(listing, editable=corruption != "safety")
    if corruption == "manifest":
        target = Path(listing["root"]) / "manifest.json"
    target.write_text("corrupt or customized runtime\n", encoding="utf-8")
    refused = command("prompts", "restore", "--all", code=2)
    assert refused["error"]["type"] == "UsageError"
    assert target.read_text(encoding="utf-8") == "corrupt or customized runtime\n"
    restored = command("prompts", "restore", "--all", "--yes")
    backup = Path(restored["backup"])
    assert backup.is_dir() and backup != Path(listing["root"])
    assert (backup / target.name).read_text(encoding="utf-8") == "corrupt or customized runtime\n"
    assert target.read_bytes() == (paths.asset_path("prompts") / target.name).read_bytes()


@pytest.mark.parametrize("reply, expected", [("yes\n", 0), ("n\n", 2), ("", 2)])
def test_interactive_restore_confirmation_stays_off_stdout(reply, expected, monkeypatch, capsys):
    stdin = io.StringIO(reply)
    monkeypatch.setattr(stdin, "isatty", lambda: True)
    monkeypatch.setattr(sys, "stdin", stdin)
    assert cli.main(["prompts", "restore", "--all"]) == expected
    captured = capsys.readouterr()
    assert json.loads(captured.out)["ok"] is (expected == 0)
    assert "[y/N]" in captured.err


def test_doctor_validates_packaged_defaults_without_runtime_home(isolated_home):
    diagnosis = command("doctor")
    entry = diagnosis["assets"]["prompts"]
    assert entry["exists"] and entry["files"] and entry["valid"]
    assert {"version", "layers", "hash"} <= entry["validation"].keys()
    assert not isolated_home.exists()


@pytest.mark.parametrize("corruption", ["missing", "manifest", "safety"])
def test_doctor_marks_invalid_bundle_unhealthy_without_writes(corruption, tmp_path, monkeypatch, capsys,
                                                            isolated_home):
    defaults = tmp_path / "defaults"
    if corruption != "missing":
        shutil.copytree(paths.asset_path("prompts"), defaults)
        if corruption == "manifest":
            (defaults / "manifest.json").write_text("{}", encoding="utf-8")
        else:
            from pymybot.prompts import PromptLibrary
            library = PromptLibrary(home=tmp_path / "unused", defaults=defaults)
            entry = next(item for item in library.layers if str(item["id"]) == "0")
            (defaults / entry["file"]).write_text("tampered safety\n", encoding="utf-8")
    original = cli.asset_path
    monkeypatch.setattr(cli, "asset_path", lambda name: defaults if name == "prompts" else original(name))
    assert cli.main(["doctor"]) == 0
    diagnosis = json.loads(capsys.readouterr().out)
    assert not diagnosis["healthy"]
    assert not diagnosis["assets"]["prompts"]["valid"]
    assert diagnosis["assets"]["prompts"]["error"]["type"]
    assert not isolated_home.exists() and not (tmp_path / "unused").exists()


@pytest.mark.parametrize("entry", ["agent", "gui"])
@pytest.mark.parametrize("disabled", [False, True])
def test_no_prompt_stats_cli_boolean(entry, disabled):
    arguments = [entry]
    if entry == "agent":
        arguments += ["--robot", "unused.sql", "--task", "hello"]
    if disabled:
        arguments += ["--no-prompt-stats"]
    assert cli.parse_args(arguments).no_prompt_stats is disabled


def test_serve_autostats_defaults_type_validation_and_conversation_key(monkeypatch):
    async def scenario():
        output = io.StringIO()
        server = serve.Server(output, threading.Event(), enable_session_log=False)
        opened, closed = [], []

        class Session:
            events = []
            executor = SimpleNamespace(cancel=lambda: None)

            async def ask(self, task):
                return {"answer": "offline"}

            async def close(self):
                closed.append(True)

        class Client:
            async def close(self):
                pass

        async def open_agent(key):
            opened.append(key.copy())
            return {"session": Session(), "client": Client()}

        monkeypatch.setattr(server, "open_agent", open_agent)
        params = {"task": "hello", "robot": "unused.sql", "scriptsDir": "unused"}
        try:
            for ident, extra in enumerate(({}, {"autoStats": True}, {"autoStats": False},
                                           {"autoStats": False}, {}), 1):
                server.requests[ident] = {"hooks": [], "cancel": threading.Event()}
                await server.handle(ident, "agent.ask", {**params, **extra}, threading.Event())
            assert [key["autoStats"] for key in opened] == [True, False, True]
            assert len(closed) == 2
            for ident, value in enumerate((0, 1, "false", [], {}), 10):
                await server.handle(ident, "agent.ask", {**params, "autoStats": value}, threading.Event())
            replies = [json.loads(line) for line in output.getvalue().splitlines()]
            assert all(reply["error"]["code"] == serve.INVALID_PARAMS
                       for reply in replies if isinstance(reply.get("id"), int) and reply["id"] >= 10)
            assert len(opened) == 3
        finally:
            await server.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("auto_stats", [True, False])
def test_serve_propagates_auto_stats_into_real_agent_config(auto_stats, monkeypatch):
    pytest.importorskip("pydantic_ai")
    from pymybot import agent

    configs = []

    class StopBeforeModel(Exception):
        pass

    def create_model(config):
        configs.append(config)
        raise StopBeforeModel

    monkeypatch.setattr(agent, "create_model", create_model)

    async def scenario():
        server = serve.Server(io.StringIO(), threading.Event(), enable_session_log=False)
        original = server.open_agent

        async def opening(key):
            with pytest.raises(StopBeforeModel):
                await original(key)
            raise StopBeforeModel

        monkeypatch.setattr(server, "open_agent", opening)
        try:
            with pytest.raises(StopBeforeModel):
                await server.m_agent_ask(1, serve.Params({"task": "hello", "robot": "unused.sql",
                                                        "scriptsDir": "unused", "autoStats": auto_stats}),
                                         threading.Event())
            assert len(configs) == 1 and configs[0].auto_stats is auto_stats
        finally:
            await server.shutdown()

    asyncio.run(scenario())
