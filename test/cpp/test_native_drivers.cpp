/* test_native_drivers.cpp —— C++ 原生驱动的直接单测（不经过 Lua/MatrixRunner） */

#include <string>

#include "hal.hpp"
#include "harness.hpp"
#include "native_driver.hpp"
#include "util_except.hpp"

namespace {

bot::Json callData(std::initializer_list<std::pair<const char*, bot::Json>> items) {
	bot::Json data = bot::JsonObject();
	for (const auto& item : items) { data.put(item.first, item.second); }
	return data;
}

} // namespace

TH_TEST(native_time_driver_reports_clock_fields) {
	bot::HALManager hal;
	auto driver = bot::makeTimeDriver(hal);
	TH_CHECK(driver->build(bot::JsonObject()).find("result")->getValue() == "OK");
	bot::Json result = driver->call(bot::JsonObject());
	TH_CHECK(result.find("result") != nullptr);
	TH_CHECK(result.find("result")->getValue() == "OK");
	TH_CHECK(result.find("epoch") != nullptr && result.find("epoch")->getInt() > 0);
	TH_CHECK(result.find("utc") != nullptr && result.find("utc")->isStr());
	TH_CHECK(result.find("local") != nullptr && result.find("local")->isStr());
	TH_CHECK(result.find("weekday") != nullptr);
	TH_CHECK(result.find("weekday")->getInt() >= 1 && result.find("weekday")->getInt() <= 7);
}

TH_TEST(native_time_driver_formats_with_the_documented_subset) {
	bot::HALManager hal;
	auto driver = bot::makeTimeDriver(hal);
	bot::Json data = callData({
		{"format", bot::JsonString("%H:%M:%S")},
		{"utc", bot::JsonInt(1)},
	});
	bot::Json result = driver->call(data);
	TH_CHECK(result.find("formatted") != nullptr);
	TH_CHECK(result.find("formatted")->getValue().size() == 8);
	bot::Json bad = callData({{"format", bot::JsonString("%a")}});
	bot::Json rejected = driver->call(bad);
	TH_CHECK(rejected.find("result")->getValue() == "ERR");
}

TH_TEST(native_loopback_probe_echoes_through_the_hal) {
	bot::HALManager hal;
	bot::Json opened = hal.call("uart_open",
		{bot::JsonString("loop://"), bot::JsonInt(115200)});
	TH_CHECK(opened.isInt() && opened.getInt() >= 0);
	auto driver = bot::makeLoopbackProbeDriver(hal);
	bot::Json data = callData({
		{"fd", opened},
		{"value", bot::JsonInt(42)},
	});
	bot::Json result = driver->call(data);
	TH_CHECK(result.find("result")->getValue() == "OK");
	TH_CHECK(result.find("rx") != nullptr && result.find("rx")->getInt() == 42);
}

TH_TEST(native_shell_driver_requires_the_hardware_gate) {
	bot::HALManager hal;
	auto driver = bot::makeShellDriver(hal);
	bot::Json rejected = driver->build(callData({{"timeout", bot::JsonInt(1000)}}));
	TH_CHECK(rejected.find("result")->getValue() == "ERR");
}

TH_TEST(native_shell_driver_runs_a_command_when_allowed) {
	bot::HALManager hal;
	hal.setAllowHardware(true);
	auto driver = bot::makeShellDriver(hal);
	bot::Json built = driver->build(callData({{"timeout", bot::JsonInt(5000)}}));
	TH_CHECK(built.find("result")->getValue() == "OK");
	bot::Json result = driver->call(callData({{"cmd", bot::JsonString("echo hello")}}));
	TH_CHECK(result.find("result")->getValue() == "OK");
	TH_CHECK(result.find("code") != nullptr && result.find("code")->getInt() == 0);
	TH_CHECK(result.find("out") != nullptr
		&& result.find("out")->getValue().find("hello") != std::string::npos);
	TH_CHECK(result.find("truncated") != nullptr
		&& result.find("truncated")->isBool() && !result.find("truncated")->getBool());
}

TH_TEST(native_dev_enum_reports_linux_buses) {
	bot::HALManager hal;
	auto driver = bot::makeDevEnumDriver(hal);
	TH_CHECK(driver->build(bot::JsonObject()).find("result")->getValue() == "OK");
	bot::Json result = driver->call(bot::JsonObject());
	TH_CHECK(result.find("result")->getValue() == "OK");
	TH_CHECK(result.find("platform")->getValue() == "linux");
	TH_CHECK(result.find("i2c") != nullptr);
	TH_CHECK(result.find("spi") != nullptr);
	TH_CHECK(result.find("uart") != nullptr);
}

TH_TEST(hal_gates_ftdi_behind_allow_hardware) {
	bot::HALManager hal;
	bot::Json result = hal.call("i2c_open",
		{bot::JsonString("ftdi://ftdi:232h/1"), bot::JsonBool(false)});
	TH_CHECK(result.isInt() && result.getInt() == -1);
	bot::Json last = hal.call("last_error", {});
	TH_CHECK(last.isStr() && last.getValue().find("allow-hardware") != std::string::npos);
}
