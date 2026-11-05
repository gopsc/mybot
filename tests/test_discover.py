"""pymybot discover: read-only host device enumeration, shared with the skill surface."""
import json
import sys
import types

import pytest

from pymybot import cli
from pymybot.agent_skill_runner import _GENERIC_COMMANDS
from pymybot.discover import BUSES, DiscoveryError, _enumerate_ftdi, _hints, _probe_uart_ports, \
    discover, parse_buses


def test_parse_buses_accepts_subsets_and_all():
    assert parse_buses(None) == BUSES
    assert parse_buses("all") == BUSES
    assert parse_buses(" UART, ftdi ") == ("uart", "ftdi")
    assert parse_buses("i2c,spi,uart,ftdi") == BUSES


@pytest.mark.parametrize("raw", ["bogus", "i2c,bogus", "", "   "])
def test_parse_buses_rejects_unknown_or_empty(raw):
    with pytest.raises(DiscoveryError):
        parse_buses(raw)


class _Descriptor:
    def __init__(self, vid, pid, sn, description):
        self.vid, self.pid, self.sn, self.description = vid, pid, sn, description


def _fake_ftdi_module(monkeypatch, devices=(), error=None):
    fake = types.ModuleType("pyftdi.ftdi")
    fake.Ftdi = types.SimpleNamespace(
        list_devices=(error if error is not None else lambda: devices))
    monkeypatch.setitem(sys.modules, "pyftdi.ftdi", fake)


def test_ftdi_enumeration_builds_hal_ready_urls(monkeypatch):
    _fake_ftdi_module(monkeypatch, devices=[
        (_Descriptor(0x0403, 0x6001, "ABC123", "FT232R USB UART"), 1),
        (_Descriptor(0x0403, 0x6014, None, None), 2)])
    report = _enumerate_ftdi()
    assert report["supported"] is True and report["notes"] == []
    assert report["adapters"][0] == {
        "vid": "0x0403", "pid": "0x6001", "interface": 1, "serial": "ABC123",
        "description": "FT232R USB UART", "url": "ftdi://0403:6001:ABC123/1"}
    assert report["adapters"][1]["url"] == "ftdi://0403:6014/2"
    assert "serial" not in report["adapters"][1] and "description" not in report["adapters"][1]


def test_ftdi_enumeration_survives_missing_pyftdi_and_usb_errors(monkeypatch):
    monkeypatch.setitem(sys.modules, "pyftdi", None)
    monkeypatch.setitem(sys.modules, "pyftdi.ftdi", None)
    missing = _enumerate_ftdi()
    assert missing["supported"] is False and not missing["adapters"]
    assert "pyftdi is not installed" in missing["notes"][0]

    def boom():
        raise OSError("usb blast")

    _fake_ftdi_module(monkeypatch, error=boom)
    failed = _enumerate_ftdi()
    assert failed["supported"] is True and failed["adapters"] == []
    assert "OSError" in failed["notes"][0]


class _FakePort:
    def __init__(self):
        self.opened = False
        self.dtr = None
        self.rts = None

    def open(self):
        self.opened = True

    def close(self):
        self.opened = False


def _fake_serial(monkeypatch):
    fake = types.ModuleType("serial")

    class SerialException(IOError):
        pass

    made = {}
    failures = {}

    def serial_for_url(device, **kwargs):
        assert kwargs.get("do_not_open") is True
        if device in failures:
            raise failures[device]
        port = _FakePort()
        made[device] = port
        return port

    fake.serial_for_url = serial_for_url
    fake.SerialException = SerialException
    monkeypatch.setitem(sys.modules, "serial", fake)
    return made, SerialException, failures


def test_probe_reports_free_and_busy_ports(monkeypatch):
    made, SerialException, failures = _fake_serial(monkeypatch)
    failures["/dev/ttyUSB1"] = SerialException(11, "Device or resource busy")
    failures["/dev/ttyUSB2"] = SerialException(13, "Permission denied")
    failures["/dev/ttyUSB3"] = RuntimeError("no driver")
    ports = [{"device": "/dev/ttyUSB0"}, {"device": "/dev/ttyUSB1"},
             {"device": "/dev/ttyUSB2"}, {"device": "/dev/ttyUSB3"},
             {"device": "/dev/ttyS4", "source": "sysfs"}]
    _probe_uart_ports(ports)
    assert ports[0]["in_use"] is False
    assert made["/dev/ttyUSB0"].dtr is False and made["/dev/ttyUSB0"].rts is False
    assert ports[1]["in_use"] is True and ports[1]["probe_error"] == "busy"
    assert ports[2]["in_use"] is None and ports[2]["probe_error"] == "denied"
    assert ports[3]["in_use"] is None and ports[3]["probe_error"] == "error"
    assert "in_use" not in ports[4]  # Sysfs-only nodes are never probed.


def _report(**overrides):
    report = {
        "uart": {"ports": [{"device": "/dev/ttyUSB0"}, {"device": "/dev/ttyS0", "source": "sysfs"},
                           {"device": "bad's"}]},
        "i2c": {"adapters": [{"device": "/dev/i2c-1"}, {"device": "/dev/i2c-9", "node_present": False}]},
        "spi": {"devices": [{"device": "/dev/spidev0.0"}]},
        "ftdi": {"adapters": [{"url": "ftdi://0403:6001:SN/1"},
                              {"url": "ft'di://bad"}]},
    }
    report.update(overrides)
    return report


def test_hints_map_devices_to_structure_sql():
    hints = _hints(_report())
    by_kind = {}
    for hint in hints:
        by_kind.setdefault(hint["kind"], []).append(hint)
    assert [h["device"] for h in by_kind["uart"]] == ["/dev/ttyUSB0"]
    assert by_kind["uart"][0]["sql"] == ("CREATE TABLE UART (name, path, baud);\n"
                                         "INSERT INTO UART (name, path, baud) VALUES ('bus', '/dev/ttyUSB0', 115200);")
    assert [h["device"] for h in by_kind["i2c"]] == ["/dev/i2c-1"]
    assert [h["device"] for h in by_kind["spi"]] == ["/dev/spidev0.0"]
    assert [h["device"] for h in by_kind["ftdi-i2c"]] == ["ftdi://0403:6001:SN/1"]
    assert by_kind["ftdi-spi"][0]["device"] == "ftdi://0403:6001:SN/1?cs=0"
    assert by_kind["ftdi-spi"][0]["sql"].startswith("CREATE TABLE SPI (name, path);")


def test_hints_skip_unsafe_values_and_cap_the_list():
    hints = _hints(_report())
    assert all("'" not in hint["device"] for hint in hints)
    flooded = _report(uart={"ports": [{"device": f"/dev/ttyUSB{i}"} for i in range(200)]})
    assert len(_hints(flooded)) == 64


def test_discover_runs_the_bundled_driver_read_only():
    report = discover(("uart",))
    assert report["platform"] and report["buses"] == ["uart"]
    assert report["uart"]["backend"] == "pyserial"
    assert isinstance(report["hints"], list)
    assert "ftdi" not in report and "i2c" not in report


def test_discover_ftdi_only_keeps_the_report_shape():
    report = discover(("ftdi",))
    assert report["buses"] == ["ftdi"] and "ftdi" in report
    for bus in ("i2c", "spi", "uart"):
        assert report[bus]["supported"] is False


def test_discover_is_on_the_skill_surface():
    assert "discover" in _GENERIC_COMMANDS


def test_cli_discover_prints_json_and_validates_buses(capsys):
    assert cli.main(["discover", "--buses", "uart"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True and payload["command"] == "discover"
    assert payload["buses"] == ["uart"] and "hints" in payload
    assert cli.main(["discover", "--buses", "nope"]) == 2
    error = json.loads(capsys.readouterr().out)
    assert error["ok"] is False and error["error"]["type"] == "UsageError"
