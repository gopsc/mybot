import math
import threading
import time
from pathlib import Path

import pytest

from pymybot.daemon import DaemonVariable, Slot, validate_config
from pymybot.errors import DriverError, ScriptError
from pymybot.hardware import Registry

MODULES = Path(__file__).resolve().parents[1] / "modules"


class FakeRuntime:
    def __init__(self, daemon, *, setup=None, tick=None, cleanup=None):
        self.daemon = daemon
        self.setup = setup
        self.tick = tick
        self.cleanup = cleanup
        self.thread_ids = [threading.get_ident()]
        self.calls = []
        self.closed = threading.Event()
        self.globals = {"__mpath": {"resolve": lambda path: str(MODULES / path)}}

    def load(self, path):
        self.thread_ids.append(threading.get_ident())
        assert isinstance(path, Path)
        if self.setup:
            self.setup(self.daemon)

    def has_function(self, name):
        return name == "daemon_tick" or (name == "daemon_cleanup" and self.cleanup is not None)

    def call(self, name, data=None, budget=None):
        self.thread_ids.append(threading.get_ident())
        self.calls.append((name, data))
        assert data is None  # Both daemon functions receive zero Lua arguments.
        if budget:
            budget.check()
        if name == "daemon_tick":
            if self.tick:
                self.tick(self.daemon)
            else:
                self.daemon.slot.publish([1.5, -2.25])
        elif self.cleanup:
            self.cleanup(self.daemon)

    def close(self):
        self.thread_ids.append(threading.get_ident())
        self.closed.set()


def fake_daemon(name="probe", config=None, registry=None, stop_event=None, **hooks):
    registry = registry if registry is not None else Registry()
    runtimes = []

    def factory(**kwargs):
        runtime = FakeRuntime(**kwargs, **hooks)
        runtimes.append(runtime)
        return runtime

    daemon = DaemonVariable(name, {"chunk": "lib/daemon_probe.lua", **(config or {})},
                            registry, factory, stop_event or threading.Event())
    registry.add(daemon)
    return daemon, runtimes


@pytest.mark.parametrize("key,value", [
    ("maxvals", "0"), ("maxvals", "1025"), ("maxvals", "1.5"), ("maxvals", "NaN"),
    ("interval", "0"), ("interval", "3600001"), ("interval", "5ms"), ("interval", True),
    ("interval", ""), ("interval", " 5"), ("proto", "i2"), ("sign", "16x"),
    ("fields", "A||B"), ("fields", "|A"), ("fields", "A|"), ("fields", "A:bad"),
    ("fields", "A:f:f"), ("fields", ""), ("fields", ":f"), ("extra", "a;proto=i2c"),
    ("extra", "a\x00b"), ("bad=key", "1"), ("mode", "3x"), ("speed", "NaN"),
    ("sources", ""), ("sources", "a||b"), ("sources", "a,a"), ("sources", "probe"),
    ("chunk", "../escape.lua"), ("chunk", "/tmp/escape.lua"), ("chunk", "C:\\escape.lua"),
    ("devices", "SyntheticI2C@0x23@VALUE||SyntheticI2C@0x24@VALUE"),
    ("devices", "SyntheticI2C@0x80@VALUE"), ("devices", "SyntheticI2C@wat@VALUE"),
    ("devices", "SyntheticI2C@0x23@VALUE@no_equal"),
])
def test_invalid_configuration_precedes_runtime(key, value):
    with pytest.raises(ScriptError):
        fake_daemon(config={key: value})


def test_config_defaults_capacity_and_equals():
    daemon, _ = fake_daemon(config={"sign": "-", "extra": "a=b=c", "fields": "A:s16|B:f,C:float"})
    assert daemon.slot.capacity == 64
    assert daemon.interval_ms == 5
    assert "sign=" not in daemon.globals()["DAEMON_CONFIG"]
    assert "extra=a=b=c" in daemon.globals()["DAEMON_CONFIG"]
    assert validate_config({"chunk": "x.lua", "maxvals": "1024", "interval": "3600000"})
    with pytest.raises(ScriptError, match="field count"):
        validate_config({"chunk": "x.lua", "maxvals": "1", "fields": "a,b"})
    with pytest.raises(ScriptError, match="total field count"):
        validate_config({"chunk": "x.lua", "maxvals": "1", "devices": "SyntheticI2C@35@VALUE|SyntheticI2C@92@VALUE"})
    result = validate_config({"chunk": "lib/sensor_daemon_multi.lua", "proto": "virt",
                              "devices": "SyntheticI2C@35@VALUE@extra=a=b"})
    assert result["devices"].endswith("extra=a=b")


def test_sources_must_be_previous_daemons_and_keep_strong_references():
    registry = Registry()
    a, _ = fake_daemon("a", registry=registry)
    b, _ = fake_daemon("b", registry=registry)
    agg, _ = fake_daemon("agg", {"sources": " a, b "}, registry)
    assert agg.config["sources"] == "a|b"
    assert agg.globals()["DAEMON_PEER_SLOTS"] == {"a": a.slot.id, "b": b.slot.id}
    registry.remove("a")
    assert agg.peers["a"] is a
    with pytest.raises(ScriptError, match="previously"):
        fake_daemon("missing", {"sources": "unknown"}, registry)
    registry.add(type("Scalar", (), {"name": "scalar", "kind": "vars"})())
    with pytest.raises(ScriptError, match="previously"):
        fake_daemon("notdaemon", {"sources": "scalar"}, registry)
    with pytest.raises(DriverError, match="read-only"):
        agg.bridge("publish", b.slot.id, [99])
    with pytest.raises(DriverError, match="unauthorized"):
        agg.bridge("capacity", 999999999)


def test_slot_snapshot_validation_and_counter_wrap():
    slot = Slot(2)
    slot.publish([1, 2, 3])
    sample = slot.snapshot()
    assert sample["values"] == [1, 2]
    sample["values"][0] = 100
    assert slot.snapshot()["values"] == [1, 2]
    for value in (True, "1", float("inf"), float("nan"), None):
        with pytest.raises(DriverError):
            slot.publish([value])
    slot.publish([])
    assert slot.snapshot()["nvals"] == 0
    with slot.condition:
        slot.count = 0x7FFFFFFE
    slot.publish([3])
    assert slot.snapshot()["count"] == 0
    slot.fail(-8)
    slot.fail(0)
    assert slot.snapshot()["status"] == -8
    with pytest.raises(DriverError, match="permanently"):
        slot.publish([5])


def test_concurrent_publish_snapshots_are_atomic():
    slot = Slot(128)
    start = threading.Barrier(3)
    finished = threading.Event()
    failures = []

    def writer():
        start.wait()
        for n in range(1, 2001):
            slot.publish([n] * 128)
        finished.set()

    def reader():
        start.wait()
        while not finished.is_set():
            snapshot = slot.snapshot()
            values = snapshot["values"]
            if values and (len(set(values)) != 1 or values[0] != snapshot["count"]):
                failures.append(snapshot)

    threads = [threading.Thread(target=writer), threading.Thread(target=reader)]
    for thread in threads:
        thread.start()
    start.wait()
    for thread in threads:
        thread.join(3)
        assert not thread.is_alive()
    assert not failures
    assert slot.snapshot()["count"] == 2000


def test_worker_owns_runtime_and_cleanup_is_not_quiesced():
    cleaned = []
    daemon, runtimes = fake_daemon(config={"interval": "3600000"},
                                   cleanup=lambda d: cleaned.append((d.stopping, d.quiesced, d.cleaning_up)))
    main_thread = threading.get_ident()
    daemon.build()
    daemon.build()  # idempotent, no second Lua state
    try:
        sample = daemon.wait_for_sample(timeout=2)
        assert sample == {"result": "OK", "status": "OK", "count": 1, "nvals": 2,
                          "values": [1.5, -2.25], "v0": 1.5, "v1": -2.25}
        daemon.request_stop()
        assert not daemon.quiesced
        with pytest.raises(DriverError, match="stopped"):
            daemon.read()
    finally:
        before = time.monotonic()
        daemon.destroy()
    assert time.monotonic() - before < 0.5
    assert cleaned == [(True, False, True)]
    assert len(runtimes) == 1 and runtimes[0].closed.is_set()
    assert len(set(runtimes[0].thread_ids)) == 1
    assert runtimes[0].thread_ids[0] != main_thread
    daemon.destroy()
    with pytest.raises(DriverError, match="stopped"):
        daemon.build()


@pytest.mark.parametrize("phase", ["setup", "tick", "cleanup"])
def test_worker_exceptions_are_permanent_and_runtime_closed(phase):
    def fail(_):
        raise RuntimeError(f"broken {phase}")

    daemon, runtimes = fake_daemon(**{phase: fail})
    daemon.build()
    if phase == "cleanup":
        daemon.wait_for_sample(timeout=2)
        daemon.request_stop()
    assert daemon._done.wait(2)
    try:
        with pytest.raises(DriverError, match=f"broken {phase}"):
            daemon.read()
        assert runtimes[0].closed.is_set()
    finally:
        daemon.destroy()


def test_negative_status_never_returns_stale_sample():
    def tick(daemon):
        daemon.slot.publish([7])
        daemon.bridge("set_status", daemon.slot.id, -9)
        daemon.bridge("set_status", daemon.slot.id, 0)

    daemon, _ = fake_daemon(config={"interval": "3600000"}, tick=tick)
    daemon.build()
    try:
        assert daemon._done.wait(2)
        with pytest.raises(DriverError, match="status -9"):
            daemon.play({})
    finally:
        daemon.destroy()


def test_wait_is_interrupted_by_global_stop():
    stop = threading.Event()
    daemon, _ = fake_daemon(stop_event=stop, tick=lambda _: None)
    daemon.build()
    try:
        with pytest.raises(TimeoutError):
            daemon.wait_for_sample(timeout=0.01)
        stop.set()
        with pytest.raises(DriverError, match="stopped"):
            daemon.wait_for_sample(timeout=10)
    finally:
        daemon.destroy()


@pytest.mark.parametrize("phase", ["setup", "tick", "cleanup"])
def test_teardown_is_bounded_and_never_closes_running_runtime(phase):
    entered, release = threading.Event(), threading.Event()

    def block(_):
        entered.set()
        assert release.wait(3)

    daemon, runtimes = fake_daemon(**{phase: block})
    daemon.destroy_timeout = 0.04
    daemon.build()
    if phase == "cleanup":
        daemon.wait_for_sample(timeout=2)
        daemon.request_stop()
    assert entered.wait(2)
    try:
        before = time.monotonic()
        with pytest.raises(DriverError, match="teardown timed out"):
            daemon.destroy()
        assert time.monotonic() - before < 0.5
        assert daemon.quiesced
        assert not runtimes[0].closed.is_set()
        with pytest.raises(DriverError, match="teardown timed out"):
            daemon.destroy()  # does not grant a fresh grace period
    finally:
        release.set()
        assert daemon._done.wait(2)
        daemon.destroy()
    assert runtimes[0].closed.is_set()
    assert len(set(runtimes[0].thread_ids)) == 1


@pytest.fixture
def lua_factory(synthetic_modules):
    pytest.importorskip("lupa.luajit21")
    from pymybot.hal import HALManager
    from pymybot.runtime import LuaState

    hal = HALManager()
    stop = threading.Event()
    created = []

    def make(name, config, registry):
        def runtime_factory(**kwargs):
            return LuaState(synthetic_modules, hal, stop, **kwargs)
        daemon = DaemonVariable(name, config, registry, runtime_factory, stop)
        registry.add(daemon)
        created.append(daemon)
        return daemon

    yield make
    try:
        for daemon in created:
            daemon.request_stop()
        for daemon in reversed(created):
            daemon.destroy()
    finally:
        hal.close()


def test_synthetic_virtual_sensor_and_multi_peer_aggregation(lua_factory):
    registry = Registry()
    sensor = lua_factory("single", {"chunk": "lib/sensor_daemon.lua", "driver": "SyntheticI2C",
                                    "proto": "virt", "addr": "0x31", "sign": "16",
                                    "fields": "VALUE:float", "interval": "3600000"}, registry)
    multi = lua_factory("pair", {"chunk": "lib/sensor_daemon_multi.lua", "proto": "virt", "sign": "16",
                                 "devices": "SyntheticI2C@0x31@VALUE:f,TAG:f@tag=11|SyntheticI2C@0x32@VALUE:f,TAG:f@tag=29"}, registry)
    agg = lua_factory("agg", {"chunk": "lib/sensor_aggregate.lua", "sources": "single,pair",
                              "maxvals": "5"}, registry)
    sensor.build()
    multi.build()
    assert sensor.wait_for_sample(timeout=5)["values"] == [10240.25]
    assert multi.wait_for_sample(timeout=5)["values"] == [10240.25, 11, 10240.75, 29]
    agg.build()
    sample = agg.wait_for_sample(timeout=5)
    assert sample["nvals"] == 5
    assert sample["values"] == [sample[f"v{i}"] for i in range(5)]
    assert sample["values"] == [10240.25, 10240.25, 11, 10240.75, 29]
    assert all(isinstance(v, float) for v in sample["values"])
    sensor.request_stop()
    assert agg._done.wait(2)
    with pytest.raises(DriverError, match="permanently failed"):
        agg.read()


def test_original_aggregate_overflow_and_latest_not_synchronized(lua_factory):
    registry = Registry()
    a = lua_factory("a", {"chunk": "lib/daemon_probe.lua", "interval": "3600000"}, registry)
    b = lua_factory("b", {"chunk": "lib/daemon_probe.lua", "interval": "3600000"}, registry)
    # No synchronization barrier: preexisting samples with different counts work.
    a.slot.publish([1, 2])
    b.slot.publish([0])
    b.slot.publish([3])
    agg = lua_factory("agg", {"chunk": "lib/sensor_aggregate.lua", "sources": "a|b", "maxvals": "3"}, registry)
    agg.build()
    assert agg.wait_for_sample(timeout=3)["values"] == [1, 2, 3]
    small = lua_factory("small", {"chunk": "lib/sensor_aggregate.lua", "sources": "a|b", "maxvals": "2"}, registry)
    small.build()
    assert small._done.wait(2)
    with pytest.raises(DriverError, match="status -2"):
        small.read()


def test_lua_bridge_only_exposes_tables_and_numbers(lua_factory):
    registry = Registry()
    daemon = lua_factory("probe", {"chunk": "lib/daemon_probe.lua", "maxvals": "128"}, registry)
    # This test owns this separate, never-started runtime in the calling thread.
    runtime = daemon.runtime_factory(daemon=daemon)
    try:
        runtime.lua.execute('''
            local P = dofile(__mpath.resolve("lib/pthread.lua"))
            assert(type(__daemon_call) == "function")
            assert(type(DAEMON_SLOT_ADDR) == "number")
            assert(type(DAEMON_SLOT_LAYOUT) == "table")
            local slot = P.slot_attach(DAEMON_SLOT_ADDR)
            assert(type(slot) == "table" and type(slot[0]) == "table")
            assert(slot[0].capacity == 128 and slot.capacity == 128)
            assert(P.addr(P.ptr(P.addr(slot))) == P.addr(slot))
            local values = {}
            for i=1,128 do values[i] = i / 2 end
            P.publish(slot, values)
            local sample, count = P.latest(slot)
            assert(type(sample) == "table" and #sample == 128 and count == 1)
            assert(sample[128] == 64 and slot[0].values[0] == 0.5)
            local extra = P.slot_new(2)
            P.publish(extra, {1, 2, 3})
            assert(#P.latest(extra) == 2)
            assert(not pcall(P.publish, extra, {"bad"}))
            assert(not pcall(P.slot_attach, -1))
            assert(not pcall(P.slot_attach, 9007199254740992))
            P.signal_stop(extra)
            assert(extra.stop == 1 and not P.quiesced(extra))
            P.init_slot(extra)
            assert(P.should_stop(extra))
            assert(not pcall(P.latest, extra))
            P.quiesce(extra)
            assert(P.quiesced(extra))
            local big = P.slot_new(1024)
            for i=1,1024 do values[i] = i end
            P.publish(big, values)
            local large = P.latest(big)
            assert(#large == 1024 and large[1024] == 1024)
            assert(not pcall(P.slot_new, 1025))
        ''')
    finally:
        runtime.close()


def test_unmodified_runtime_embedded_model_integration(synthetic_modules):
    pytest.importorskip("lupa.luajit21")
    from pymybot.hal import HALManager
    from pymybot.runtime import LuaState

    assert all(not (root / "lib/virtbus/synthetici2c.lua").exists() for root in synthetic_modules)
    hal, stop, registry = HALManager(), threading.Event(), Registry()
    daemon = DaemonVariable("real", {"chunk": "lib/sensor_daemon.lua", "driver": "SyntheticI2C",
                                     "proto": "virt", "addr": "49", "fields": "COUNT:f|VALUE:f"},
                            registry, lambda **kw: LuaState(synthetic_modules, hal, stop, **kw), stop)
    registry.add(daemon)
    daemon.build()
    try:
        sample = daemon.wait_for_sample(timeout=3)
        count = 40960 + sample["count"]
        assert sample["values"] == [count, count / 4]
    finally:
        daemon.destroy()
        hal.close()
    assert daemon._done.is_set() and not daemon._thread.is_alive()
    assert not hal._handles and not hal._buses


@pytest.fixture
def multi_runtime(lua_factory, monkeypatch):
    """Run the real multi chunk synchronously; any non-virtual I/O fails the test."""
    from pymybot.hal import HALManager

    def no_hardware(self, operation, *args):
        assert operation == "sleep_ms", f"Unexpected physical HAL operation: {operation}"
        return 0  # Virtual models do not need wall-clock sleeps.

    monkeypatch.setattr(HALManager, "call", no_hardware)
    states = []

    def make(devices):
        daemon = lua_factory("manual", {"chunk": "lib/sensor_daemon_multi.lua",
                                        "proto": "virt", "devices": devices}, Registry())
        state = daemon.runtime_factory(daemon=daemon)
        states.append(state)
        state.lua.execute('''
            dofile(__mpath.resolve("lib/HAL.lua"))
            -- Observe loaded chunks without wrapping their execution or copying entries.
            driver_chunks = {}
            local load = loadfile
            loadfile = function(path)
                local f, message = load(path)
                if f then driver_chunks[#driver_chunks + 1] = f end
                return f, message
            end
        ''')
        state.load(MODULES / "lib/sensor_daemon_multi.lua")
        return daemon, state

    yield make
    for state in states:
        try:
            # Some tests inspect teardown themselves; do not destroy twice after restore().
            if state.has_function("daemon_cleanup") and state.globals["__BOT4CJ_VIRTBUS"]._injected:
                state.call("daemon_cleanup")
            assert state.lua.eval("__BOT4CJ_VIRTBUS.fd_count()") == 0
            assert not state.globals["__BOT4CJ_VIRTBUS"]._injected
            assert not state.hal._handles and not state.hal._buses
        finally:
            state.close()


def assert_multi_environments(state):
    state.lua.execute('''
        assert(#driver_chunks == 2)
        local a, b = getfenv(driver_chunks[1]), getfenv(driver_chunks[2])
        assert(a ~= b and a ~= _G and b ~= _G)
        for _, name in ipairs({"build", "call", "destroy"}) do
            assert(type(rawget(a, name)) == "function", name .. " missing from first instance")
            assert(type(rawget(b, name)) == "function", name .. " missing from second instance")
            assert(a[name] ~= b[name], name .. " shared between instances")
            assert(rawget(_G, name) == nil, name .. " leaked into shared globals")
        end
        for _, name in ipairs({"require_driver", "arg_table", "err", "i2c_pair",
                              "num_or", "virt_prepare", "i2c_set_addr", "i2c_write_multi"}) do
            assert(rawget(a, name) == nil and rawget(b, name) == nil)
            assert(a[name] == _G[name] and b[name] == _G[name], name .. " must stay shared")
        end
        assert(getfenv(a.i2c_pair) == _G)
        assert(a.__BOT4CJ_HAL == b.__BOT4CJ_HAL)
        assert(a.__BOT4CJ_VIRTBUS == b.__BOT4CJ_VIRTBUS)
        assert(a.i2c_write_multi == __BOT4CJ_VIRTBUS.v_i2c_write_multi)
        assert(__BOT4CJ_VIRTBUS.bus_contract == __BOT4CJ_BUS_CONTRACT)
        assert(__BOT4CJ_VIRTBUS.fd_count() == 1)
    ''')


@pytest.mark.parametrize("reverse", [False, True], ids=["bh1750-first", "ads1115-first"])
def test_multi_real_heterogeneous_driver_isolation(multi_runtime, reverse):
    specs = ["BH1750@0x23@LUX:f", "ADS1115@0x48@voltage:f"]
    if reverse:
        specs.reverse()
    daemon, state = multi_runtime("|".join(specs))  # Deliberately leave path at its default.
    assert daemon.slot.snapshot()["status"] == 0
    assert_multi_environments(state)
    state.lua.execute('''
        local light = __BOT4CJ_VIRTBUS.devs[0x23].model
        local adc = __BOT4CJ_VIRTBUS.devs[0x48].model
        assert(light.state.power and light.state.mode == "H")
        assert(#light.cmds == 2 and light.cmds[1] == 1 and light.cmds[2] == 0x10)
        assert(#adc:config_writes() == 1 and adc:config_shadow() == 0x4583)
        local opened = __BOT4CJ_VIRTBUS.txlog[1]
        assert(opened.dir == "open" and opened.bytes.raw == "/dev/i2c-1")
    ''')
    phase = 2 * math.pi / 32
    lux = math.floor(15002 + 3000 * math.sin(int(reverse) * phase) + 0.5) / 1.2
    volts = 1.65 + 0.25 * math.sin(int(not reverse) * phase)
    volts = math.floor(volts * 32768 / 2.048 + 0.5) * 2.048 / 32768
    expected = [volts, lux] if reverse else [lux, volts]
    for count in (1, 2, 3):
        state.call("daemon_tick")
        sample = daemon.slot.snapshot()
        assert sample["status"] == 0 and sample["count"] == count and sample["nvals"] == 2
        assert sample["values"] == pytest.approx(expected)
    state.call("daemon_cleanup")
    state.lua.execute('''
        local light = __BOT4CJ_VIRTBUS.devs[0x23].model
        local adc = __BOT4CJ_VIRTBUS.devs[0x48].model
        assert(not light.state.power and light.cmds[#light.cmds] == 0)
        assert(#adc:config_writes() == 5 and adc:start_count() == 3)
        assert(adc:config_shadow() == 0x4583)
    ''')


@pytest.mark.parametrize("first,second", [(('H', 69, 1), ('H2', 138, 0.5)),
                                          (('L', 31, 4), ('H', 69, 1))])
def test_multi_same_driver_configuration_isolation(multi_runtime, first, second):
    specs = [f"BH1750@{addr}@LUX:f@mode={mode}@mtreg={mtreg}"
             for addr, (mode, mtreg, _) in zip(("0x23", "0x5C"), (first, second))]
    daemon, state = multi_runtime("|".join(specs))
    assert daemon.slot.snapshot()["status"] == 0
    expected = [math.floor(15002 + 3000 * math.sin(i * 2 * math.pi / 32) + 0.5)
                * lsb * 69 / (1.2 * mtreg)
                for i, (_, mtreg, lsb) in enumerate((first, second))]
    for count in (1, 2):
        state.call("daemon_tick")
        assert daemon.slot.snapshot()["count"] == count
        assert daemon.slot.snapshot()["values"] == pytest.approx(expected)
    assert_multi_environments(state)
    # Rebuilding only the first instance must not replace the second's local configuration.
    state.lua.execute('''
        local a, b = getfenv(driver_chunks[1]), getfenv(driver_chunks[2])
        local fd = i2c_open("/dev/i2c-1")
        local pa, pb = {fd=fd, address=0x23, mode="H2", mtreg=69}, {fd=fd, address=0x5C}
        local light = __BOT4CJ_VIRTBUS.devs[0x23].model
        local other = __BOT4CJ_VIRTBUS.devs[0x5C].model
        local before = assert(b.call(pb).LUX)
        assert(a.build(pa).result == "OK")
        assert(a.call(pa).LUX == light.count / 2.4)
        assert(b.call(pb).LUX == before)
        assert(a.destroy(pa).result == "OK")
        assert(not light.state.power and other.state.power)
        assert(b.call(pb).LUX == before)
        assert(b.destroy(pb).result == "OK")
        assert(not other.state.power)
        i2c_close(fd)
    ''')


@pytest.mark.parametrize("explicit_state", [False, True], ids=["default-state", "spec-state"])
def test_require_driver_instance_entry_and_state_isolation(lua_factory, explicit_state):
    daemon = lua_factory("contract", {"chunk": "lib/daemon_probe.lua"}, Registry())
    state = daemon.runtime_factory(daemon=daemon)
    try:
        state.globals["explicit_state"] = explicit_state
        state.lua.execute('''
            dofile(__mpath.resolve("lib/drv_common.lua"))
            local source = [[
                local spec = {
                    name = "state-probe",
                    state = explicit_state and {} or nil,
                    build = function(ctx, data)
                        ctx.state.tag = data.tag
                        ctx.state.calls = 0
                        ctx.state.destroyed = false
                        return {result="OK", state=ctx.state}
                    end,
                    call = function(ctx, data)
                        ctx.state.calls = ctx.state.calls + 1
                        return {result="OK", state=ctx.state}
                    end,
                    destroy = function(ctx, data)
                        ctx.state.destroyed = true
                        return {result="OK", state=ctx.state}
                    end,
                }
                assert(require_driver("i2c", spec) == spec)
                declared_state = spec.state
            ]]
            local function load_instance()
                local env = setmetatable({}, {__index=_G})
                local chunk = assert(loadstring(source))
                setfenv(chunk, env)
                chunk()
                return env
            end
            local a, b = load_instance(), load_instance()
            local vbus = __BOT4CJ_VIRTBUS
            vbus.attach("first", 0x31, {})
            vbus.attach("second", 0x32, {})
            vbus.inject()
            local fd = i2c_open("/dev/i2c-1")
            local pa, pb = {fd=fd, address=0x31, tag=11}, {fd=fd, address=0x32, tag=29}
            local sa, sb = a.build(pa).state, b.build(pb).state
            assert(sa ~= sb, "driver state shared between instances")
            assert(sa.tag == 11 and sb.tag == 29)
            if explicit_state then
                assert(sa == a.declared_state and sb == b.declared_state)
            end
            for _, name in ipairs({"build", "call", "destroy"}) do
                assert(type(rawget(a, name)) == "function")
                assert(type(rawget(b, name)) == "function" and a[name] ~= b[name])
                assert(rawget(_G, name) == nil)
                assert(a[name]("invalid").result == "ERR")
            end
            assert(a.call(pa).state == sa and a.call(pa).state == sa)
            assert(b.call(pb).state == sb and sa.calls == 2 and sb.calls == 1)
            assert(a.destroy(pa).state == sa and sa.destroyed and not sb.destroyed)
            assert(b.call(pb).state == sb and sb.calls == 2)
            assert(a.build(pa).state == sa and not sa.destroyed and sa.calls == 0)
            assert(sb.calls == 2 and sb.tag == 29)
            assert(b.destroy(pb).state == sb and sb.destroyed and not sa.destroyed)
            i2c_close(fd)
            vbus.restore()
        ''')
    finally:
        state.close()
