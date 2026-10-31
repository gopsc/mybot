import threading

import pytest

from pymybot.daemon import DaemonVariable
from pymybot.errors import ControllerError
from pymybot.hal import HALManager
from pymybot.hardware import Registry
from pymybot.robot import Robot
from pymybot.native import PythonState
from pymybot.runtime import LuaState

PROTOCOLS = ["I2C", "SPI", "UART"]


def direct_sql(protocol):
    columns, values = {
        "I2C": ("path String", "'virt-synthetic'"),
        "SPI": ("path String,spi_mode Number,bits Number,speed Number,delay Number",
                "'virt-synthetic',0,8,1000000,0"),
        "UART": ("path String,baud Number", "'virt-synthetic',9600"),
    }[protocol]
    names = ",".join(column.split()[0] for column in columns.split(","))
    return f'''
CREATE TABLE {protocol}(name String,proto String,{columns});
INSERT INTO {protocol}(name,proto,{names}) VALUES('bus','virt',{values});
CREATE TABLE Synthetic{protocol}(name String,{protocol} String,proto String,address Number,path String,tag Number);
INSERT INTO Synthetic{protocol}(name,{protocol},proto,address,path,tag) VALUES('a','$bus','virt',49,'virt-synthetic',11);
INSERT INTO Synthetic{protocol}(name,{protocol},proto,address,path,tag) VALUES('b','$bus','virt',49,'virt-synthetic',29);
'''


def model_expression(protocol, path="virt-synthetic"):
    if protocol == "I2C":
        return "__BOT4CJ_VIRTBUS.devs[49].model"
    return f'__BOT4CJ_VIRTBUS.{protocol.lower()}_devs["{path}"].model'


@pytest.fixture(autouse=True)
def no_hardware(monkeypatch):
    original = HALManager.call

    def checked(hal, operation, *args, **kwargs):
        if operation in {"i2c_open", "spi_open", "uart_open"}:
            path = args[0] if args else None
            virtual = bool(args and args[-1] is True)
            virtual |= isinstance(path, str) and path.startswith("virt-") or path == "loop://"
            if not virtual:
                pytest.fail("Synthetic protocol tests must never reach physical HAL")
        return original(hal, operation, *args, **kwargs)

    monkeypatch.setattr(HALManager, "call", checked)


@pytest.fixture
def closed_states(monkeypatch):
    snapshots = []
    close = LuaState.close

    def observed_close(state):
        if not state._closed:
            vbus = state.globals["__BOT4CJ_VIRTBUS"]
            if vbus is not None:
                snapshots.append((vbus.fd_count(), bool(vbus._injected)))
        close(state)
        assert state._closed and state.lua is None

    monkeypatch.setattr(LuaState, "close", observed_close)
    return snapshots


@pytest.mark.parametrize("protocol", PROTOCOLS)
def test_synthetic_direct_actions_and_instance_isolation(protocol, synthetic_modules, closed_states):
    with Robot(direct_sql(protocol), module_paths=synthetic_modules) as robot:
        bus_runtime = robot.registry["bus"].runtime
        assert isinstance(bus_runtime, PythonState) and bus_runtime._virtual is None
        bus_fd = robot.registry["bus"].read()["fd"]
        assert robot.hal._handles[bus_fd].backend == "virtual"
        outputs = robot.run("@Action\na.read b.read;\n1 1;\n@")
        assert outputs == [dict(result="OK", COUNT=40961, VALUE=10240.25, TAG=tag,
                                WORD="synthetic", CRC_OK=1) for tag in (11, 29)]
        a, b = (robot.registry[name].runtime for name in ("a", "b"))
        model = model_expression(protocol)
        a.lua.execute(f"local model = {model}; model:virt_tick(8)")
        assert robot.registry["a"].read()["COUNT"] == 40969
        assert robot.registry["b"].read()["COUNT"] == 40961
        for state in (a, b):
            assert state.lua.eval("__BOT4CJ_VIRTBUS.fd_count()") == 1
            assert state.globals.build("invalid")["result"] == "ERR"
            assert state.globals.call(state.lua.table())["result"] == "ERR"
    assert robot.state == "Inactive"
    assert all(variable.runtime is None for variable in robot.registry.values())
    assert len(closed_states) == 2 and all(count == 0 for count, _ in closed_states)
    assert not robot.hal._handles and not robot.hal._buses


@pytest.mark.parametrize("protocol,path", [
    ("I2C", "/dev/i2c-1"),
    ("SPI", "/dev/spidev0.0"),
    ("UART", "/dev/ttyUSB0"),
])
def test_virtual_bus_proto_uses_virtual_backend_for_legacy_path(protocol, path, synthetic_modules):
    sql = direct_sql(protocol).replace("'virt-synthetic'", f"'{path}'", 1)
    with Robot(sql, module_paths=synthetic_modules, allow_hardware=True) as robot:
        fd = robot.registry["bus"].read()["fd"]
        assert robot.hal._handles[fd].backend == "virtual"


@pytest.mark.parametrize("protocol,fault,message", [
    ("I2C", "nack", "synthetic I2C read NACK"),
    ("I2C", "read_nack", "synthetic I2C read NACK"),
    ("SPI", "fail", "synthetic SPI transfer failed"),
    ("UART", "fail", "synthetic UART write failed"),
    ("UART", "silent", "synthetic UART timeout"),
    ("UART", "link", "synthetic UART read failed"),
])
def test_synthetic_direct_errors_recover_and_remain_isolated(protocol, fault, message,
                                                            synthetic_modules, closed_states):
    with Robot(direct_sql(protocol), module_paths=synthetic_modules) as robot:
        state = robot.registry["a"].runtime
        target = ("__BOT4CJ_VIRTBUS.uart_fail_read" if fault == "link"
                  else f"{model_expression(protocol)}.{fault}")
        state.lua.execute(f"{target} = true")
        with pytest.raises(ControllerError, match=message):
            robot.run("@Action\na.read;\n1;\n@")
        assert robot.registry["b"].read()["TAG"] == 29
        state.lua.execute(f"{target} = false")
        if protocol == "UART":
            fd = robot.registry["bus"].read()["fd"]
            state.lua.execute(f"assert(uart_flush({fd}) == 0)")
        assert robot.run("@Action\na.read;\n1;\n@")[0]["TAG"] == 11
    assert len(closed_states) == 2 and all(count == 0 for count, _ in closed_states)


@pytest.mark.parametrize("reply,message", [
    ("scalar", "must return a table"),
    ("empty", "expected a non-empty result table"),
    ("status", "unknown result status"),
])
def test_synthetic_direct_result_validation(reply, message, synthetic_modules, closed_states):
    with Robot(direct_sql("I2C"), module_paths=synthetic_modules) as robot:
        with pytest.raises(ControllerError, match=message):
            robot.run("@Action\na.reply;\n$(requested);\n@", vars={"requested": reply})
        assert robot.registry["a"].read()["COUNT"] == 40961
    assert all(count == 0 for count, _ in closed_states)


@pytest.mark.parametrize("protocol", PROTOCOLS)
def test_synthetic_daemon_samples_and_cleanup(protocol, synthetic_modules, closed_states):
    sql = f'''
CREATE TABLE Daemon(name String,chunk String,proto String,driver String,addr Number,fields String,tag Number);
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields,tag) VALUES('a','lib/sensor_daemon.lua','virt','Synthetic{protocol}',49,'COUNT:f|VALUE:f|TAG:f',11);
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields,tag) VALUES('b','lib/sensor_daemon.lua','virt','Synthetic{protocol}',49,'COUNT:f|VALUE:f|TAG:f',29);
'''
    assert all(not (root / f"lib/virtbus/synthetic{protocol.lower()}.lua").exists()
               for root in synthetic_modules)
    with Robot(sql, module_paths=synthetic_modules) as robot:
        daemons = list(robot.registry.values())
        for daemon, tag in zip(daemons, (11, 29)):
            previous = 0
            for _ in range(3):
                sample = daemon.wait_for_sample(after=previous, timeout=3)
                assert sample["result"] == sample["status"] == "OK"
                assert sample["count"] > previous and sample["nvals"] == 3
                count = 40960 + sample["count"]
                assert sample["values"] == [count, count / 4, tag]
                assert sample["values"] == [sample[f"v{i}"] for i in range(3)]
                previous = sample["count"]
    assert all(daemon._done.is_set() and not daemon._thread.is_alive() for daemon in daemons)
    assert closed_states == [(0, False), (0, False)]
    assert not robot.hal._handles and not robot.hal._buses


@pytest.fixture
def daemon_runtime(synthetic_modules):
    hal, stop = HALManager(), threading.Event()
    states = []

    def make(protocol, **extra):
        config = {"chunk": "lib/sensor_daemon.lua", "proto": "virt", "driver": f"Synthetic{protocol}",
                  "addr": "49", "fields": "COUNT:f|VALUE:f", "path": "virt-synthetic", **extra}
        daemon = DaemonVariable("manual", config, Registry(), None, stop)
        state = LuaState(synthetic_modules, hal, stop, daemon=daemon)
        states.append(state)
        state.load(synthetic_modules[1] / config["chunk"])
        return daemon, state

    yield make
    try:
        for state in states:
            try:
                if state.has_function("daemon_cleanup"):
                    state.call("daemon_cleanup")
                assert state.lua.eval("__BOT4CJ_VIRTBUS.fd_count()") == 0
            finally:
                state.close()
    finally:
        hal.close()


@pytest.mark.parametrize("protocol", PROTOCOLS)
def test_synthetic_daemon_transfer_failure_does_not_publish(protocol, daemon_runtime, capsys):
    daemon, state = daemon_runtime(protocol)
    state.call("daemon_tick")
    assert daemon.slot.snapshot()["values"] == [40961, 10240.25]
    target = f"{model_expression(protocol)}." + ("nack" if protocol == "I2C" else "fail")
    state.lua.execute(f"{target} = true")
    state.call("daemon_tick")
    snapshot = daemon.slot.snapshot()
    assert snapshot["count"] == 1 and snapshot["values"] == [40961, 10240.25]
    assert "tick error #1" in capsys.readouterr().err
    state.lua.execute(f"{target} = false")
    state.call("daemon_tick")
    snapshot = daemon.slot.snapshot()
    assert snapshot["count"] == 2 and snapshot["values"] == [40963, 10240.75]


@pytest.mark.parametrize("protocol", PROTOCOLS)
@pytest.mark.parametrize("extra,message", [
    ({"fields": "ABSENT:f"}, "absent or non-numeric"),
    ({"fields": "WORD:f"}, "absent or non-numeric"),
    ({"fields": "VALUE:s16"}, "would be truncated"),
    ({"reply": "crc"}, "CRC check failed"),
    ({"fail_call": "yes"}, "synthetic sample failure"),
])
def test_synthetic_daemon_rejects_bad_samples(protocol, extra, message, daemon_runtime, capsys):
    daemon, state = daemon_runtime(protocol, **extra)
    state.call("daemon_tick")
    snapshot = daemon.slot.snapshot()
    assert snapshot["count"] == 0 and snapshot["nvals"] == 0 and snapshot["status"] == 0
    assert message in capsys.readouterr().err


@pytest.mark.parametrize("protocol", PROTOCOLS)
def test_synthetic_daemon_build_failure_closes_bus(protocol, daemon_runtime, capsys):
    daemon, state = daemon_runtime(protocol, fail_build="yes")
    snapshot = daemon.slot.snapshot()
    assert snapshot["status"] == -2 and snapshot["nvals"] == 0
    assert state.lua.eval("__BOT4CJ_VIRTBUS.fd_count()") == 0
    assert "synthetic build failure" in capsys.readouterr().err


@pytest.mark.parametrize("protocol", PROTOCOLS)
def test_synthetic_daemon_destroy_failure_still_closes_bus(protocol, daemon_runtime, capsys):
    daemon, state = daemon_runtime(protocol, fail_destroy="yes")
    state.call("daemon_tick")
    assert daemon.slot.snapshot()["count"] == 1
    state.call("daemon_cleanup")
    assert state.lua.eval("__BOT4CJ_VIRTBUS.fd_count()") == 0
    assert not state.globals["__BOT4CJ_VIRTBUS"]._injected
    assert "synthetic destroy failure" in capsys.readouterr().err
