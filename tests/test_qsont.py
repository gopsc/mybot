"""End-to-end Qsont driver tests against an in-process fake qsont iot-server.

The fake serves the documented API subset on a loopback ephemeral port, so the
whole stack (HTTP.py bus → HAL → urllib → Qsont.lua) runs without hardware,
without --allow-hardware, and without any external network dependency.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from pymybot.errors import DriverError
from pymybot.robot import Robot

ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "modules"
USER, PASSWORD, DEVICE_ID = "iot_probe", "secret7", 7
FOREIGN_ID, FOREIGN_KEY = 8, "flower-key-1234"


class FakeIotApi:
    """In-memory qsont iot-server state: login, data, commands, device binding."""

    def __init__(self):
        self.lock = threading.Lock()
        self.token = "tok-1"
        # device_id -> {key, owner, name}; DEVICE_ID is ours, FOREIGN_ID belongs
        # to a mobile user and is reachable only after binding by device_key.
        self.devices = {DEVICE_ID: {"key": "own-key", "owner": "iot", "name": "probe"},
                        FOREIGN_ID: {"key": FOREIGN_KEY, "owner": "mobile", "name": "flower-pot"}}
        self.bound = set()         # device ids bound by the iot account
        self.points = []           # (device_id, data_key, data_value) in arrival order
        self.pending = [{"id": 11, "command_type": "set_threshold", "payload": {"value": 25}}]
        self.command_status = {}
        self.online = None
        self.requests = []         # (method, path, authorization)
        self.responder = None      # optional forced (status, payload) per request

    def _reachable(self, device_id):
        entry = self.devices.get(device_id)
        return entry is not None and (entry["owner"] == "iot" or device_id in self.bound)

    def handle(self, method, path, query, auth, body):
        with self.lock:
            self.requests.append((method, path, auth))
            if self.responder is not None:
                forced = self.responder(method, path, query, auth, body)
                if forced is not None:
                    return forced
            if path == "/api/v1/ping" and method == "GET":
                return 200, {"pong": True}
            if path == "/api/v1/users/login" and method == "POST":
                if json.loads(body) == {"username": USER, "password": PASSWORD}:
                    return 200, {"access_token": self.token, "token_type": "bearer"}
                return 401, {"detail": "bad credentials"}
            if auth != f"Bearer {self.token}":
                return 401, {"detail": "Invalid or expired token"}
            if path == "/api/v1/devices" and method == "POST":
                data = json.loads(body)
                did = max(self.devices) + 1
                self.devices[did] = {"key": f"key-{did}", "owner": "iot",
                                     "name": data["device_name"]}
                return 200, {"id": did, "user_id": 1,
                             "device_name": data["device_name"],
                             "device_key": f"key-{did}", "is_online": False}
            if path == "/api/v1/devices/bind" and method == "POST":
                entry = next((d for d in self.devices.values()
                              if d["key"] == json.loads(body).get("device_key")), None)
                if entry is None:
                    return 404, {"detail": "Device not found"}
                did = next(k for k, v in self.devices.items() if v is entry)
                if entry["owner"] == "iot":
                    return 400, {"detail": "Cannot bind your own device"}
                if did in self.bound:
                    return 400, {"detail": "Device already bound"}
                self.bound.add(did)
                return 200, {"message": "Device bound successfully",
                             "device_id": did, "device_name": entry["name"]}
            if method == "DELETE" and path.startswith("/api/v1/devices/") and path.endswith("/unbind"):
                did = int(path.split("/")[4])
                if did in self.bound:
                    self.bound.discard(did)
                    return 200, {"message": "Device unbound successfully"}
                if did in self.devices:
                    return 400, {"detail": "Device is not bound"}
                return 404, {"detail": "Device not found"}
            if path == "/api/v1/data" and method == "POST":
                data = json.loads(body)
                if not self._reachable(data["device_id"]):
                    return 404, {"detail": "Device not found"}
                self.points.append((data["device_id"], data["data_key"], data["data_value"]))
                return 200, {"id": len(self.points), "device_id": data["device_id"],
                             "data_key": data["data_key"], "data_value": data["data_value"],
                             "timestamp": "2026-10-22T00:00:00"}
            if path == "/api/v1/data/batch" and method == "POST":
                data = json.loads(body)
                for item in data["items"]:
                    if not self._reachable(item["device_id"]):
                        return 404, {"detail": "Device not found"}
                for item in data["items"]:
                    self.points.append((item["device_id"], item["data_key"], item["data_value"]))
                return 200, {"count": len(data["items"])}
            if path == "/api/v1/commands/pending" and method == "GET":
                return 200, self.pending
            if method == "PUT" and path.startswith("/api/v1/commands/") and path.endswith("/status"):
                cid = int(path.split("/")[4])
                self.command_status[cid] = json.loads(body)["status"]
                self.pending = [command for command in self.pending if command["id"] != cid]
                return 200, {"message": "Command status updated"}
            if method == "PUT" and path == f"/api/v1/devices/{DEVICE_ID}/status":
                self.online = json.loads(body)["is_online"]
                return 200, {"message": "Device status updated"}
            if path == "/api/v1/devices" and method == "GET":
                visible = [{"id": did, "device_name": entry["name"],
                            "is_online": entry["owner"] == "iot"}
                           for did, entry in sorted(self.devices.items()) if self._reachable(did)]
                return 200, visible
            if path.startswith("/api/v1/data/") and path.endswith("/latest") and method == "GET":
                did = int(path.split("/")[4])
                if not self._reachable(did):
                    return 404, {"detail": "Device not found"}
                key = (query.get("data_key") or [None])[0]
                for device_id, entry_key, entry_value in reversed(self.points):
                    if device_id == did and (key is None or entry_key == key):
                        return 200, {"id": 1, "device_id": did, "data_key": entry_key,
                                     "data_value": entry_value, "timestamp": "2026-10-22T00:00:01"}
                return 404, {"detail": "no data"}
            return 404, {"detail": "not found"}


@pytest.fixture
def iot_server():
    api = FakeIotApi()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _dispatch(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8") if length else ""
            parts = urlsplit(self.path)
            status, payload = api.handle(self.command.upper(), parts.path,
                                         parse_qs(parts.query),
                                         self.headers.get("Authorization"), body)
            raw = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        do_GET = do_POST = do_PUT = do_DELETE = lambda self: self._dispatch()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/api/v1", api
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def qsont_sql(base, user=USER, password=PASSWORD, device=DEVICE_ID):
    return f"""
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', '{base}', 3000);
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device) VALUES ('qs', '$cloud', '{user}', '{password}', {device});
"""


def qsont_bound_sql(base):
    """Credentials and device id come from Alias/Vars rows overridden at activation."""
    return f"""
CREATE TABLE Alias (name String, alias String);
INSERT INTO Alias (name, alias) VALUES ('user', 'COVER_ME');
INSERT INTO Alias (name, alias) VALUES ('pass', 'COVER_ME');
CREATE TABLE Vars (name String, value String);
INSERT INTO Vars (name, value) VALUES ('device', 0);
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', '{base}', 3000);
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device) VALUES ('qs', '$cloud', '$user', '$pass', '$(device)');
"""


def test_qsont_actions_over_loopback(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base), module_paths=[MODULES]) as robot:
        outputs = robot.run('@Action\nqs.op        qs.key           qs.value;\n'
                            '$("push")    $("temperature") 23.5;\n'
                            '$("online")  -                -;\n'
                            '$("pull")    -                -;\n@', timeout=30)
        assert [row["result"] for row in outputs] == ["OK"] * 3
        assert outputs[0]["id"] == 1 and api.points[-1:] == [(DEVICE_ID, "temperature", "23.5")]
        assert api.online is True
        assert outputs[2]["count"] == 1
        assert json.loads(outputs[2]["commands"])[0]["command_type"] == "set_threshold"
        # ack clears the pending queue; read() is the latest-data readback
        robot.run('@Action\nqs.op     qs.cmd;\n$("ack")  11;\n@', timeout=30)
        assert api.command_status == {11: "executed"} and api.pending == []
        outputs = robot.run('@Action\nqs.op       qs.key;\n$("latest")  $("temperature");\n@', timeout=30)
        assert outputs[0]["value"] == "23.5"
        assert robot.registry["qs"].read()["value"] == "23.5"
        # batch + devices listing
        robot.run('@Action\nqs.op      qs.items;\n$("batch")  $("humidity=60|co2=410");\n@', timeout=30)
        assert api.points[-2:] == [(DEVICE_ID, "humidity", "60"), (DEVICE_ID, "co2", "410")]
        outputs = robot.run('@Action\nqs.op;\n$("devices");\n@', timeout=30)
        assert outputs[0]["count"] == 1 and json.loads(outputs[0]["devices"])[0]["id"] == DEVICE_ID


def test_qsont_relogin_on_rotated_token(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base), module_paths=[MODULES]) as robot:
        api.token = "tok-2"  # server-side rotation invalidates tok-1
        outputs = robot.run('@Action\nqs.op      qs.key           qs.value;\n$("push")  $("temperature") 24;\n@', timeout=30)
        assert outputs[0]["result"] == "OK"
        logins = [r for r in api.requests if r[1] == "/api/v1/users/login"]
        assert len(logins) == 2  # build-time login + automatic re-login on 401
        assert (DEVICE_ID, "temperature", "24") in api.points


def test_qsont_bad_credentials_fail_activation(iot_server):
    base, _ = iot_server
    robot = Robot(qsont_sql(base, password="wrong"), module_paths=[MODULES])
    with pytest.raises(DriverError, match="login failed"):
        robot.active()
    robot.deactivate()


def test_qsont_offloop_base_requires_allow_hardware():
    robot = Robot(qsont_sql("https://qsont.me:8004/api/v1"), module_paths=[MODULES])
    with pytest.raises(DriverError, match="loopback"):
        robot.active()
    robot.deactivate()


def test_qsont_autopush_from_controller_chain(iot_server, tmp_path):
    base, api = iot_server
    (tmp_path / "Sensor.lua").write_text(
        'function build(d) return {result="OK"} end\n'
        'function call(d) return {result="OK", T=25.5, H=60, note="ok"} end\n'
        'function destroy(d) return {result="OK"} end\n')
    sql = qsont_sql(base) + """
CREATE TABLE Sensor (name String, controller String);
INSERT INTO Sensor (name, controller) VALUES ('s1', 'qs');
"""
    with Robot(sql, module_paths=[tmp_path, MODULES]) as robot:
        outputs = robot.run("@Action\ns1.go;\n1;\n@", timeout=30)
        assert outputs[0]["result"] == "OK" and outputs[0]["count"] == 3
        assert (DEVICE_ID, "T", "25.5") in api.points and (DEVICE_ID, "H", "60") in api.points
        assert (DEVICE_ID, "note", "ok") in api.points


def test_http_bus_standalone_requests(iot_server):
    base, _ = iot_server
    sql = f"""
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', '{base}', 3000);
"""
    with Robot(sql, module_paths=[MODULES]) as robot:
        outputs = robot.run('@Action\ncloud.method  cloud.path;\n$("GET")      $("ping");\n@', timeout=30)
        assert outputs[0]["result"] == "OK" and outputs[0]["status"] == 200
        assert json.loads(outputs[0]["body"]) == {"pong": True}
        # without request parameters the bus hands its handle to referencing rows
        session = robot.registry["cloud"].read()
        assert session["result"] == "OK" and session["base"] == base and session["fd"] >= 0


def test_qsont_bind_unbind_foreign_device(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base), module_paths=[MODULES]) as robot:
        # bind adopts the foreign device id for the rest of the session
        outputs = robot.run('@Action\nqs.op      qs.key;\n$("bind")  $("%s");\n@' % FOREIGN_KEY,
                            timeout=30)
        assert outputs[0] == {"result": "OK", "device": FOREIGN_ID, "name": "flower-pot"}
        assert api.bound == {FOREIGN_ID}
        # pushes now land on the bound device without touching the SQL
        outputs = robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("soil") 42;\n@',
                            timeout=30)
        assert outputs[0]["result"] == "OK" and api.points[-1] == (FOREIGN_ID, "soil", "42")
        # duplicate binding / post-unbind pushes raise: ERR rows abort the run
        with pytest.raises(DriverError, match="already bound"):
            robot.run('@Action\nqs.op      qs.key;\n$("bind")  $("%s");\n@' % FOREIGN_KEY,
                      timeout=30)
        outputs = robot.run('@Action\nqs.op;\n$("unbind");\n@', timeout=30)
        assert outputs[0] == {"result": "OK", "device": FOREIGN_ID}
        assert api.bound == set()
        with pytest.raises(DriverError, match="404"):
            robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("soil") 43;\n@',
                      timeout=30)


def test_qsont_create_device_then_push(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base, device=0), module_paths=[MODULES]) as robot:
        outputs = robot.run('@Action\nqs.op         qs.device_name;\n$("create")   $("new-pot");\n@',
                            timeout=30)
        created = outputs[0]
        assert created == {"result": "OK", "device": 9, "key": "key-9", "name": "new-pot"}
        assert api.devices[9]["owner"] == "iot"
        # 创建后同一会话直接推数据，无需重新 activate
        outputs = robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("soil") 42;\n@',
                            timeout=30)
        assert outputs[0]["result"] == "OK"
        assert api.points[-1] == (9, "soil", "42")


def test_qsont_device_ops_require_create_or_bind(iot_server):
    base, _ = iot_server
    with Robot(qsont_sql(base, device=0), module_paths=[MODULES]) as robot:
        with pytest.raises(DriverError, match="No device assigned"):
            robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("soil") 42;\n@',
                      timeout=30)


def test_qsont_create_requires_contract_fields(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base, device=0), module_paths=[MODULES]) as robot:
        api.responder = lambda m, p, q, a, b: (
            (200, {"id": 5}) if m == "POST" and p == "/api/v1/devices" else None)
        with pytest.raises(DriverError, match="create response"):
            robot.run('@Action\nqs.op        qs.device_name;\n$("create")  $("pot");\n@',
                      timeout=30)


def test_qsont_alias_and_vars_bindings_apply_before_build(iot_server):
    base, api = iot_server
    bindings = {"user": USER, "pass": PASSWORD, "device": str(DEVICE_ID)}
    with Robot(qsont_bound_sql(base), module_paths=[MODULES], vars=bindings) as robot:
        outputs = robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("soil") 42;\n@',
                            timeout=30)
    assert outputs[0]["result"] == "OK"
    assert api.points[-1] == (DEVICE_ID, "soil", "42")


def test_qsont_structure_bindings_are_required_at_activation(iot_server):
    base, _ = iot_server
    with pytest.raises(DriverError, match="login failed"):
        Robot(qsont_bound_sql(base), module_paths=[MODULES]).active()


def test_qsont_vars_binding_stays_numeric_in_run_session(iot_server):
    base, api = iot_server
    bindings = {"user": USER, "pass": PASSWORD, "device": str(DEVICE_ID)}
    with Robot(qsont_bound_sql(base), module_paths=[MODULES], vars=bindings) as robot:
        # run() re-applies bindings; $(device) must still resolve as a number.
        outputs = robot.run('@Action\nqs.op      qs.key     qs.value;\n$("push")  $("air") 7;\n@',
                            vars=bindings, timeout=30)
    assert outputs[0]["result"] == "OK"
    assert api.points[-1] == (DEVICE_ID, "air", "7")


def test_qsont_3xx_is_not_reported_as_success(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base), module_paths=[MODULES]) as robot:
        cases = [
            ("/api/v1/data", "POST",
             '@Action\nqs.op      qs.key           qs.value;\n'
             '$("push")  $("temperature") 23.5;\n@'),
            ("/api/v1/data/batch", "POST",
             '@Action\nqs.op      qs.items;\n$("batch")  $("humidity=60");\n@'),
            ("/api/v1/commands/11/status", "PUT",
             '@Action\nqs.op     qs.cmd;\n$("ack")  11;\n@'),
        ]
        for path, method, script in cases:
            api.responder = lambda m, p, q, a, b, path=path, method=method: (
                (307, {"detail": "redirect"}) if m == method and p == path else None)
            with pytest.raises(DriverError, match="307"):
                robot.run(script, timeout=30)


def test_qsont_requires_contract_fields(iot_server):
    base, api = iot_server
    with Robot(qsont_sql(base), module_paths=[MODULES]) as robot:
        api.responder = lambda m, p, q, a, b: (
            (200, {"id": 1}) if m == "GET" and p.endswith("/latest") else None)
        with pytest.raises(DriverError, match="latest"):
            robot.run('@Action\nqs.op       qs.key;\n'
                      '$("latest")  $("temperature");\n@', timeout=30)

        api.responder = lambda m, p, q, a, b: (
            (200, {"message": "ok"}) if m == "POST" and p == "/api/v1/devices/bind" else None)
        with pytest.raises(DriverError, match="device_id"):
            robot.run('@Action\nqs.op      qs.key;\n$("bind")  $("%s");\n@' % FOREIGN_KEY,
                      timeout=30)
