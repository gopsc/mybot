"""Conversation transcript storage under ~/.mybot/sessions."""
import asyncio
import json
import os
import stat
import sys
import threading

import pytest

from pymybot import session_log
from pymybot.session_log import SessionLog, create_session_log


def read_events(path):
    text = (path / "transcript.jsonl").read_text(encoding="utf-8")
    return [json.loads(line) for line in text.splitlines()]


class FakeExecutor:
    def __init__(self, result=None):
        self.stop_event = threading.Event()
        self.result = result or {"ok": True, "executed": False, "state": "completed",
                                 "data": {"value": 7}}
        self.closed = False

    async def start(self, *, deadline=None):
        return {"robot": "test", "hardware": []}

    async def call(self, name, arguments, *, timeout):
        return self.result

    def cancel(self):
        self.stop_event.set()

    async def close(self):
        self.closed = True


def test_transcript_and_images_are_written(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    monkeypatch.setenv("MYBOT_SESSION_LOG", "1")
    log = create_session_log(robot="robots/r.sql", model="openai-chat:m", mode="test")
    try:
        log.write("user", text="hello")
        image = {"data": b"\x89PNG\r\n\x1a\n" + b"x" * 10, "media_type": "image/png"}
        log.write_image("capture_image", image, turn=1)
        log.write_image("capture_image", image, turn=1)
        log.write("assistant", text="done")
    finally:
        log.close()

    assert log.path.is_relative_to(tmp_path / "sessions")
    events = read_events(log.path)
    assert [event["type"] for event in events] == [
        "session_start", "user", "image", "image", "assistant", "session_end"]
    assert events[2]["sha256"] == events[3]["sha256"]
    files = list((log.path / "images").iterdir())
    assert len(files) == 1 and files[0].suffix == ".png"
    meta = json.loads((log.path / "meta.json").read_text(encoding="utf-8"))
    assert meta["robot"] == "robots/r.sql"
    assert meta["model"] == "openai-chat:m"
    assert meta["format"] == 1


def test_environment_can_disable_logging(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")
    assert create_session_log() is None
    assert not (tmp_path / "sessions").exists()


def test_default_root_is_dot_mybot(monkeypatch, tmp_path):
    monkeypatch.delenv("MYBOT_HOME", raising=False)
    monkeypatch.setattr(session_log.Path, "home", lambda: tmp_path)
    assert session_log.session_root() == tmp_path / ".mybot" / "sessions"


def test_large_events_are_bounded(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    log = SessionLog()
    try:
        log.write("tool_result", data={"text": "x" * (session_log.MAX_STRING * 2)})
    finally:
        log.close()
    lines = (log.path / "transcript.jsonl").read_text(encoding="utf-8").splitlines()
    assert all(len(line.encode("utf-8")) <= session_log.MAX_EVENT_BYTES for line in lines)
    assert "chars]" in lines[1]


def test_oversized_image_is_recorded_but_not_stored(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    monkeypatch.setattr(session_log, "MAX_IMAGE_BYTES", 4)
    log = SessionLog()
    try:
        log.write_image("capture_image", {"data": b"12345", "media_type": "image/jpeg"})
    finally:
        log.close()
    events = read_events(log.path)
    assert events[-2]["type"] == "image"
    assert events[-2]["omitted"] == "size"
    assert not any((log.path / "images").iterdir())


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permissions")
def test_posix_permissions_are_restricted(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    log = SessionLog()
    try:
        assert stat.S_IMODE(log.path.stat().st_mode) == 0o700
        assert stat.S_IMODE((log.path / "images").stat().st_mode) == 0o700
        assert stat.S_IMODE((log.path / "transcript.jsonl").stat().st_mode) == 0o600
        assert stat.S_IMODE((log.path / "meta.json").stat().st_mode) == 0o600
    finally:
        log.close()


def test_list_and_prune_sessions(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    created = []
    for index in range(4):
        log = SessionLog(robot=f"r{index}.sql", mode="test")
        log.write("user", text=f"turn {index}")
        log.close()
        created.append(log.path)

    sessions = session_log.list_sessions()
    assert len(sessions) == 4
    assert {item["id"] for item in sessions} == {path.name for path in created}
    assert all(item["bytes"] > 0 for item in sessions)

    dry = session_log.prune_sessions(keep=2, dry_run=True)
    assert dry["dry_run"] is True and len(dry["deleted"]) == 2
    assert all(path.exists() for path in created)

    real = session_log.prune_sessions(keep=2)
    assert len(real["deleted"]) == 2 and real["kept"] == 2 and real["bytes_freed"] > 0
    remaining = {path.name for path in created if path.exists()}
    assert len(remaining) == 2
    assert {item["id"] for item in session_log.list_sessions()} == remaining


def test_delete_sessions_by_id(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    created = []
    for _ in range(3):
        log = SessionLog()
        log.close()
        created.append(log.path)

    dry = session_log.delete_sessions([created[0].name, "missing"], dry_run=True)
    assert dry["dry_run"] is True and dry["deleted"] == [created[0].name]
    assert dry["errors"] == ["missing"] and created[0].exists()

    real = session_log.delete_sessions([created[0].name, created[1].name])
    assert set(real["deleted"]) == {created[0].name, created[1].name}
    assert real["bytes_freed"] > 0 and real["errors"] == []
    assert not created[0].exists() and not created[1].exists() and created[2].exists()

    invalid = session_log.delete_sessions(["../escape"])
    assert invalid["deleted"] == [] and invalid["errors"] == ["../escape"]
    for ids in ([], None, ["x"] * (session_log.MAX_KEEP + 1)):
        with pytest.raises(ValueError):
            session_log.delete_sessions(ids)


def test_prune_ignores_unknown_directories_and_symlinks(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    log = SessionLog()
    log.close()
    root = tmp_path / "sessions"
    (root / "notes").mkdir()
    fake = root / "20260101-000000-deadbeef"
    fake.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    link = root / "20250101-000000-deadbeef"
    try:
        link.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("symlinks unavailable")
    result = session_log.prune_sessions(keep=1)
    assert result["deleted"] == [] and fake.exists() and (root / "notes").exists()
    assert outside.exists()


def test_prune_older_than_days(monkeypatch, tmp_path):
    import time

    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    created = []
    for index in range(3):
        log = SessionLog(robot=f"r{index}.sql")
        log.write("user", text="old")
        log.close()
        created.append(log.path)
    old = time.time() - 40 * 86400
    for path in created[:2]:
        for item in [path, *path.rglob("*")]:
            os.utime(item, (old, old))
    result = session_log.prune_sessions(keep=1, older_than_days=30)
    assert set(result["deleted"]) == {created[0].name, created[1].name}
    assert len(session_log.list_sessions()) == 1


@pytest.mark.skipif(os.name == "nt", reason="active-process probe is POSIX-only")
def test_prune_skips_live_session(monkeypatch, tmp_path):
    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    old = SessionLog(robot="old.sql")
    old.write("user", text="still running")
    old.close()
    new = SessionLog(robot="new.sql")
    new.write("user", text="newer")
    new.close()

    transcript = old.path / "transcript.jsonl"
    lines = [line for line in transcript.read_text(encoding="utf-8").splitlines()
             if '"type":"session_end"' not in line]
    transcript.write_text("\n".join(lines) + "\n", encoding="utf-8")
    meta_path = old.path / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["pid"] = os.getpid()
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    past = old.path.stat().st_mtime - 3600
    for item in [old.path, *old.path.rglob("*")]:
        os.utime(item, (past, past))

    result = session_log.prune_sessions(keep=1)
    assert old.path.exists()
    assert old.path.name in result["skipped"]
    assert new.path.exists()


def test_prune_validates_arguments():
    for keep in (0, -1, True, "2", session_log.MAX_KEEP + 1):
        with pytest.raises(ValueError):
            session_log.prune_sessions(keep=keep)
    with pytest.raises(ValueError):
        session_log.prune_sessions(older_than_days=-1)


def test_agent_session_records_text_turn(monkeypatch, tmp_path):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai import models
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    from pymybot.agent import AgentConfig, AgentSession

    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("done")])

    async def scenario():
        log = SessionLog(robot="r.sql", model="openai-chat:m", mode="test")
        session = AgentSession(FakeExecutor(), FunctionModel(respond), AgentConfig(), session_log=log)
        result = await session.ask("hello")
        assert result["output"] == "done"
        await session.close()
        return log

    log = asyncio.run(scenario())
    events = read_events(log.path)
    assert [event["type"] for event in events] == [
        "session_start", "user", "intent", "assistant", "usage", "session_end"]
    assert events[1]["text"] == "hello" and events[1]["turn"] == 1
    assert events[2]["name"] == "chat"
    assert events[3]["text"] == "done"


def test_agent_session_records_tool_call_and_image(monkeypatch, tmp_path):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    from pymybot.agent import AgentConfig, AgentSession

    monkeypatch.setenv("MYBOT_HOME", str(tmp_path))
    executor = FakeExecutor({"ok": True, "executed": True, "state": "completed",
                             "data": {"outputs": [{"result": "OK"}]},
                             "images": [{"data": b"image-bytes", "media_type": "image/png"}]})

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("unused")])

    async def scenario():
        log = SessionLog(robot="r.sql", model="openai-chat:m", mode="test")
        session = AgentSession(executor, FunctionModel(respond),
                               AgentConfig(allow_actions=True), session_log=log)
        result = await session.dispatch("run_action_script", {"script": "a.mt"})
        assert result["data"] == {"outputs": [{"result": "OK"}]}
        await session.close()
        return log

    log = asyncio.run(scenario())
    events = read_events(log.path)
    assert [event["type"] for event in events] == [
        "session_start", "tool_call", "tool_result", "image", "session_end"]
    assert events[1]["arguments"] == {"script": "a.mt"}
    assert events[2]["data"] == {"outputs": [{"result": "OK"}]}
    images = list((log.path / "images").iterdir())
    assert len(images) == 1 and images[0].read_bytes() == b"image-bytes"
