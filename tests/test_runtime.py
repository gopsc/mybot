import threading
import time
from pathlib import Path

import pytest

from conftest import usable_symlink
from pymybot.errors import BudgetExceeded, DriverError, ScriptError
from pymybot.hardware import Budget, ensure_ok
from pymybot.runtime import LuaState


class NoHardware:
    def call(self, operation, *args, **kwargs):
        raise AssertionError("Test must not touch hardware")

    def release_owner(self, owner):
        pass


@pytest.fixture
def state(tmp_path):
    runtime = LuaState([tmp_path], NoHardware(), threading.Event())
    yield runtime
    runtime.close()


def test_luajit_and_python_bridge_hidden(state):
    assert state.lua.eval("jit.version").startswith("LuaJIT")
    assert state.lua.eval("python == nil and debug == nil")
    assert state.lua.eval("os.execute == nil and io.open == nil and package.loadlib == nil")
    assert state.lua.eval("require('ffi') ~= nil")
    ok, _ = state.lua.eval("pcall(require, 'python')")
    assert not ok


def test_error_recovery_and_return_contract(state, tmp_path):
    path = tmp_path / "test.lua"
    path.write_text('function call(d) if d.bad then error("bad") end return {result="OK", value=2} end')
    state.load(path)
    with pytest.raises(DriverError, match="bad"):
        state.call("call", {"bad": True})
    assert state.call("call", {}) == {"result": "OK", "value": 2}
    assert ensure_ok({"delay": 1}) == {"delay": 1}
    for value in ({}, None, {"result": "maybe"}, {"result": 4}, {"result": " ERR "}):
        with pytest.raises(DriverError):
            ensure_ok(value)


def test_values_arrays_and_cycles(state):
    value = state.lua.eval('{result="OK", arr={[0]=10,[2]=20}, empty={}, mixed={[2]=3,a=4}}')
    assert state.from_lua(value, outer=True) == {"result": "OK", "arr": [10, 20], "empty": [], "mixed": {"2": 3, "a": 4}}
    with pytest.raises(ScriptError, match="NUL"):
        state.to_lua({"bad": "x\x00y"})
    cycle = state.lua.eval("(function() local t={} t.self=t return t end)()")
    with pytest.raises(DriverError, match="nesting"):
        state.from_lua(cycle)


def test_loader_rejects_escape_and_symlinks(state, tmp_path):
    with pytest.raises(DriverError, match="outside"):
        state.load(tmp_path.parent / "outside.lua")
    with pytest.raises(ScriptError, match="escapes"):
        state._resolve("../outside.lua")
    target = tmp_path / "valid.lua"
    target.write_text("return {}")
    link = tmp_path / "linked.lua"
    if not usable_symlink(link, target):
        pytest.skip("Platform cannot create usable symbolic links")
    with pytest.raises(DriverError, match="Symlink"):
        state.load(link)


def test_budget_interrupts_lua_and_runtime_is_reusable(state, tmp_path):
    path = tmp_path / "test.lua"
    path.write_text('function call(d) if d.spin then while true do end end return {result="OK"} end')
    state.load(path)
    with pytest.raises(BudgetExceeded):
        state.call("call", {"spin": True}, budget=Budget(timeout=0.02))
    assert state.call("call", {})["result"] == "OK"


def test_secret_environment_hidden(state, monkeypatch):
    monkeypatch.setenv("BOT4CJ_LLM_KEY", "not-a-real-key")
    assert state.lua.eval("os.getenv('BOT4CJ_LLM_KEY')") is None


@pytest.mark.parametrize("operation,args", [
    ("i2c_open", ["ftdi://ftdi:232h/1"]),
    ("spi_open", ["/dev/spidev0.0"]),
    ("uart_open", ["COM3", 115200]),
    ("camera_capture", [1, {}]),
    ("shell_open", [1000]),
])
def test_physical_hardware_requires_opt_in(state, operation, args):
    with pytest.raises(DriverError, match="allow-hardware"):
        state._hal_call(operation, *(state.to_lua(v) for v in args))


def test_result_null_is_not_an_absent_result():
    with pytest.raises(DriverError, match="string"):
        ensure_ok({"result": None})


def test_missing_optional_module_preserves_pcall_fallback(state, tmp_path):
    path = state._resolve("optional.lua")
    assert Path(path) == tmp_path / "optional.lua"
    ok, error = state.lua.eval("function(path) return pcall(dofile, path) end")(path)
    assert not ok and "optional.lua" in error


def test_timer_sleep_honors_budget_and_cleanup_ignores_stop(tmp_path):
    import time
    from pymybot.hal import HALManager

    stop = threading.Event()
    hal = HALManager()
    with_runtime = LuaState([tmp_path], hal, stop)
    path = tmp_path / "Timer.lua"
    path.write_text('''
function call(d) __hal_call("sleep_ms", 10000); return {result="OK"} end
function destroy(d) __hal_call("sleep_ms", 1); return {result="OK"} end
''')
    try:
        with_runtime.load(path)
        started = time.monotonic()
        with pytest.raises(BudgetExceeded):
            with_runtime.call("call", {}, budget=Budget(stop, .02))
        assert time.monotonic() - started < 1
        stop.set()
        assert with_runtime.call("destroy", {})["result"] == "OK"
    finally:
        with_runtime.close()
        hal.close()


def test_lua_uart_polling_receives_call_budget(tmp_path):
    pytest.importorskip("serial")
    from pymybot.hal import HALManager

    hal = HALManager()
    state = LuaState([tmp_path], hal, threading.Event())
    path = tmp_path / "Uart.lua"
    path.write_text('''
function call(d)
    local h = __hal_call("uart_open", "loop://", 115200)
    local data = __hal_call("uart_read", h, 1, 350)
    return {result="OK", n=#data}
end
''')
    try:
        state.load(path)
        started = time.monotonic()
        with pytest.raises(BudgetExceeded):
            state.call("call", {}, budget=Budget(timeout=0.02))
        assert time.monotonic() - started < 0.2
    finally:
        state.close()
        hal.close()


def test_close_releases_handles_owned_by_the_state(tmp_path):
    pytest.importorskip("serial")
    from pymybot.hal import HALManager

    hal = HALManager()
    path = tmp_path / "Open.lua"
    path.write_text('function call(d) return {result="OK", '
                    'fd=__hal_call("uart_open", "loop://", 115200)} end')
    state = LuaState([tmp_path], hal, threading.Event())
    try:
        state.load(path)
        assert state.call("call", {})["fd"] >= 0
        assert len(hal._handles) == 1 and len(hal._buses) == 1
    finally:
        state.close()
    assert not hal._handles and not hal._buses
    hal.close()


def test_shared_bus_survives_until_last_owner_closes(tmp_path):
    pytest.importorskip("serial")
    from pymybot.hal import HALManager

    hal = HALManager()
    path = tmp_path / "Open.lua"
    path.write_text('function call(d) return {result="OK", '
                    'fd=__hal_call("uart_open", "loop://", 115200)} end')
    first = LuaState([tmp_path], hal, threading.Event())
    second = LuaState([tmp_path], hal, threading.Event())
    try:
        for state in (first, second):
            state.load(path)
            assert state.call("call", {})["fd"] >= 0
        assert len(hal._handles) == 2 and len(hal._buses) == 1
        bus = next(iter(hal._buses.values()))
        first.close()
        assert len(hal._handles) == 1 and not bus.closed
        second.close()
        assert not hal._handles and not hal._buses and bus.closed
    finally:
        first.close()
        second.close()
        hal.close()


def test_http_gate_loopback_without_allow_hardware(tmp_path):
    from pymybot.hal import HALManager

    hal = HALManager()
    state = LuaState([tmp_path], hal, threading.Event())
    probe = tmp_path / "probe.lua"
    probe.write_text('function call(d) return {result="OK", fd=__hal_call("http_open", d.base, 100)} end')
    try:
        state.load(probe)
        for base in ("http://127.0.0.1:1/", "https://localhost:8443/api",
                     "http://[::1]:8000/", "http://127.0.0.1/api/v1"):
            assert state.call("call", {"base": base})["fd"] >= 0
        for base in ("http://qsont.me:8004/", "https://example.com/", "http://192.168.1.5:8000/",
                     "http://0.0.0.0:8000/", "loop://", "not a url"):
            with pytest.raises(DriverError, match="loopback"):
                state.call("call", {"base": base})
    finally:
        state.close()
        hal.close()


def test_http_gate_offloop_open_with_allow_hardware(tmp_path):
    import socket

    from pymybot.hal import HALManager

    hal = HALManager()
    state = LuaState([tmp_path], hal, threading.Event(), allow_hardware=True)
    probe = tmp_path / "probe.lua"
    # open never connects; the follow-up request to a closed port must return
    # a plain ERR table instead of raising.
    probe.write_text('''
function call(d)
    local fd = __hal_call("http_open", d.base, 300)
    return __hal_call("http_request", fd, "GET", "/", nil, nil)
end
''')
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    try:
        state.load(probe)
        out = state.call("call", {"base": f"http://127.0.0.1:{port}/"})
        assert out["result"] == "ERR" and "message" in out
    finally:
        state.close()
        hal.close()


def test_shell_gate_runs_with_allow_hardware(tmp_path):
    from pymybot.hal import HALManager

    hal = HALManager()
    state = LuaState([tmp_path], hal, threading.Event(), allow_hardware=True)
    probe = tmp_path / "probe.lua"
    probe.write_text('''
function call(d)
    local fd = __hal_call("shell_open", 5000)
    return __hal_call("shell_run", fd, d.cmd)
end
''')
    try:
        state.load(probe)
        out = state.call("call", {"cmd": "echo gate-ok"})
        assert out["result"] == "OK" and out["code"] == 0
        assert "gate-ok" in out["out"]
    finally:
        state.close()
        hal.close()
