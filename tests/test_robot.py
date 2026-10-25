import copy
from pathlib import Path
import threading
import time

import pytest

from pymybot.errors import BudgetExceeded, ControllerError, DriverError, ScriptError
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


@pytest.mark.parametrize("same_table", [False, True])
def test_hot_temporary_duplicate_does_not_rebuild_original(same_table):
    sql = ("CREATE TABLE Vars(name String,value Number); INSERT INTO Vars(name,value) VALUES('n',1);"
           "CREATE TABLE Alias(name String,alias String);")
    mutation = ("INSERT INTO Vars(name,value) VALUES('n',2); DELETE FROM Vars WHERE value=2;"
                if same_table else "INSERT INTO Alias(name,alias) VALUES('n','temporary'); DELETE FROM Alias;")
    with Robot(sql) as robot:
        previous = robot.registry["n"]
        tables = copy.deepcopy(robot.tables)
        robot.apply_sql(mutation)
        assert robot.registry["n"] is previous
        assert robot.tables == tables


@pytest.mark.parametrize("cancel_after", ["a", "b"])
def test_hot_cancelled_deletion_preserves_dependency_validity(cancel_after):
    sql = ("CREATE TABLE Vars(name String,value Number);"
           "INSERT INTO Vars(name,value) VALUES('a','$(b+1)');"
           "INSERT INTO Vars(name,value) VALUES('b',1);")
    with Robot(sql) as robot:
        assert robot.registry.resolve_number("a") == 2
        cancel = threading.Event()
        robot.registry[cancel_after].destroy = cancel.set
        with pytest.raises(BudgetExceeded):
            robot.apply_sql("DELETE FROM Vars;", cancel=cancel)
        if cancel_after == "a":
            assert list(robot.registry) == ["b"]
            assert robot.registry.resolve_number("b") == 1
        else:
            assert not robot.registry
        assert set(robot._rows(robot.tables)) == set(robot.registry)


def test_hot_cancelled_cyclic_deletion_finishes_cleanup_group():
    sql = ("CREATE TABLE Vars(name String,value Number);"
           "INSERT INTO Vars(name,value) VALUES('a','$(b+1)');"
           "INSERT INTO Vars(name,value) VALUES('b','$(a+1)');")
    with Robot(sql) as robot:
        cancel = threading.Event()
        robot.registry["b"].destroy = cancel.set
        with pytest.raises(BudgetExceeded):
            robot.apply_sql("DELETE FROM Vars;", cancel=cancel)
        assert not robot.registry and not robot.tables["Vars"].data


@pytest.mark.parametrize("kind", ["UPDATE Probe SET fail='no'", "DELETE FROM Probe"])
def test_hot_sql_rejects_invalid_where_before_changing_devices(modules, kind):
    with Robot(probe_sql(), module_paths=modules) as robot:
        previous = robot.registry["dev"]
        with pytest.raises(ScriptError, match="no such column"):
            robot.apply_sql(f"{kind} WHERE missing='value';")
        assert robot.registry["dev"] is previous and previous.runtime is not None


@pytest.mark.parametrize("module,parameter", [("Ema", "in"), ("Kalman", "in"), ("Monitor", "v0")])
def test_snapshot_chain_can_build_without_samples_but_cannot_execute(module, parameter):
    sql = ("CREATE TABLE Monitor(name String,src String);"
           "INSERT INTO Monitor(name,src) VALUES('filter','-');" if module == "Monitor" else
           f"CREATE TABLE {module}(name String); INSERT INTO {module}(name) VALUES('filter');"
           "CREATE TABLE Monitor(name String,src String);")
    sql += ("INSERT INTO Monitor(name,src) VALUES('consumer','$filter');"
            "INSERT INTO Monitor(name,src) VALUES('downstream','$consumer');")
    with Robot(sql) as robot:
        with pytest.raises(DriverError, match="no sample yet"):
            robot.run("@Action\ndownstream.tick;\n1;\n@")
        outputs = robot.run(f"@Action\nfilter.{parameter};\n5;\n@\n"
                            "@Action\nconsumer.tick;\n1;\n@\n@Action\ndownstream.tick;\n1;\n@")
        assert outputs[-1]["out"] == outputs[0]["v0"]
        assert outputs[-1]["result"] == "OK"


def test_hot_sql_transient_action_executes_and_clears():
    with Robot("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('t0');") as robot:
        result = robot.apply_sql("CREATE TABLE Action(t0.delay Number); INSERT INTO Action(t0.delay) VALUES(1);")
        assert "已生效" in result
        assert robot.tables["Action"].data == []
        assert list(robot.registry) == ["t0"]


@pytest.mark.parametrize("value", ["1", "2"])
def test_hot_same_name_scalar_replacement_rebuilds(value):
    sql = "CREATE TABLE Vars(name String,value Number); INSERT INTO Vars(name,value) VALUES('n',1);"
    with Robot(sql) as robot:
        previous = robot.registry["n"]
        receipt = robot.apply_sql(f"DELETE FROM Vars; INSERT INTO Vars(name,value) VALUES('n',{value});")
        assert robot.registry["n"] is not previous
        assert robot.registry.resolve_number("n") == float(value)
        assert robot.query_sql("SELECT * FROM Vars;").splitlines()[-1] == f"n\t{value}"
        assert "热更新 1 行" in receipt


def test_hot_same_name_driver_replacement_preserves_inherited_survivor(modules):
    sql = ("CREATE TABLE Probe(name String,value String);"
           "INSERT INTO Probe(name,value) VALUES('first',10);"
           "INSERT INTO Probe(name,value) VALUES('second','-');")
    with Robot(sql, module_paths=modules) as robot:
        first, second = robot.registry["first"], robot.registry["second"]
        robot.run("@Action\nfirst.tick second.tick;\n1 1;\n@")
        robot.apply_sql("DELETE FROM Probe WHERE name='first';"
                        "INSERT INTO Probe(name,value) VALUES('first',20);")
        assert first.runtime is None
        assert robot.registry["first"] is not first
        assert robot.registry["second"] is second
        output = robot.run("@Action\nfirst.tick second.tick;\n1 1;\n@")
        assert [(item["value"], item["count"]) for item in output] == [("20", 1), ("10", 2)]


def test_hot_same_name_replacement_can_change_driver_type(modules):
    sql = probe_sql("CREATE TABLE dummy(name String);")
    with Robot(sql, module_paths=modules) as robot:
        previous = robot.registry["dev"]
        robot.apply_sql("DELETE FROM Probe; INSERT INTO dummy(name) VALUES('dev');")
        assert previous.runtime is None
        assert robot.registry["dev"].path.name == "dummy.lua"
        assert robot.run("@Action\ndev.echo;\n7;\n@")[0]["echo"] == 7


def test_hot_same_name_failed_replacement_does_not_restore_old_device(modules):
    with Robot(probe_sql(), module_paths=modules) as robot:
        previous = robot.registry["dev"]
        with pytest.raises(DriverError, match="remain deactivated"):
            robot.apply_sql("DELETE FROM Probe; INSERT INTO Probe(name,fail) VALUES('dev','yes');")
        assert previous.runtime is None
        assert "dev" not in robot.registry
        assert not robot.tables["Probe"].data


def test_hot_same_name_replacement_rejects_surviving_references(modules):
    sql = probe_sql("CREATE TABLE Relay(name String,controller String);"
                    "INSERT INTO Relay(name,controller) VALUES('relay','dev');")
    with Robot(sql, module_paths=modules) as robot:
        previous = robot.registry["dev"]
        with pytest.raises(ScriptError, match="still referenced"):
            robot.apply_sql("DELETE FROM Probe; INSERT INTO Probe(name,fail) VALUES('dev','no');")
        assert robot.registry["dev"] is previous and previous.runtime is not None


@pytest.mark.parametrize("mutation", [
    "DELETE FROM Probe;",
    "DROP TABLE Probe;",
    "UPDATE Probe SET fail='no' WHERE name='dev';",
    "DELETE FROM Probe; INSERT INTO Probe(name,fail) VALUES('dev','no');",
    "INSERT INTO Probe(name,fail) VALUES('second','no');",
])
@pytest.mark.parametrize("robot_stop", [False, True])
def test_hot_sql_precancelled_has_no_side_effects(modules, monkeypatch, mutation, robot_stop):
    with Robot(probe_sql(), module_paths=modules) as robot:
        previous = robot.registry["dev"]
        tables = copy.deepcopy(robot.tables)
        cancel = robot.stop_event if robot_stop else threading.Event()
        cancel.set()
        with monkeypatch.context() as patch:
            patch.setattr(previous, "destroy", lambda: pytest.fail("Cancelled SQL destroyed a device"))
            patch.setattr(robot, "_assemble", lambda *args: pytest.fail("Cancelled SQL assembled variables"))
            with pytest.raises(BudgetExceeded):
                robot.apply_sql(mutation, cancel=None if robot_stop else cancel)
        assert robot.tables == tables
        assert list(robot.registry) == ["dev"] and robot.registry["dev"] is previous
        cancel.clear()


def test_hot_sql_cancelled_after_validation_has_no_side_effects(modules, monkeypatch):
    with Robot(probe_sql(), module_paths=modules) as robot:
        cancel = threading.Event()
        previous = robot.registry["dev"]
        validate = robot._validate
        def cancel_after_validation(tables):
            rows = validate(tables)
            cancel.set()
            return rows
        monkeypatch.setattr(robot, "_validate", cancel_after_validation)
        with pytest.raises(BudgetExceeded):
            robot.apply_sql("DELETE FROM Probe;", cancel=cancel)
        assert robot.registry["dev"] is previous and previous.runtime is not None
        assert robot.tables["Probe"].data == [["dev", "no"]]


def test_hot_sql_cancellation_stops_further_deletions(modules):
    sql = probe_sql("INSERT INTO Probe(name,fail) VALUES('second','no');")
    with Robot(sql, module_paths=modules) as robot:
        cancel = threading.Event()
        second = robot.registry["second"]
        destroy = second.destroy
        def cancel_after_destroy():
            destroy()
            cancel.set()
        second.destroy = cancel_after_destroy
        with pytest.raises(BudgetExceeded):
            robot.apply_sql("DELETE FROM Probe;", cancel=cancel)
        assert list(robot.registry) == ["dev"]
        assert robot.tables["Probe"].data == [["dev", "no"]]
        assert second.runtime is None


@pytest.mark.parametrize("result", [{"result": "ERR", "message": "source failed"}, {},
                                     {"result": "UNKNOWN"}, {"result": 1}])
def test_metadata_read_failure_blocks_downstream_and_allows_cleanup(modules, monkeypatch, result):
    sql = (probe_sql() + "CREATE TABLE Relay(name String,src String);"
           "INSERT INTO Relay(name,src) VALUES('relay','$dev');")
    with Robot(sql, module_paths=modules) as robot:
        source, downstream = robot.registry["dev"], robot.registry["relay"]
        monkeypatch.setattr(source, "read", lambda: result)
        def forbidden(*args, **kwargs):
            pytest.fail("Downstream driver executed after metadata read failure")
        with monkeypatch.context() as patch:
            patch.setattr(downstream.runtime, "call", forbidden)
            with pytest.raises(DriverError):
                downstream.play({"test": 7})
        assert downstream.metadata.collect(for_destroy=True) == downstream.metadata.static
        downstream.destroy()
        assert downstream.runtime is None


def test_metadata_read_failure_blocks_activation_before_downstream_build(monkeypatch):
    from pymybot.runtime import LuaState

    sql = ("CREATE TABLE Timer(name String); INSERT INTO Timer(name) VALUES('src');"
           "CREATE TABLE dummy(name String,src String); INSERT INTO dummy(name,src) VALUES('dev','$src');")
    calls = []
    original = LuaState.call
    def record(self, name, data=None, **kwargs):
        calls.append((name, dict(data or {})))
        return original(self, name, data, **kwargs)
    monkeypatch.setattr(LuaState, "call", record)
    robot = Robot(sql)
    with pytest.raises(DriverError, match="delay"):
        robot.active()
    assert len([name for name, _ in calls if name == "build"]) == 1
    assert robot.state == "Inactive"


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


def test_vars_precision_formats_rendered_parameters(modules):
    script = '''@Vars
name value precision;
ratio 2.3456 2;
whole 2.6 0;
@
@Action
dev.value;
$(ratio);
@
@Action
dev.value;
$(whole);
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        assert [result["value"] for result in robot.run(script)] == ["2.35", "3"]


def test_structure_vars_precision_formats_parameters(modules):
    sql = probe_sql() + (
        "CREATE TABLE Vars(name String,value Number,precision Number);"
        "INSERT INTO Vars(name,value,precision) VALUES('ratio','2.3456',2);"
    )
    with Robot(sql, module_paths=modules) as robot:
        output = robot.run("@Action\ndev.value;\n$(ratio);\n@")[0]
        assert output["value"] == "2.35"


def test_vars_precision_rejects_invalid_values(modules):
    script = '''@Vars
name value precision;
x 1 nope;
@
@Action
dev.value;
1;
@
'''
    with Robot(probe_sql(), module_paths=modules) as robot:
        with pytest.raises(ScriptError, match="precision"):
            robot.run(script)


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
