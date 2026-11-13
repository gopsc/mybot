/* test_native_drivers.cpp —— C++ 原生驱动的直接单测（不经过 Lua/MatrixRunner） */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

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

termios readTermios(const std::string& path) {
	termios t{};
	const int fd = ::open(path.c_str(), O_RDWR | O_NOCTTY);
	if (fd < 0) { throw std::runtime_error("cannot open pty slave " + path); }
	if (::tcgetattr(fd, &t) != 0) {
		::close(fd);
		throw std::runtime_error("cannot read termios from " + path);
	}
	::close(fd);
	return t;
}

bool sameTermios(const termios& a, const termios& b) {
	return a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag
		&& a.c_cflag == b.c_cflag && a.c_lflag == b.c_lflag
		&& a.c_cc[VMIN] == b.c_cc[VMIN] && a.c_cc[VTIME] == b.c_cc[VTIME]
		&& cfgetispeed(&a) == cfgetispeed(&b)
		&& cfgetospeed(&a) == cfgetospeed(&b);
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

TH_TEST(native_uart_open_configures_high_baud_and_restores_termios) {
	/* pty 充当真实 tty：覆盖宿主 UART 的两次映射回归（此前 baudToSpeed 被
	 * 调用两次，9600 先查成 B9600=13，再当 Hz 查一次即 unsupported），
	 * 以及高波特率表与 close 时的 termios 恢复。 */
	const int master = ::posix_openpt(O_RDWR | O_NOCTTY);
	if (master < 0) { TH_SKIP("本机没有 pty 支持，无法验证真实 UART termios 路径"); }
	if (::grantpt(master) != 0 || ::unlockpt(master) != 0) {
		::close(master);
		TH_SKIP("本机无法创建 pty slave，无法验证真实 UART termios 路径");
	}
	const char* slaveName = ::ptsname(master);
	if (slaveName == nullptr) {
		::close(master);
		TH_SKIP("ptsname 未返回 slave 路径，无法验证真实 UART termios 路径");
	}
	const std::string slave(slaveName);
	const termios before = readTermios(slave);
	bot::HALManager hal;
#ifdef B1000000
	const int bauds[] = {9600, 1000000};
#else
	const int bauds[] = {9600};
#endif
	for (int baud : bauds) {
		bot::Json opened = hal.call("uart_open",
			{bot::JsonString(slave), bot::JsonInt(baud), bot::JsonBool(false)});
		TH_CHECK(opened.isInt() && opened.getInt() >= 0);
		if (!opened.isInt() || opened.getInt() < 0) {
			::close(master);
			return;
		}
		const termios during = readTermios(slave);
#ifdef B1000000
		TH_CHECK(cfgetispeed(&during) == (baud == 9600 ? B9600 : B1000000));
#else
		TH_CHECK(cfgetispeed(&during) == B9600);
#endif
		TH_CHECK((during.c_cflag & (CREAD | CLOCAL)) == (CREAD | CLOCAL));
		bot::Json closed = hal.call("close_handle", {opened});
		TH_CHECK(closed.isInt() && closed.getInt() == 0);
		TH_CHECK(sameTermios(before, readTermios(slave)));
	}
	::close(master);
}

TH_TEST(hal_concurrent_open_close_is_safe) {
	/* 守护线程与主线程会同时经 __hal_call 进入 HALManager；open/close 会
	 * 改句柄表，closeAll 会清表。8 线程各 2000 轮 open/close 验证句柄表
	 * 锁与 Resource 生命周期（此前的无锁 map 在压力下会段错误）。 */
	bot::HALManager hal;
	std::vector<std::thread> workers;
	for (int t = 0; t < 8; ++t) {
		workers.emplace_back([&hal] {
			for (int i = 0; i < 2000; ++i) {
				bot::Json opened = hal.call("i2c_open",
					{bot::JsonString("virt-probe"), bot::JsonBool(true)});
				if (!opened.isInt() || opened.getInt() < 0) { continue; }
				hal.call("close_handle", {opened});
			}
		});
	}
	for (auto& worker : workers) { worker.join(); }
	/* 全部句柄都已 close；再 open 一次确认管理器仍可用。 */
	bot::Json opened = hal.call("i2c_open",
		{bot::JsonString("virt-probe"), bot::JsonBool(true)});
	TH_CHECK(opened.isInt() && opened.getInt() >= 0);
	TH_CHECK(hal.call("close_handle", {opened}).isInt());
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
