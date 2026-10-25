"""Conversation transcript storage under ~/.mybot/sessions."""
import asyncio
import json
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
        "session_start", "user", "assistant", "usage", "session_end"]
    assert events[1]["text"] == "hello" and events[1]["turn"] == 1
    assert events[2]["text"] == "done"


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
