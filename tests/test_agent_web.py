"""Bounded web fetch/search tools and their agent/CLI wiring."""
from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

import pytest

from pymybot.agent_web import WebError, WebPolicy, fetch, search

pytest.importorskip("httpx")
pytest.importorskip("bs4")


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return None

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/page"):
            body = (b"<html><head><title>Demo</title></head><body>"
                    b"<script>bad()</script><h1>Hello</h1><p>world</p></body></html>")
            self._send(200, "text/html; charset=utf-8", body)
        elif self.path.startswith("/bin"):
            self._send(200, "application/octet-stream", b"\x00\x01")
        elif self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", "/page")
            self.end_headers()
        elif self.path.startswith("/loop"):
            self.send_response(302)
            self.send_header("Location", "/loop")
            self.end_headers()
        elif self.path.startswith("/big"):
            self._send(200, "text/html", b"<p>" + b"x" * 5000 + b"</p>")
        elif self.path.startswith("/search"):
            payload = {"results": [
                {"title": "A", "url": "https://example.com/a", "content": "first"},
                {"title": "B", "url": "javascript:alert(1)", "content": "skip"},
                {"title": "C", "url": "https://example.com/c", "content": "second"},
            ]}
            body = json.dumps(payload).encode()
            self._send(200, "application/json", body)
        else:
            self._send(404, "text/plain", b"missing")


@pytest.fixture()
def base_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _loopback():
    return WebPolicy(allow_loopback=True)


def test_fetch_refuses_private_and_malformed_targets():
    with pytest.raises(WebError, match="loopback"):
        fetch("https://127.0.0.1/")
    with pytest.raises(WebError, match="private"):
        fetch("https://192.168.1.1/")
    with pytest.raises(WebError, match="credentials"):
        fetch("https://user:pass@example.com/")
    with pytest.raises(WebError, match="Only http"):
        fetch("file:///etc/passwd")
    with pytest.raises(WebError, match="HTTPS"):
        fetch("http://example.com/")


def test_fetch_extracts_text_and_follows_redirect(base_url):
    data = fetch(f"{base_url}/page", policy=_loopback())
    assert data["status"] == 200 and data["title"] == "Demo"
    assert "Hello" in data["text"] and "world" in data["text"]
    assert "bad()" not in data["text"]
    redirected = fetch(f"{base_url}/redirect", policy=_loopback())
    assert redirected["final_url"] == f"{base_url}/page"


def test_fetch_limits_redirects_types_size_and_status(base_url):
    with pytest.raises(WebError, match="Too many redirects"):
        fetch(f"{base_url}/loop", policy=_loopback())
    with pytest.raises(WebError, match="Unsupported content type"):
        fetch(f"{base_url}/bin", policy=_loopback())
    with pytest.raises(WebError, match="HTTP 404"):
        fetch(f"{base_url}/missing", policy=_loopback())
    big = fetch(f"{base_url}/big", policy=WebPolicy(allow_loopback=True, max_bytes=100))
    assert big["truncated"] is True and big["bytes"] <= 100


def test_search_uses_configured_endpoint_and_skips_invalid_urls(base_url):
    data = search("robot", endpoint=base_url, policy=_loopback())
    assert data["provider"] == "searx"
    assert [item["title"] for item in data["results"]] == ["A", "C"]
    with pytest.raises(WebError, match="not configured"):
        search("robot", endpoint="", policy=_loopback())


def test_agent_registers_web_tools_only_when_enabled():
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.models.test import TestModel

    from pymybot.agent import make_agent

    plain = make_agent(TestModel())
    assert "web_fetch" not in plain._function_toolset.tools
    fetch_only = make_agent(TestModel(), enable_web=True)
    assert "web_fetch" in fetch_only._function_toolset.tools
    assert "web_search" not in fetch_only._function_toolset.tools
    both = make_agent(TestModel(), enable_web=True, web_search_enabled=True)
    assert {"web_fetch", "web_search"} <= set(both._function_toolset.tools)


def test_dispatch_requires_approval_and_never_calls_the_network():
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    from pymybot.agent import AgentConfig, AgentSession

    class Executor:
        def __init__(self):
            self.stop_event = threading.Event()
            self.calls = []
            self.records = []

        async def start(self, *, deadline=None):
            return {"ok": True}

        async def call(self, name, arguments, *, timeout):
            self.calls.append((name, arguments))
            return {"ok": True, "executed": False, "state": "completed", "data": {}}

        def cancel(self):
            self.stop_event.set()

        async def close(self):
            return None

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        executor = Executor()
        session = AgentSession(executor, FunctionModel(respond), AgentConfig(enable_web=True))
        try:
            result = await session.dispatch("web_fetch", {"url": "https://example.com/"})
            assert result["state"] == "not_executed" and not result["ok"]
            assert executor.calls == []
            return result
        finally:
            await session.close()

    assert asyncio_result(scenario())["executed"] is False


def asyncio_result(coro):
    import asyncio
    return asyncio.run(coro)


def test_preapproved_web_tool_uses_the_bounded_runner(monkeypatch):
    pytest.importorskip("pydantic_ai")
    from pydantic_ai.messages import ModelResponse, TextPart
    from pydantic_ai.models.function import FunctionModel

    from pymybot.agent import AgentConfig, AgentSession
    from pymybot import agent_web

    monkeypatch.setattr(agent_web, "run_tool",
                        lambda name, arguments, *, timeout, search_endpoint="":
                        {"title": "Doc", "text": "body", "results": []})

    class Executor:
        stop_event = threading.Event()

        async def start(self, *, deadline=None):
            return {"ok": True}

        async def call(self, name, arguments, *, timeout):
            raise AssertionError("web tools must not reach the robot executor")

        def cancel(self):
            pass

        async def close(self):
            pass

    async def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def scenario():
        session = AgentSession(Executor(), FunctionModel(respond),
                               AgentConfig(enable_web=True, allow_web=True))
        try:
            return await session.dispatch("web_fetch", {"url": "https://example.com/"})
        finally:
            await session.close()

    result = asyncio_result(scenario())
    assert result["ok"] and result["data"]["title"] == "Doc"


def test_config_cli_and_gui_surfaces(tmp_path):
    pytest.importorskip("pydantic_ai")
    from pymybot.agent import AgentConfig, AgentConfigurationError
    from pymybot.cli import UsageError, parse_args
    from pymybot.gui.config import GuiConfig

    with pytest.raises(AgentConfigurationError):
        AgentConfig(allow_web=True)
    with pytest.raises(AgentConfigurationError):
        AgentConfig(enable_web=True, search_endpoint="http://example.com")
    args = parse_args(["agent", "--robot", "x.sql", "--task", "hi", "--web",
                       "--allow-web", "--search-endpoint", "https://searx.example"])
    assert args.web and args.allow_web and args.search_endpoint.endswith("searx.example")
    with pytest.raises(UsageError):
        parse_args(["agent", "--robot", "x.sql", "--task", "hi", "--allow-web"])
    gui = parse_args(["gui", "--web", "--search-endpoint", "https://searx.example"])
    assert gui.web and gui.search_endpoint.endswith("searx.example")
    path = tmp_path / "settings.json"
    GuiConfig(enable_web=True, search_endpoint="https://searx.example", allow_web=True).store(path)
    loaded = GuiConfig.load(path)
    assert loaded.enable_web and loaded.search_endpoint.endswith("searx.example")
    assert loaded.allow_web is False  # runtime grant is never persisted
