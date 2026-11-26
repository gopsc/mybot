"""TCP contract tests: real loopback peers plus deterministic nonblocking faults."""
from contextlib import contextmanager
import errno
import json
from pathlib import Path
import queue
import socket
import threading
import time

import pytest

import pymybot.hal as hal_module
from pymybot.errors import BudgetExceeded, DriverError
from pymybot.hal import HALManager
from pymybot.hardware import Budget
from pymybot.native import PythonState
from pymybot.robot import Robot
from pymybot.runtime import LuaState


ROOT = Path(__file__).resolve().parents[1]
MODULES = ROOT / "modules"
WAIT = 3
TCP_IO = {"tcp_open", "tcp_read", "tcp_write", "close_handle"}


class LoopbackPeer:
    """Each accepted socket has an event-gated command queue, never sleep sync."""

    def __init__(self, connections=1):
        self.stop = threading.Event()
        self.accepted = [threading.Event() for _ in range(connections)]
        self.commands = [queue.Queue() for _ in range(connections)]
        self.errors = queue.Queue()
        self.clients = []
        self.workers = []
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.settimeout(.1)
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen(connections)
        self.thread = threading.Thread(target=self._accept, name="tcp-test-accept", daemon=True)
        self.thread.start()

    def _accept(self):
        try:
            for index in range(len(self.commands)):
                while not self.stop.is_set():
                    try:
                        conn, address = self.listener.accept()
                        break
                    except socket.timeout:
                        continue
                else:
                    return
                assert address[0] == "127.0.0.1"
                conn.settimeout(WAIT)
                self.clients.append(conn)
                worker = threading.Thread(target=self._serve, args=(conn, index),
                                          name=f"tcp-test-peer-{index}", daemon=True)
                self.workers.append(worker)
                worker.start()
                self.accepted[index].set()
        except Exception as exc:
            if not self.stop.is_set():
                self.errors.put(exc)

    def _serve(self, conn, index):
        try:
            with conn:
                while not self.stop.is_set():
                    try:
                        operation, value, done, reply = self.commands[index].get(timeout=.1)
                    except queue.Empty:
                        continue
                    try:
                        if operation == "send":
                            conn.sendall(value)
                            result = None
                        elif operation == "capture":
                            result = bytearray()
                            while len(result) < value:
                                part = conn.recv(value - len(result))
                                if not part:
                                    raise AssertionError("client closed before sending expected bytes")
                                result.extend(part)
                            result = bytes(result)
                        elif operation == "eof":
                            conn.shutdown(socket.SHUT_WR)
                            result = None
                        elif operation == "closed":
                            result = conn.recv(1)
                        else:
                            raise AssertionError(operation)
                        reply.put(result)
                    finally:
                        done.set()
        except Exception as exc:
            if not self.stop.is_set():
                self.errors.put(exc)

    def wait_connected(self, index=0):
        assert self.accepted[index].wait(WAIT), "local TCP accept did not complete"
        self._check_errors()

    def command(self, operation, value=None, index=0):
        self.wait_connected(index)
        done, reply = threading.Event(), queue.Queue()
        self.commands[index].put((operation, value, done, reply))
        assert done.wait(WAIT), f"local peer command {operation} did not complete"
        self._check_errors()
        return reply.get_nowait()

    def _check_errors(self):
        if not self.errors.empty():
            raise self.errors.get_nowait()

    def close(self):
        self.stop.set()
        self.listener.close()
        # Join accept first, so it cannot append another worker after our snapshot.
        self.thread.join(WAIT)
        for conn in self.clients:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
        for worker in self.workers:
            worker.join(WAIT)
        assert not self.thread.is_alive()
        assert all(not worker.is_alive() for worker in self.workers)
        self._check_errors()


@pytest.fixture
def peer():
    server = LoopbackPeer()
    try:
        yield server
    finally:
        server.close()


@pytest.fixture
def manager():
    hal = HALManager()
    try:
        yield hal
    finally:
        hal.close()


def make_robot(port):
    sql = ("CREATE TABLE TCP(name String,host String,port Number);"
           f"INSERT INTO TCP(name,host,port) VALUES('net','127.0.0.1',{port});")
    return Robot(sql, module_paths=[MODULES])


def mt(robot, **fields):
    headers = " ".join(f"net.{key}" for key in fields)
    strings = {key: value for key, value in fields.items() if isinstance(value, str)}
    prefix = f"@Struct(tcp_args)\n{json.dumps(strings, ensure_ascii=False)}\n@\n" if strings else ""
    values = " ".join(f"$(tcp_args.{key})" if isinstance(value, str) else str(value)
                      for key, value in fields.items())
    return robot.run(f"{prefix}@Action\n{headers};\n{values};\n@")[-1]


def assert_received(result, field, value, count, status="data"):
    assert result["result"] == "OK", result
    assert result["status"] == status
    assert result["received"] == count
    assert result[field] == value


def assert_hal_read(result, data, status="data"):
    assert result["result"] == "OK", result
    assert result["status"] == status
    assert result["data"] == data


def forbid_io(monkeypatch, hal):
    original = hal.call
    attempts = []

    def guard(operation, *args, **kwargs):
        if operation in TCP_IO:
            attempts.append((operation, args))
            raise AssertionError(f"unexpected TCP I/O: {operation}")
        return original(operation, *args, **kwargs)

    monkeypatch.setattr(hal, "call", guard)
    return attempts


def test_static_check_build_and_read_do_not_connect(monkeypatch, peer):
    robot = make_robot(peer.port)
    attempts = forbid_io(monkeypatch, robot.hal)
    try:
        robot._validate(robot.tables)
        assert robot.state == "Loaded"
        robot.active()
        metadata = robot.registry["net"].read()
        assert metadata["fd"] == -1
        assert metadata["host"] == "127.0.0.1" and metadata["port"] == peer.port
        assert metadata["timeout"] == 1000 and metadata["num_recv"] == 512
        assert not robot.hal._handles
        assert not peer.accepted[0].is_set()
    finally:
        robot.deactivate()
    assert attempts == []


def test_mt_explicit_connect_and_close_are_idempotent(peer):
    with make_robot(peer.port) as robot:
        assert mt(robot, connect=1)["result"] == "OK"
        peer.wait_connected()
        fd = robot.registry["net"].read()["fd"]
        assert fd >= 0
        assert mt(robot, connect=1)["result"] == "OK"
        assert robot.registry["net"].read()["fd"] == fd
        assert len(robot.hal._handles) == 1
        assert mt(robot, close=1)["result"] == "OK"
        assert peer.command("closed") == b""
        assert robot.registry["net"].read()["fd"] == -1
        assert mt(robot, close=1)["result"] == "OK"
        assert not robot.hal._handles


def test_mt_zero_flags_are_noops_even_together(monkeypatch, peer):
    with make_robot(peer.port) as robot:
        attempts = forbid_io(monkeypatch, robot.hal)
        result = mt(robot, connect=0, close=0, recv_hex=0, recv_str=0, timeout=19, num_recv=7)
        assert result["result"] == "OK"
        metadata = robot.registry["net"].read()
        assert metadata["timeout"] == 19 and metadata["num_recv"] == 7
        assert metadata["fd"] == -1
        assert attempts == []


@pytest.mark.parametrize("field,value,payload,receive,expected", [
    ("send_hex", "00 ff", b"\x00\xff", "recv_hex", "00 FF"),
    ("send_hex", "00ff", b"\x00\xff", "recv_hex", "00 FF"),
    ("send_str", "你好", "你好".encode("utf-8"), "recv_str", "你好"),
])
def test_mt_hex_and_utf8_send_capture_and_receive(peer, field, value, payload, receive, expected):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        sent = mt(robot, **{field: value})
        assert sent["result"] == "OK" and sent["sent"] == len(payload)
        assert peer.command("capture", len(payload)) == payload
        peer.command("send", payload)
        assert_received(mt(robot, **{receive: 1, "num_recv": len(payload)}),
                        receive, expected, len(payload))


@pytest.mark.parametrize("timeout,count", [(1, 1), (60000, 512)])
def test_mt_settings_persist_and_apply_with_one_operation(peer, timeout, count):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        mt(robot, connect=1, timeout=timeout, num_recv=count)
        metadata = robot.registry["net"].read()
        assert metadata["timeout"] == timeout and metadata["num_recv"] == count
        # A second settings-only call changes exactly one persistent setting.
        mt(robot, timeout=123)
        assert robot.registry["net"].read()["num_recv"] == count
        peer.command("send", b"X" * count)
        assert_received(mt(robot, recv_hex=1), "recv_hex", " ".join(["58"] * count), count)
        assert robot.registry["net"].read()["timeout"] == 123


def test_connected_read_is_metadata_only(monkeypatch, peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        peer.command("send", b"\xff")
        with monkeypatch.context() as patch:
            attempts = forbid_io(patch, robot.hal)
            metadata = robot.registry["net"].read()
            assert metadata["fd"] >= 0
            assert not {"recv_hex", "recv_str", "received", "status", "data"} & metadata.keys()
            assert attempts == []
        assert_received(mt(robot, recv_hex=1), "recv_hex", "FF", 1)


def test_driver_read_timeout_vs_eof_and_explicit_reconnect():
    peer = LoopbackPeer(connections=2)
    try:
        with make_robot(peer.port) as robot:
            mt(robot, connect=1, timeout=20)
            fd = robot.registry["net"].read()["fd"]
            assert_received(mt(robot, recv_hex=1), "recv_hex", "", 0, "timeout")
            assert robot.registry["net"].read()["fd"] == fd
            peer.command("send", b"A")
            assert_received(mt(robot, recv_hex=1), "recv_hex", "41", 1)
            peer.command("eof")
            assert_received(mt(robot, recv_str=1), "recv_str", "", 0, "eof")
            assert robot.registry["net"].read()["fd"] == -1
            with pytest.raises(DriverError):
                mt(robot, send_str="not-replayed")
            assert mt(robot, connect=1)["result"] == "OK"
            peer.wait_connected(1)
            new_fd = robot.registry["net"].read()["fd"]
            assert new_fd >= 0 and new_fd != fd
            peer.command("send", b"B", index=1)
            assert_received(mt(robot, recv_str=1), "recv_str", "B", 1)
    finally:
        peer.close()


def test_fragmented_utf8_survives_timeout_and_next_packet(peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1, timeout=20, num_recv=1)
        peer.command("send", b"\xe4")
        assert_received(mt(robot, recv_str=1), "recv_str", "", 1)
        assert_received(mt(robot, recv_str=1), "recv_str", "", 0, "timeout")
        peer.command("send", b"\xbd")
        assert_received(mt(robot, recv_str=1), "recv_str", "", 1)
        peer.command("send", b"\xa0")
        assert_received(mt(robot, recv_str=1), "recv_str", "你", 1)
        peer.command("send", "好".encode("utf-8"))
        assert_received(mt(robot, recv_str=1, num_recv=3), "recv_str", "好", 3)


def test_switch_to_hex_flushes_pending_before_socket_bytes(peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1, num_recv=2)
        peer.command("send", b"\xe4\xbd")
        assert_received(mt(robot, recv_str=1), "recv_str", "", 2)
        peer.command("send", b"\xa0Z")
        # Hex mode must return the decoder tail first, without consuming new I/O.
        assert_received(mt(robot, recv_hex=1), "recv_hex", "E4 BD", 2)
        assert_received(mt(robot, recv_hex=1), "recv_hex", "A0 5A", 2)
        peer.command("send", "你".encode("utf-8"))
        assert_received(mt(robot, recv_str=1, num_recv=3), "recv_str", "你", 3)


def test_invalid_received_utf8_closes_connection_without_auto_replay(monkeypatch, peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        peer.command("send", b"\xff")
        with pytest.raises(DriverError, match="UTF-8"):
            mt(robot, recv_str=1)
        assert robot.registry["net"].read()["fd"] == -1
        assert peer.command("closed") == b""
        attempts = forbid_io(monkeypatch, robot.hal)
        with pytest.raises(DriverError):
            mt(robot, recv_hex=1)
        assert attempts == []


@pytest.mark.parametrize("fields", [
    {"send_hex": "0", "timeout": 27},
    {"send_hex": "gg", "num_recv": 9},
    {"send_str": "\ud800", "timeout": 27},
    {"send_str": 123, "num_recv": 9},
    {"timeout": 0, "connect": 1},
    {"timeout": 60001, "recv_hex": 1},
    {"num_recv": 0, "close": 1},
    {"num_recv": 513, "send_hex": "00"},
    {"connect": 1, "close": 1, "timeout": 27},
    {"send_hex": "00", "recv_str": 1, "num_recv": 9},
])
def test_invalid_driver_call_is_atomic_and_has_no_io(monkeypatch, peer, fields):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        before = robot.registry["net"].read()
        with monkeypatch.context() as patch:
            attempts = forbid_io(patch, robot.hal)
            with pytest.raises(DriverError):
                robot.registry["net"].play(fields)
            assert robot.registry["net"].read() == before
            assert attempts == []
        assert mt(robot, send_hex="00")["sent"] == 1
        assert peer.command("capture", 1) == b"\x00"


@contextmanager
def refused_port():
    # Keep the port reserved without listen(), eliminating free-port reuse races.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
        reserved.bind(("127.0.0.1", 0))
        yield reserved.getsockname()[1]


def test_connection_refusal_does_not_autoconnect_or_replay(monkeypatch):
    with refused_port() as port, make_robot(port) as robot:
        with pytest.raises(DriverError):
            mt(robot, connect=1, timeout=100)
        assert robot.registry["net"].read()["fd"] == -1
        assert not robot.hal._handles
        attempts = forbid_io(monkeypatch, robot.hal)
        with pytest.raises(DriverError):
            mt(robot, send_str="never-sent")
        with pytest.raises(DriverError):
            mt(robot, recv_hex=1)
        assert attempts == []


def test_deactivate_closes_tcp_and_reclaims_owner(peer):
    robot = make_robot(peer.port)
    try:
        robot.active()
        mt(robot, connect=1)
        runtime = robot.registry["net"].runtime
        assert robot.hal._handles
        robot.deactivate()
        assert peer.command("closed") == b""
        assert not robot.hal._handles and not robot.hal._owners
        assert runtime._closed
    finally:
        robot.deactivate()


def test_hal_real_socket_default_timeout_and_512_byte_boundary(manager, peer):
    fd = manager.call("tcp_open", "127.0.0.1", peer.port)
    assert type(fd) is int and fd >= 0
    sock = manager._handles[fd].device
    assert sock.gettimeout() == 0.0, "actual TCP socket must be nonblocking"
    payload = list(range(256)) * 2
    written = manager.call("tcp_write", fd, payload)
    assert written["result"] == "OK" and written["sent"] == 512
    assert peer.command("capture", 512) == bytes(payload)
    peer.command("send", bytes(payload))
    assert_hal_read(manager.call("tcp_read", fd, 512), payload)
    assert manager.call("close_handle", fd) == 0
    assert sock.fileno() == -1


def test_hal_timeout_keeps_socket_but_eof_retires_it_until_close(manager, peer):
    fd = manager.call("tcp_open", "127.0.0.1", peer.port)
    sock = manager._handles[fd].device
    assert_hal_read(manager.call("tcp_read", fd, 1, 20), [], "timeout")
    assert sock.fileno() >= 0 and fd in manager._handles
    peer.command("send", b"\x00")
    assert_hal_read(manager.call("tcp_read", fd, 1), [0])
    peer.command("eof")
    assert_hal_read(manager.call("tcp_read", fd, 1), [], "eof")
    assert sock.fileno() == -1
    assert fd in manager._handles, "EOF retires the socket, not its logical handle"
    assert manager.call("close_handle", fd) == 0
    assert fd not in manager._handles


def test_hal_same_endpoint_connections_are_independent(manager):
    peer = LoopbackPeer(connections=2)
    try:
        a = manager.call("tcp_open", "127.0.0.1", peer.port)
        b = manager.call("tcp_open", "127.0.0.1", peer.port)
        peer.wait_connected(1)
        assert type(a) is int and type(b) is int and a >= 0 and b >= 0 and a != b
        assert manager._handles[a] is not manager._handles[b]
        assert manager._handles[a].device is not manager._handles[b].device
        peer.command("send", b"A", index=0)
        peer.command("send", b"B", index=1)
        assert_hal_read(manager.call("tcp_read", a, 1), [65])
        assert_hal_read(manager.call("tcp_read", b, 1), [66])
        manager.call("close_handle", a)
        assert peer.command("closed", index=0) == b""
        result = manager.call("tcp_write", b, [67])
        assert result["result"] == "OK" and result["sent"] == 1
        assert peer.command("capture", 1, index=1) == b"C"
        manager.call("close_handle", b)
    finally:
        peer.close()


@pytest.mark.parametrize("port,timeout", [
    (True, 1000), (float("nan"), 1000), (80, True), (80, float("nan")),
])
def test_hal_rejects_bool_and_nan_before_open_io(monkeypatch, manager, port, timeout):
    attempts = []

    def forbidden(*args, **kwargs):
        attempts.append((args, kwargs))
        raise AssertionError("invalid TCP arguments must not create a socket")

    monkeypatch.setattr(hal_module.socket, "socket", forbidden)
    assert manager.call("tcp_open", "127.0.0.1", port, timeout) == -1
    assert attempts == [] and not manager._handles


@pytest.mark.parametrize("operation,payload,timeout", [
    ("tcp_read", True, 1000),
    ("tcp_read", float("nan"), 1000),
    ("tcp_read", 513, 1000),
    ("tcp_write", [True], 1000),
    ("tcp_write", [float("nan")], 1000),
    ("tcp_write", [0] * 513, 1000),
    ("tcp_write", [0], True),
    ("tcp_read", 1, float("nan")),
])
def test_hal_invalid_read_write_do_not_touch_socket(monkeypatch, manager, fake_socket, operation, payload, timeout):
    fd = manager.call("tcp_open", "127.0.0.1", 12345)
    assert type(fd) is int and fd >= 0
    fake_socket.calls.clear()
    fake_socket.polls.clear()
    result = manager.call(operation, fd, payload, timeout)
    assert result["result"] == "ERR" and result["message"]
    if operation == "tcp_write":
        assert result["sent"] == 0
    assert not fake_socket.calls and not fake_socket.polls
    assert not fake_socket.closed


def runtime_call(state, operation, *args):
    if isinstance(state, PythonState):
        return state.context.call(operation, *args)
    bridge = state.lua.eval("function(op, ...) return __hal_call(op, ...) end")
    return state.from_lua(bridge(operation, *(state.to_lua(arg) for arg in args)))


@pytest.mark.parametrize("state_class", [PythonState, LuaState])
def test_direct_runtime_tcp_open_blocks_nonloopback_before_socket_io(monkeypatch, manager, state_class):
    state = state_class([MODULES], manager, threading.Event())
    attempts = []

    def forbidden(*args, **kwargs):
        attempts.append((args, kwargs))
        raise AssertionError("permission gate must run before networking")

    monkeypatch.setattr(hal_module.socket, "socket", forbidden)
    try:
        with pytest.raises(DriverError, match="allow-hardware"):
            runtime_call(state, "tcp_open", "192.0.2.1", 80)
        assert attempts == [] and not manager._handles
    finally:
        state.close()


@pytest.mark.parametrize("state_class", [PythonState, LuaState])
def test_direct_runtime_loopback_and_main_thread_owner_cleanup(manager, peer, state_class):
    state = state_class([MODULES], manager, threading.Event())
    try:
        fd = runtime_call(state, "tcp_open", "127.0.0.1", peer.port)
        assert type(fd) is int and fd >= 0
        peer.wait_connected()
        sock = manager._handles[fd].device
        assert runtime_call(state, "tcp_write", fd, [1, 2])["sent"] == 2
        assert peer.command("capture", 2) == b"\x01\x02"
        state.close()
        assert sock.fileno() == -1
        assert peer.command("closed") == b""
        assert not manager._handles and not manager._owners
    finally:
        state.close()


class FakeSocket:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.blocking = True
        self.connect_error = getattr(errno, "WSAEWOULDBLOCK", errno.EINPROGRESS)
        self.so_error = 0
        self.sends = []
        self.reads = []
        self.polls = []
        self.on_poll = None

    def setblocking(self, value):
        self.calls.append(("setblocking", value))
        self.blocking = value

    def gettimeout(self):
        return None if self.blocking else 0.0

    def connect_ex(self, address):
        self.calls.append(("connect_ex", address))
        return self.connect_error

    def getsockopt(self, level, option):
        self.calls.append(("getsockopt", level, option))
        assert (level, option) == (socket.SOL_SOCKET, socket.SO_ERROR)
        return self.so_error

    def send(self, data):
        self.calls.append(("send", bytes(data)))
        action = self.sends.pop(0) if self.sends else len(data)
        if isinstance(action, BaseException):
            raise action
        assert 0 <= action <= len(data)
        return action

    def recv(self, count):
        self.calls.append(("recv", count))
        action = self.reads.pop(0) if self.reads else BlockingIOError(errno.EWOULDBLOCK, "not ready")
        if isinstance(action, BaseException):
            raise action
        assert len(action) <= count
        return action

    def close(self):
        self.closed = True

    def fileno(self):
        return -1 if self.closed else 101

    def select(self, readers, writers, exceptional, timeout=None):
        self.polls.append(timeout)
        assert timeout is not None and 0 <= timeout <= .1, "select must use short deadline/cancel polls"
        if self.on_poll is not None:
            return self.on_poll(readers, writers, exceptional)
        return list(readers), list(writers), []


@pytest.fixture
def fake_socket(monkeypatch):
    sock = FakeSocket()
    monkeypatch.setattr(hal_module.socket, "socket", lambda *args, **kwargs: sock)
    monkeypatch.setattr(hal_module.select, "select", sock.select)
    return sock


def test_hal_short_writes_finish_without_replaying_prefix(manager, fake_socket):
    fd = manager.call("tcp_open", "127.0.0.1", 12345)
    assert type(fd) is int and fd >= 0
    fake_socket.sends = [2, BlockingIOError(errno.EWOULDBLOCK, "busy"), 1, 3]
    result = manager.call("tcp_write", fd, [0, 1, 2, 3, 4, 5], 1000)
    assert result["result"] == "OK" and result["sent"] == 6
    assert [call[1] for call in fake_socket.calls if call[0] == "send"] == [
        b"\x00\x01\x02\x03\x04\x05", b"\x02\x03\x04\x05", b"\x02\x03\x04\x05", b"\x03\x04\x05"]
    assert not fake_socket.blocking and not fake_socket.closed


def test_hal_partial_send_failure_preserves_sent_and_never_replays(manager, fake_socket):
    fd = manager.call("tcp_open", "127.0.0.1", 12345)
    assert type(fd) is int and fd >= 0
    fake_socket.sends = [2, OSError(errno.ECONNRESET, "synthetic reset")]
    result = manager.call("tcp_write", fd, [0, 1, 2, 3])
    assert result["result"] == "ERR" and result["sent"] == 2 and result["message"]
    assert [call for call in fake_socket.calls if call[0] == "send"] == [
        ("send", b"\x00\x01\x02\x03"), ("send", b"\x02\x03")]
    assert len([call for call in fake_socket.calls if call[0] == "connect_ex"]) == 1
    assert fake_socket.closed


@pytest.mark.parametrize("operation", ["tcp_open", "tcp_read", "tcp_write"])
def test_hal_connect_and_io_cancel_close_socket_and_propagate(manager, fake_socket, operation):
    fd = None
    if operation != "tcp_open":
        fd = manager.call("tcp_open", "127.0.0.1", 12345)
        assert type(fd) is int and fd >= 0
    cancelled = threading.Event()

    def poll(readers, writers, exceptional):
        cancelled.set()
        return [], [], []

    def check():
        if cancelled.is_set():
            raise BudgetExceeded("synthetic TCP cancellation")

    fake_socket.on_poll = poll
    value = [1] if operation == "tcp_write" else 1
    args = ("127.0.0.1", 12345, 60000) if fd is None else (fd, value, 60000)
    started = time.monotonic()
    with pytest.raises(BudgetExceeded, match="synthetic TCP cancellation"):
        manager.call(operation, *args, cancel_check=check)
    assert time.monotonic() - started < 1
    assert fake_socket.polls and fake_socket.closed
    if operation == "tcp_open":
        assert not manager._handles
    else:
        manager.call("close_handle", fd)
    assert not manager._handles


def test_hal_connect_checks_so_error_and_closes_failed_socket(manager, fake_socket):
    fake_socket.so_error = getattr(errno, "WSAECONNREFUSED", errno.ECONNREFUSED)
    assert manager.call("tcp_open", "127.0.0.1", 12345, 1000) == -1
    assert any(call[0] == "getsockopt" for call in fake_socket.calls)
    assert fake_socket.closed and not manager._handles
    assert manager.call("last_error")


def test_direct_hal_has_no_runtime_permission_gate(manager, fake_socket):
    # Reserved TEST-NET address is safe: the socket constructor is stubbed.
    fd = manager.call("tcp_open", "192.0.2.1", 80)
    assert type(fd) is int and fd >= 0
    assert ("connect_ex", ("192.0.2.1", 80)) in fake_socket.calls


@pytest.mark.parametrize("operation", ["tcp_open", "tcp_read", "tcp_write"])
@pytest.mark.parametrize("state_class", [PythonState, LuaState])
def test_runtime_cancel_after_hal_return_closes_stream(monkeypatch, manager, fake_socket, operation, state_class):
    state = state_class([MODULES], manager, threading.Event())
    state.budget = Budget(state.stop_event, timeout=5)
    try:
        fd = None
        if operation != "tcp_open":
            fd = runtime_call(state, "tcp_open", "127.0.0.1", 12345)
        fake_socket.reads = [b"A"]
        original = manager.call

        def cancel_after_call(name, *args, **kwargs):
            result = original(name, *args, **kwargs)
            if name == operation:
                state.stop_event.set()
            return result

        monkeypatch.setattr(manager, "call", cancel_after_call)
        args = ("127.0.0.1", 12345) if fd is None else (float(fd), [65] if operation == "tcp_write" else 1)
        with pytest.raises(BudgetExceeded):
            runtime_call(state, operation, *args)
        assert fake_socket.closed
        assert not manager._handles and not manager._owners
    finally:
        state.close()


@pytest.mark.parametrize("operation", ["recv_hex", "recv_str", "send_str"])
def test_driver_cancel_invalidates_fd_and_allows_explicit_reconnect(monkeypatch, manager, fake_socket, operation):
    state = PythonState([MODULES], manager, threading.Event())
    try:
        state.load(MODULES / "TCP.py")
        state.call("build", {"host": "127.0.0.1", "port": 12345})
        old_fd = state.call("call", {"connect": 1})["fd"]
        state.driver.utf8_pending = b"\xe4" if operation != "recv_hex" else b""

        def cancel_in_poll(readers, writers, exceptional):
            state.stop_event.set()
            return [], [], []

        fake_socket.on_poll = cancel_in_poll
        with pytest.raises(BudgetExceeded):
            state.call("call", {operation: "A" if operation == "send_str" else 1})
        assert fake_socket.closed
        assert not manager._handles and not manager._owners
        state.stop_event.clear()
        assert state.call("read")["connected"] is False
        assert state.driver.utf8_pending == b""
        replacement = FakeSocket()
        monkeypatch.setattr(hal_module.socket, "socket", lambda *args, **kwargs: replacement)
        monkeypatch.setattr(hal_module.select, "select", replacement.select)
        new_fd = state.call("call", {"connect": 1})["fd"]
        assert new_fd >= 0 and new_fd != old_fd
        assert not replacement.closed
    finally:
        state.close()


def test_hal_late_readiness_does_not_extend_total_write_deadline(monkeypatch, manager, fake_socket):
    fd = manager.call("tcp_open", "127.0.0.1", 12345)
    now = [0.0]
    monkeypatch.setattr(hal_module.time, "monotonic", lambda: now[0])

    def delayed_ready(readers, writers, exceptional):
        now[0] += .6
        return readers, writers, []

    fake_socket.on_poll = delayed_ready
    fake_socket.sends = [2, 2]
    result = manager.call("tcp_write", fd, [0, 1, 2, 3], 1000)
    assert result["result"] == "ERR" and result["sent"] == 2
    assert [call for call in fake_socket.calls if call[0] == "send"] == [("send", b"\x00\x01\x02\x03")]
    assert fake_socket.closed


def test_incomplete_utf8_at_eof_is_error_and_closes_connection(peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        peer.command("send", b"\xe4")
        assert_received(mt(robot, recv_str=1), "recv_str", "", 1)
        peer.command("eof")
        with pytest.raises(DriverError, match="UTF-8"):
            mt(robot, recv_str=1)
        assert robot.registry["net"].read()["connected"] is False
        assert not robot.hal._handles


def test_mt_hex_receive_capture_can_be_sent_again(peer):
    with make_robot(peer.port) as robot:
        mt(robot, connect=1)
        peer.command("send", b"\x00\xff")
        outputs = robot.run("@Action\nnet.recv_hex net.reply;\n1 $reply=recv_hex;\n@\n"
                            "@Action\nnet.send_hex;\n$(reply);\n@")
        assert outputs[0]["recv_hex"] == "00 FF"
        assert outputs[-1]["sent"] == 2
        assert peer.command("capture", 2) == b"\x00\xff"
