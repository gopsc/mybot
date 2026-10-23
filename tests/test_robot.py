from pathlib import Path
import time

import pytest

from pymybot.errors import ControllerError, DriverError, ScriptError
from pymybot.robot import Robot

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def modules(tmp_path):
    (tmp_path / "Probe.lua").write_text('''
local count = 0
function build(d)
    if d.fail == "yes" then return {result="ERR", message="requested build failure"} end
    return {result="OK"}
end
function call(d)
    count = count + 1
    return {result="OK", count=count, value=d.value or 0, word="hello"}
end
function read(d) return {result="OK", count=count} end
function destroy(d) return {result="OK"} end
''')
    return [tmp_path, ROOT / "modules"]


def probe_sql(extra=""):
    return "CREATE TABLE Probe(name String, fail String); INSERT INTO Probe(name,fail) VALUES('dev','no');" + extra


def test_relay_controller_chain():
    with Robot.from_file(ROOT / "robots" / "relay-test.sql") as robot:
        result = robot.run("@Action\nrelay0.test;\n1;\n@")
        assert result[-1]["result"] == "OK"
        assert result[-1]["slept"] == 1
    assert robot.state == "Inactive"
    robot.deactivate()


def test_variable_capture_conditional_loop_and_scope(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        result = robot.run("""@Vars
name value;
i 0;
@
@while(i<3)
@Action
dev.value dev.capture;
$(i+1) $i=count;
@
@
@if(i==3)
@Action
dev.value;
99;
@
@
""")
        assert result[-1]["value"] == 99
        assert robot.registry.get("i") is None
        assert robot.registry["dev"].read()["count"] == 4


def test_injected_alias_and_scope_on_failure(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        result = robot.run("@Action\ndev.value;\n$(arg);\n@", vars={"arg": "hello"})
        assert result[-1]["value"] == "hello"
        assert "arg" not in robot.registry
        with pytest.raises(ControllerError):
            robot.run("@Alias\nname alias;\nx dev;\n@\n@Action\nmissing.value;\n1;\n@")
        assert "x" not in robot.registry


def test_invalid_reference_rejected_before_activation(modules):
    robot = Robot("CREATE TABLE Probe(name String, src String); INSERT INTO Probe(name,src) VALUES('dev','$absent');", module_paths=modules)
    with pytest.raises(ScriptError, match="undefined"):
        robot.active()
    assert robot.state == "Loaded"
    assert len(robot.registry) == 0


def test_hot_insert_rollback_update_delete_and_query(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        robot.apply_sql("INSERT INTO Probe(name,fail) VALUES('second','no');")
        assert "second" in robot.registry
        assert "second" in robot.query_sql("SELECT * FROM Probe WHERE name='second';")
        with pytest.raises(ControllerError, match="build failure"):
            robot.apply_sql("INSERT INTO Probe(name,fail) VALUES('third','no'); INSERT INTO Probe(name,fail) VALUES('fourth','yes');")
        assert set(robot.registry) == {"dev", "second"}
        assert len(robot.tables["Probe"].data) == 2
        robot.apply_sql("UPDATE Probe SET name='renamed' WHERE name='second';")
        assert set(robot.registry) == {"dev", "renamed"}
        robot.apply_sql("DELETE FROM Probe WHERE name='renamed';")
        assert set(robot.registry) == {"dev"}
        assert "Probe" in robot.query_sql("SHOW TABLES;")
        robot.apply_sql("DROP TABLE Probe;")
        assert not robot.tables


def test_hot_sql_transient_action_executes_and_clears():
    with Robot("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');") as robot:
        result = robot.apply_sql("CREATE TABLE Action(t0.delay Number); INSERT INTO Action(t0.delay) VALUES(1);")
        assert "已生效" in result
        assert robot.tables["Action"].data == []
        assert list(robot.registry) == ["t0"]


def test_update_failure_does_not_restore_powered_down_variable(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        with pytest.raises(ControllerError, match="remain deactivated"):
            robot.apply_sql("UPDATE Probe SET fail='yes' WHERE name='dev';")
        assert "dev" not in robot.registry
        assert not robot.tables["Probe"].data


def test_referenced_hardware_cannot_be_deleted(modules):
    sql = probe_sql("CREATE TABLE Relay(name String,controller String); INSERT INTO Relay(name,controller) VALUES('relay','dev');")
    with Robot(sql, module_paths=modules) as robot:
        with pytest.raises(ScriptError, match="referenced|defined before"):
            robot.apply_sql("DELETE FROM Probe;")
        assert set(robot.registry) == {"dev", "relay"}


def test_repeated_lifecycle_starts_fresh_state(modules):
    robot = Robot(probe_sql(), module_paths=modules)
    for _ in range(2):
        with robot:
            assert robot.run("@Action\ndev.value;\n1;\n@")[0]["count"] == 1


def test_repeated_lifecycle_reopens_hal():
    robot = Robot("CREATE TABLE Camera(name String); INSERT INTO Camera(name) VALUES('cam');")
    previous = None
    for _ in range(2):
        with robot:
            assert robot.hal is not previous
            assert robot.registry["cam"].runtime is not None
            previous = robot.hal


def test_real_bus_refused_without_importing_backend(monkeypatch):
    import pymybot.hal as hal

    monkeypatch.setattr(hal.importlib, "import_module", lambda *a: pytest.fail("Physical backend imported"))
    sql = "CREATE TABLE UART(name String,path String,baud Number); INSERT INTO UART(name,path,baud) VALUES('uart','COM3',115200);"
    robot = Robot(sql)
    with pytest.raises(ControllerError, match="allow-hardware"):
        robot.active()
    assert robot.state == "Inactive"


@pytest.mark.parametrize("separator", [",", "|"])
def test_virtual_daemon_sources_and_dependency_deletion(separator, synthetic_modules):
    sql = f'''CREATE TABLE Daemon(name String,chunk String,proto String,driver String,addr Number,fields String,sources String);
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields,sources) VALUES('a','lib/sensor_daemon.lua','virt','SyntheticI2C',49,'TAG:f','-');
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields,sources) VALUES('b','lib/sensor_daemon.lua','virt','SyntheticI2C',49,'TAG:f','-');
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields,sources) VALUES('combined','lib/sensor_aggregate.lua','virt','SyntheticI2C',49,'TAG:f','a{separator}b');'''
    with Robot(sql, module_paths=synthetic_modules) as robot:
        assert robot.registry["a"].wait_for_sample(timeout=3)["values"] == [7]
        assert robot.registry["b"].wait_for_sample(timeout=3)["values"] == [7]
        combined = robot.registry["combined"]
        deadline = time.monotonic() + 3
        sample = combined.wait_for_sample(timeout=3)
        while sample["nvals"] < 2:
            sample = combined.wait_for_sample(after=sample["count"], timeout=max(0, deadline - time.monotonic()))
        assert sample["values"] == [7, 7]
        with pytest.raises(ScriptError):
            robot.apply_sql("DELETE FROM Daemon WHERE name='a';")


@pytest.mark.parametrize("literal,expected", [("0x10", 16), ("0x1.8p+2", 6), ("1e2", 100)])
def test_numeric_variables_accept_source_numeric_literals(literal, expected):
    sql = f"CREATE TABLE Vars(name String,value Number); INSERT INTO Vars(name,value) VALUES('x','{literal}');"
    with Robot(sql) as robot:
        assert robot.registry.resolve_number("x") == expected


def test_library_probes_survive_drive_letters_and_colons(tmp_path, monkeypatch):
    # Shared Lua libraries used to split BOT4CJ_MODULE_PATH on ':', so a Windows drive
    # letter (or a POSIX directory containing ':') produced bogus probe paths and every
    # activation raised and swallowed Lua errors. Every probe must now hit a real file.
    import sys
    from conftest import I2C_DRIVER, PRELUDE
    from pymybot.runtime import LuaState

    root = tmp_path / ("drivers" if sys.platform == "win32" else "drivers:extra")
    root.mkdir()
    (root / "SyntheticI2C.lua").write_text(PRELUDE + I2C_DRIVER, encoding="utf-8")
    failures = []
    original = LuaState._loader
    def recording_loader(self, path):
        loaded = original(self, path)
        if isinstance(loaded, tuple):
            failures.append(str(path))
        return loaded
    monkeypatch.setattr(LuaState, "_loader", recording_loader)
    sql = '''CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('timer-0');
CREATE TABLE Relay(name String, controller String); INSERT INTO Relay(name,controller) VALUES('relay0','timer-0');
CREATE TABLE UART(name String,path String,baud Number); INSERT INTO UART(name,path,baud) VALUES('uart','loop://',115200);
CREATE TABLE I2C(name String,path String,proto String); INSERT INTO I2C(name,path,proto) VALUES('bus','virt-i2c-0','virt');
CREATE TABLE SyntheticI2C(name String,I2C String,address Number,proto String); INSERT INTO SyntheticI2C(name,I2C,address,proto) VALUES('dev','$bus',49,'virt');
CREATE TABLE Daemon(name String,chunk String,proto String,driver String,addr Number,fields String);
INSERT INTO Daemon(name,chunk,proto,driver,addr,fields) VALUES('d','lib/sensor_daemon.lua','virt','SyntheticI2C',49,'TAG:f');'''
    with Robot(sql, module_paths=[root, ROOT / "modules"]) as robot:
        assert robot.run("@Action\nrelay0.test;\n1;\n@")[-1]["result"] == "OK"
        assert robot.registry["d"].wait_for_sample(timeout=3)["values"] == [7]
    # The only expected miss: sensor_daemon prefers a standalone lib/virtbus/<driver>.lua
    # model and falls back to the driver's embedded *_VIRT factory by design.
    unexpected = [p for p in failures if not p.replace("\\", "/").endswith("lib/virtbus/synthetici2c.lua")]
    assert unexpected == []


def test_empty_module_path_segments_use_default(monkeypatch):
    import os
    from pymybot.robot import module_roots

    monkeypatch.setenv("BOT4CJ_MODULE_PATH", os.pathsep * 2)
    assert module_roots() == [ROOT / "modules"]
    monkeypatch.setenv("BOT4CJ_MODULE_PATH", os.pathsep.join(["", str(ROOT / "modules"), str(ROOT / "modules"), ""]))
    assert module_roots() == [ROOT / "modules"]


@pytest.mark.parametrize("chunk, columns, values, consumer", [
    ("sensor_daemon.lua", "driver String,addr Number,fields String",
     "'SyntheticI2C',49,'COUNT:f'", "sample-d0"),
    ("sensor_daemon_multi.lua", "devices String",
     "'SyntheticI2C@0x31@COUNT:f'", r"sample-d0\[0\]"),
])
def test_single_consumer_rejected_before_device_open(single_consumer_modules, monkeypatch,
                                                    chunk, columns, values, consumer):
    from pymybot.hal import HALManager
    from pymybot.runtime import LuaState

    def forbidden(*args, **kwargs):
        pytest.fail("Single-consumer validation must precede Lua and hardware access")

    monkeypatch.setattr(HALManager, "call", forbidden)
    monkeypatch.setattr(LuaState, "__init__", forbidden)
    names = ",".join(column.split()[0] for column in columns.split(","))
    sql = f'''
CREATE TABLE I2C(name String,path String);
INSERT INTO I2C(name,path) VALUES('bus','/dev/i2c-99');
CREATE TABLE SyntheticI2C(name String,I2C String,address String);
INSERT INTO SyntheticI2C(name,I2C,address) VALUES('sample0','$bus','0x31');
CREATE TABLE Daemon(name String,chunk String,proto String,path String,{columns});
INSERT INTO Daemon(name,chunk,proto,path,{names}) VALUES('sample-d0','lib/{chunk}','i2c','/dev/i2c-99',{values});
'''
    robot = Robot(sql, module_paths=single_consumer_modules, allow_hardware=True)
    with pytest.raises(ScriptError, match=f"Single-consumer.*{consumer}.*sample0"):
        robot.active()
    assert robot.state == "Loaded"
    assert not robot.registry and not robot.hal._handles


def test_hot_delete_failure_removes_dead_variable_and_rolls_back_additions(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        variable = robot.registry["dev"]
        destroy = variable.destroy

        def failing_destroy():
            destroy()
            raise RuntimeError("device cleanup failed")

        variable.destroy = failing_destroy
        with pytest.raises(ControllerError, match="cleanup failed"):
            robot.apply_sql("INSERT INTO Probe(name,fail) VALUES('new','no'); DELETE FROM Probe WHERE name='dev';")
        assert not robot.tables["Probe"].data
        assert set(robot.registry) == set()


def test_shell_driver_end_to_end_with_allow_hardware():
    sql = ("CREATE TABLE Shell(name String, timeout Number); "
           "INSERT INTO Shell(name,timeout) VALUES('sh',10000);")
    with Robot(sql, module_paths=[ROOT / "modules"], allow_hardware=True) as robot:
        result = robot.run('@Action\nsh.cmd;\n$("echo\\te2e-shell-ok");\n$("exit\\t7");\n@')
        assert result[0]["result"] == "OK" and result[0]["code"] == 0
        assert "e2e-shell-ok" in result[0]["out"] and result[0]["err"] == ""
        # a non-zero exit code is a normal completion, not an ERR
        assert result[1]["result"] == "OK" and result[1]["code"] == 7


def test_shell_driver_refused_without_allow_hardware():
    sql = ("CREATE TABLE Shell(name String, timeout Number); "
           "INSERT INTO Shell(name,timeout) VALUES('sh',10000);")
    robot = Robot(sql, module_paths=[ROOT / "modules"])
    try:
        # activation fails at build: the session gate refuses shell_open
        with pytest.raises(DriverError, match="allow-hardware"):
            robot.active()
    finally:
        robot.deactivate()


def test_struct_loop_capture_and_per_run_scope(modules):
    script = '''@Struct(state)
{"count":0,"points":[{"x":10}],"enabled":true}
@
@while(state.enabled&&state.count<3)
@Action
dev.value dev.capture;
$(state.count+1) $state.count=value;
@
@
@Action
dev.value dev.capture;
$(state.points[0].x) $state.points[0].x=count;
$(state.points[0].x) -;
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        outputs = robot.run(script)
        assert [v["value"] for v in outputs] == [1, 2, 3, 10, 4]
        assert robot.registry.get("state") is None
        assert robot.run(script)[0]["value"] == 1
        assert robot.registry["dev"].read()["count"] == 10


def test_struct_capture_indices_and_values_are_frozen_before_row_dispatch(modules):
    script = '''@Struct(state)
{"values":[0,0]}
@
@Vars
name value;
i 0;
@
@Action
dev.value dev.i dev.slot;
$(state.values[i]) $i=count $state.values[i]=count;
- - -;
@
@Action
dev.value;
$(state.values[0]*10+state.values[1]);
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        outputs = robot.run(script)
        assert [v["value"] for v in outputs] == [0, 0, 12]


def test_struct_hoisting_and_vars_can_read_numeric_members(modules):
    script = '''@Vars
name value;
scaled $(state.value*2);
@
@Action
dev.value dev.capture;
$(scaled) $state.value=count;
- -;
@
@Struct(state)
{"value":3}
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        assert [v["value"] for v in robot.run(script)] == [6, 2]


def test_struct_whole_assignment_and_nested_capture_preserve_receipts(modules):
    (modules[0] / "JsonProbe.lua").write_text('''
function build(d) return {result="OK"} end
function call(d)
    return {result="OK", payload={points={{x=1},{x=2}},flag=true}, number=7, flag=false, value=d.value}
end
function destroy(d) return {result="OK"} end
''', encoding="utf-8")
    sql = "CREATE TABLE JsonProbe(name String); INSERT INTO JsonProbe(name) VALUES('dev');"
    script = '''@Struct(state)
{}
@
@Action
dev.capture;
$state=payload;
$state.points[0].x=number;
$state.points[1]=payload;
$state.flag=flag;
@
@if(!state.flag)
@Action
dev.value;
$(state.points[0].x+state.points[1].points[1].x);
@
@
@Action
dev.capture;
$state=number;
@
@Action
dev.value;
$(state);
@
'''
    with Robot(sql, module_paths=modules) as robot:
        outputs = robot.run(script)
        assert outputs[0]["payload"]["points"][0]["x"] == 1
        assert outputs[4]["value"] == 9
        assert outputs[-1]["value"] == 7
        assert robot.registry.get("state") is None


@pytest.mark.parametrize("target", ["state.missing", "state.points[1]", "state.points[-1]",
                                       "state.points[0].x", "absent.x", "state.points[0.5]"])
def test_struct_invalid_capture_targets_restore_scope(modules, target):
    script = '@Struct(state)\n{"points":[1]}\n@\n@Action\ndev.value;\n$' + target + '=count;\n@\n'
    with Robot(probe_sql(), module_paths=modules) as robot:
        with pytest.raises(ScriptError):
            robot.run(script)
        assert robot.registry.get("state") is None


def test_struct_assignment_failure_restores_previous_struct_without_undoing_driver(modules):
    from pymybot.hardware import Struct

    with Robot(probe_sql(), module_paths=modules) as robot:
        state = Struct("state", {"count": 0})
        robot.registry.add(state)
        with pytest.raises(ScriptError):
            robot.run('@Action\ndev.value;\n$state.count=count;\n$state.missing=count;\n@\n')
        assert robot.registry.get("state") is state and state.read() == {"count": 0}
        assert robot.registry["dev"].read()["count"] == 2


@pytest.mark.parametrize("before,after", [
    ('@Struct(state)\n{}\n@\n', '@Struct(state)\n[]\n@\n'),
    ('@Struct(state)\n{}\n@\n', '@Alias\nname alias;\nstate dev;\n@\n'),
    ('@Alias\nname alias;\nstate dev;\n@\n', '@Struct(state)\n{}\n@\n'),
    ('@Vars\nname value;\nstate 1;\n@\n', '@Struct(state)\n{}\n@\n'),
    ('@Struct(dev)\n{}\n@\n', ''),
])
def test_struct_rejects_duplicate_or_shadowed_declarations_before_play(modules, before, after):
    with Robot(probe_sql(), module_paths=modules) as robot:
        with pytest.raises(ScriptError, match="Duplicate"):
            robot.run(before + after + '@Action\ndev.value;\n1;\n@\n')
        assert robot.registry["dev"].read()["count"] == 0
        assert robot.registry.get("state") is None


def test_struct_rejects_cli_binding_override(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        with pytest.raises(ScriptError, match="Struct"):
            robot.run('@Struct(state)\n{}\n@\n@Action\ndev.value;\n1;\n@\n', vars={"state": "text"})
        assert robot.registry["dev"].read()["count"] == 0


def test_struct_reflex_captures_survive_between_calls_only(modules):
    script = '''@Struct(state)
{"count":0}
@
@Reflex
name dev.value;
read $state.count=count;
use $(state.count);
@
@Trigger
trigger;
read;
use;
read;
use;
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        assert [v["value"] for v in robot.run(script)] == [0, 1, 0, 3]
        assert robot.registry.get("state") is None


@pytest.mark.parametrize("directive", ["Include", "Merge"])
def test_struct_composed_scripts_run_without_payload_loss(modules, tmp_path, directive):
    (tmp_path / "part.mt").write_text('''@Struct(cfg)
{"word":"text # ; @ with spaces", "value":7}
@
@Action
dev.value;
$(cfg.word);
$(cfg.value);
@
''', encoding="utf-8")
    with Robot(probe_sql(), module_paths=modules) as robot:
        outputs = robot.run(f'@{directive}\npath;\npart.mt;\n@\n', base_dir=tmp_path)
        assert [v["value"] for v in outputs] == ["text # ; @ with spaces", 7]
        assert robot.registry.get("cfg") is None
