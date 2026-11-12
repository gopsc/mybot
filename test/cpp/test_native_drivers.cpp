/* test_native_drivers.cpp —— C++ 原生驱动的直接单测（不经过 Lua/MatrixRunner） */

#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "fixtures.hpp"
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

void writeText(const std::filesystem::path& path, const std::string& text) {
	std::ofstream out(path, std::ios::binary | std::ios::trunc);
	if (!out) { throw std::runtime_error("cannot write " + path.string()); }
	out << text;
}

std::string readText(const std::filesystem::path& path) {
	std::ifstream in(path, std::ios::binary);
	if (!in) { return std::string(); }
	return std::string(std::istreambuf_iterator<char>(in),
		std::istreambuf_iterator<char>());
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

TH_TEST(native_shell_driver_runs_a_command) {
	bot::HALManager hal;
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

TH_TEST(hal_gpio_rejects_bad_chip_and_invalid_handles) {
	bot::HALManager hal;
	bot::Json badPath = hal.call("gpio_request_line",
		{bot::JsonString("/tmp/not-a-gpiochip"), bot::JsonInt(0),
		 bot::JsonString("out"), bot::JsonInt(0), bot::JsonBool(false)});
	TH_CHECK(badPath.isInt() && badPath.getInt() == -1);

	bot::Json missingChip = hal.call("gpio_request_line",
		{bot::JsonString("/dev/gpiochip9999"), bot::JsonInt(0),
		 bot::JsonString("out"), bot::JsonInt(0), bot::JsonBool(false)});
	TH_CHECK(missingChip.isInt() && missingChip.getInt() == -1);

	bot::Json setResult = hal.call("gpio_set_value",
		{bot::JsonInt(999), bot::JsonInt(1)});
	TH_CHECK(setResult.isBool() && !setResult.getBool());
	bot::Json getResult = hal.call("gpio_get_value", {bot::JsonInt(999)});
	TH_CHECK(getResult.isInt() && getResult.getInt() == -1);
}

TH_TEST(hal_pwm_uses_the_configured_sysfs_root) {
	fx::TempDir dir("hal_pwm");
	const std::filesystem::path chip = dir.path() / "pwmchip0";
	const std::filesystem::path channel = chip / "pwm1";
	std::filesystem::create_directories(channel);
	writeText(chip / "npwm", "2");
	writeText(chip / "unexport", "");
	writeText(channel / "enable", "1");
	writeText(channel / "period", "0");
	writeText(channel / "duty_cycle", "0");
	writeText(channel / "polarity", "normal");
	fx::EnvVar root("BOT4CJ_PWM_SYSFS_ROOT", dir.path().c_str());

	bot::HALManager hal;
	bot::Json npwm = hal.call("pwm_npwm", {bot::JsonInt(0)});
	TH_CHECK(npwm.isInt() && npwm.getInt() == 2);
	TH_CHECK(hal.call("pwm_exported", {bot::JsonInt(0), bot::JsonInt(1)}).getBool());
	TH_CHECK(hal.call("pwm_export", {bot::JsonInt(0), bot::JsonInt(1)}).getBool());

	bot::Json config = hal.call("pwm_config",
		{bot::JsonInt(0), bot::JsonInt(1), bot::JsonInt(1000), bot::JsonInt(25)});
	TH_CHECK(config.isArr() && config.size() == 3);
	TH_CHECK(config.at(0).isBool() && config.at(0).getBool());
	TH_CHECK(config.at(1).getInt() == 1000000);
	TH_CHECK(config.at(2).getInt() == 250000);
	TH_CHECK(readText(channel / "period") == "1000000");
	TH_CHECK(readText(channel / "duty_cycle") == "250000");

	TH_CHECK(hal.call("pwm_set_polarity",
		{bot::JsonInt(0), bot::JsonInt(1), bot::JsonBool(true)}).getBool());
	TH_CHECK(readText(channel / "polarity") == "inversed");
	TH_CHECK(hal.call("pwm_enable",
		{bot::JsonInt(0), bot::JsonInt(1), bot::JsonBool(true)}).getBool());
	TH_CHECK(readText(channel / "enable") == "1");
	TH_CHECK(hal.call("pwm_unexport",
		{bot::JsonInt(0), bot::JsonInt(1)}).getBool());
	TH_CHECK(readText(chip / "unexport") == "1");

	bot::Json outOfRange = hal.call("pwm_export",
		{bot::JsonInt(0), bot::JsonInt(2)});
	TH_CHECK(outOfRange.isBool() && !outOfRange.getBool());
	bot::Json missingChip = hal.call("pwm_npwm", {bot::JsonInt(7)});
	TH_CHECK(missingChip.isNull());
}
