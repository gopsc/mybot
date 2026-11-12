#include "hal.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <linux/spi/spidev.h>
#include <mutex>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <termios.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

#include <curl/curl.h>

#include "ftdi.hpp"
#include "util_env.hpp"

namespace bot {
namespace {

thread_local std::string g_lastError;
HALManager* g_current = nullptr;

constexpr int kMaxHandle = (1 << 30);

bool isVirtualPath(const std::string& path) {
	if (path.size() < 6 || path.compare(0, 5, "virt-") != 0) { return false; }
	unsigned char c = static_cast<unsigned char>(path[5]);
	return std::isalnum(c) != 0 || c == '_';
}

std::string urlHost(const std::string& base) {
	const std::size_t scheme = base.find("://");
	if (scheme == std::string::npos) { return std::string(); }
	std::string rest = base.substr(scheme + 3);
	const std::size_t slash = rest.find('/');
	if (slash != std::string::npos) { rest = rest.substr(0, slash); }
	if (!rest.empty() && rest.front() == '[') {
		const std::size_t end = rest.find(']');
		return end == std::string::npos ? std::string() : rest.substr(1, end - 1);
	}
	const std::size_t colon = rest.rfind(':');
	if (colon != std::string::npos) { rest = rest.substr(0, colon); }
	return rest;
}

std::string errText(int code) {
	return std::string(std::strerror(code));
}

int asInt(const Json& value, int low, int high, const char* what) {
	double number = 0;
	if (value.isInt()) {
		number = static_cast<double>(value.getInt());
	} else if (value.isFloat()) {
		number = value.getFloat();
	} else if (value.isStr()) {
		try {
			std::size_t used = 0;
			number = std::stod(value.getValue(), &used);
			if (used != value.getValue().size()) {
				throw std::runtime_error(std::string(what) + " must be an integer");
			}
		} catch (const std::exception&) {
			throw std::runtime_error(std::string(what) + " must be an integer");
		}
	} else {
		throw std::runtime_error(std::string(what) + " must be an integer");
	}
	if (!std::isfinite(number) || std::floor(number) != number
			|| number < low || number > high) {
		throw std::runtime_error(std::string(what) + " outside "
			+ std::to_string(low) + ".." + std::to_string(high));
	}
	return static_cast<int>(number);
}

std::string asStr(const Json& value, const char* what) {
	if (!value.isStr()) { throw std::runtime_error(std::string(what) + " must be text"); }
	return value.getValue();
}

/* 数值入口：接受 Int/Float/数字字符串，拒绝非有限值。GPIO 默认电平与
 * PWM 频率/占空比都需要它——asInt 只收整数，而这些参数可以是小数。 */
double asFiniteNumber(const Json& value, const char* what) {
	double number = 0;
	if (value.isInt()) {
		number = static_cast<double>(value.getInt());
	} else if (value.isFloat()) {
		number = value.getFloat();
	} else if (value.isStr()) {
		try {
			std::size_t used = 0;
			number = std::stod(value.getValue(), &used);
			if (used != value.getValue().size()) {
				throw std::runtime_error(std::string(what) + " must be a number");
			}
		} catch (const std::exception&) {
			throw std::runtime_error(std::string(what) + " must be a number");
		}
	} else {
		throw std::runtime_error(std::string(what) + " must be a number");
	}
	if (!std::isfinite(number)) {
		throw std::runtime_error(std::string(what) + " must be finite");
	}
	return number;
}

/* GPIO/PWM 的“非有限值回落安全侧”语义：默认电平/使能位等非关键参数
 * 解析失败时按 0 处理，与 Lua 侧 bus.finite_of / byte_of 的口径一致。 */
double numberOrZero(const Json& value) {
	try {
		return asFiniteNumber(value, "value");
	} catch (const std::exception&) {
		return 0;
	}
}

bool boolish(const Json& value) {
	if (value.isBool()) { return value.getBool(); }
	if (value.isInt()) { return value.getInt() != 0; }
	if (value.isFloat()) { return value.getFloat() != 0; }
	if (value.isStr()) {
		const std::string& text = value.getValue();
		return text == "1" || text == "true" || text == "on";
	}
	return false;
}

std::string pwmRoot() {
	auto env = getEnvVar("BOT4CJ_PWM_SYSFS_ROOT");
	std::string root = (env && !env->empty()) ? *env : "/sys/class/pwm";
	while (root.size() > 1 && root.back() == '/') { root.pop_back(); }
	return root;
}

std::string pwmChipPath(int chip, const char* attribute) {
	return pwmRoot() + "/pwmchip" + std::to_string(chip) + "/" + attribute;
}

std::string pwmAttrPath(int chip, int channel, const char* attribute) {
	return pwmRoot() + "/pwmchip" + std::to_string(chip)
		+ "/pwm" + std::to_string(channel) + "/" + attribute;
}

bool readSysfs(const std::string& path, std::string& out) {
	const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
	if (fd < 0) { return false; }
	char buffer[64];
	const ssize_t n = ::read(fd, buffer, sizeof buffer);
	const int saved = errno;
	::close(fd);
	if (n < 0) {
		errno = saved;
		return false;
	}
	out.assign(buffer, static_cast<std::size_t>(n));
	return true;
}

bool writeSysfs(const std::string& path, const std::string& value, std::string& error) {
	const int fd = ::open(path.c_str(), O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		error = "open " + path + ": " + errText(errno);
		return false;
	}
	const ssize_t n = ::write(fd, value.data(), value.size());
	const int saved = errno;
	::close(fd);
	if (n != static_cast<ssize_t>(value.size())) {
		error = "write " + path + ": " + errText(n < 0 ? saved : EIO);
		return false;
	}
	return true;
}

bool pwmExportedPath(int chip, int channel) {
	const std::string path = pwmAttrPath(chip, channel, "enable");
	return ::access(path.c_str(), F_OK) == 0;
}

std::vector<std::uint8_t> asBytes(const Json& value, std::size_t maximum,
		std::size_t minimum = 0) {
	if (!value.isArr()) {
		throw std::runtime_error("expected a byte table");
	}
	if (value.size() < minimum || value.size() > maximum) {
		throw std::runtime_error("expected " + std::to_string(minimum) + ".."
			+ std::to_string(maximum) + " bytes");
	}
	std::vector<std::uint8_t> out;
	out.reserve(value.size());
	for (std::size_t i = 0; i < value.size(); ++i) {
		out.push_back(static_cast<std::uint8_t>(asInt(value.at(i), 0, 255, "byte")));
	}
	return out;
}

Json bytesJson(const std::vector<std::uint8_t>& data) {
	Json out = JsonArray();
	for (std::uint8_t b : data) { out.add(JsonInt(b)); }
	return out;
}

Json errorObject(const std::string& message) {
	Json out = JsonObject();
	out.put("result", JsonString("ERR"));
	out.put("message", JsonString(message));
	return out;
}

Json errorObjectSent(const std::string& message, int sent) {
	Json out = errorObject(message);
	out.put("sent", JsonInt(sent));
	return out;
}

void checkStop() {
	if (stopRequested().load()) {
		throw std::runtime_error("stop requested");
	}
}

int pollFd(int fd, short events, int timeoutMs) {
	pollfd pfd{fd, events, 0};
	return ::poll(&pfd, 1, timeoutMs);
}

speed_t baudToSpeed(int baud) {
	switch (baud) {
	case 1200: return B1200;
	case 2400: return B2400;
	case 4800: return B4800;
	case 9600: return B9600;
	case 19200: return B19200;
	case 38400: return B38400;
	case 57600: return B57600;
	case 115200: return B115200;
	case 230400: return B230400;
#ifdef B460800
	case 460800: return B460800;
#endif
	default: throw std::runtime_error("unsupported UART baud");
	}
}

void configureSerial(int fd, int baud) {
	termios tio{};
	if (::tcgetattr(fd, &tio) != 0) {
		throw std::runtime_error("tcgetattr failed: " + errText(errno));
	}
	::cfmakeraw(&tio);
	const speed_t speed = baudToSpeed(baud);
	if (::cfsetispeed(&tio, speed) != 0 || ::cfsetospeed(&tio, speed) != 0) {
		throw std::runtime_error("cannot set UART baud: " + errText(errno));
	}
	tio.c_cflag |= CLOCAL | CREAD;
	tio.c_cflag &= ~(CSTOPB | PARENB | CRTSCTS);
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;
	if (::tcsetattr(fd, TCSANOW, &tio) != 0) {
		throw std::runtime_error("tcsetattr failed: " + errText(errno));
	}
	::tcflush(fd, TCIOFLUSH);
}

std::string trimHeader(const std::string& text) {
	const std::size_t begin = text.find_first_not_of(" \t\r\n");
	if (begin == std::string::npos) { return std::string(); }
	const std::size_t end = text.find_last_not_of(" \t\r\n");
	return text.substr(begin, end - begin + 1);
}

void appendLimited(std::string& target, const char* data, std::size_t size,
		std::size_t limit, bool& truncated) {
	const std::size_t room = limit > target.size() ? limit - target.size() : 0;
	if (size > room) { truncated = true; }
	target.append(data, std::min(size, room));
}

struct HttpCapture {
	std::string body;
	std::map<std::string, std::string> headers;
	bool tooLarge = false;
};

std::size_t httpWrite(char* data, std::size_t size, std::size_t count, void* user) {
	auto* capture = static_cast<HttpCapture*>(user);
	const std::size_t total = size * count;
	if (capture->body.size() + total > static_cast<std::size_t>(HALManager::kHttpMaxBytes)) {
		capture->tooLarge = true;
		return 0;
	}
	capture->body.append(data, total);
	return total;
}

std::size_t httpHeader(char* data, std::size_t size, std::size_t count, void* user) {
	auto* capture = static_cast<HttpCapture*>(user);
	const std::size_t total = size * count;
	const std::string line(data, total);
	const std::size_t colon = line.find(':');
	if (colon != std::string::npos && capture->headers.size() < HALManager::kHttpMaxHeaders) {
		std::string key = trimHeader(line.substr(0, colon));
		std::string value = trimHeader(line.substr(colon + 1));
		std::transform(key.begin(), key.end(), key.begin(),
			[](unsigned char c) { return static_cast<char>(std::tolower(c)); });
		if (!key.empty()) { capture->headers[key] = value; }
	}
	return total;
}

Json runShell(const std::string& command, int timeoutMs) {
	if (command.empty() || command.find('\0') != std::string::npos) {
		throw std::runtime_error("shell command must be nonempty text without NUL");
	}
	if (command.size() > static_cast<std::size_t>(HALManager::kShellMaxCmdBytes)) {
		throw std::runtime_error("shell command exceeds the size ceiling");
	}
	int outPipe[2] = {-1, -1};
	int errPipe[2] = {-1, -1};
	if (::pipe2(outPipe, O_CLOEXEC) != 0 || ::pipe2(errPipe, O_CLOEXEC) != 0) {
		const int code = errno;
		if (outPipe[0] >= 0) { ::close(outPipe[0]); }
		if (outPipe[1] >= 0) { ::close(outPipe[1]); }
		throw std::runtime_error("cannot create shell pipes: " + errText(code));
	}
	const pid_t pid = ::fork();
	if (pid < 0) {
		const int code = errno;
		::close(outPipe[0]); ::close(outPipe[1]);
		::close(errPipe[0]); ::close(errPipe[1]);
		throw std::runtime_error("cannot fork shell: " + errText(code));
	}
	if (pid == 0) {
		::setsid();
		::dup2(outPipe[1], STDOUT_FILENO);
		::dup2(errPipe[1], STDERR_FILENO);
		::dup2(::open("/dev/null", O_RDONLY), STDIN_FILENO);
		::close(outPipe[0]); ::close(outPipe[1]);
		::close(errPipe[0]); ::close(errPipe[1]);
		::execl("/bin/sh", "sh", "-c", command.c_str(), nullptr);
		::_exit(127);
	}
	::close(outPipe[1]);
	::close(errPipe[1]);
	::fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
	::fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

	std::string out;
	std::string err;
	bool truncated = false;
	bool timedOut = false;
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(timeoutMs);
	int status = 0;
	bool exited = false;
	while (true) {
		checkStop();
		char buffer[8192];
		pollfd fds[2] = {{outPipe[0], POLLIN, 0}, {errPipe[0], POLLIN, 0}};
		const int ready = ::poll(fds, 2, 10);
		if (ready > 0) {
			for (int i = 0; i < 2; ++i) {
				if ((fds[i].revents & (POLLIN | POLLHUP)) != 0) {
					const ssize_t n = ::read(fds[i].fd, buffer, sizeof(buffer));
					if (n > 0) {
						appendLimited(i == 0 ? out : err, buffer, static_cast<std::size_t>(n),
							HALManager::kShellMaxOutBytes, truncated);
					}
				}
			}
		}
		if (!exited) {
			const pid_t result = ::waitpid(pid, &status, WNOHANG);
			if (result == pid) {
				exited = true;
				::kill(-pid, SIGKILL);
			} else if (std::chrono::steady_clock::now() >= deadline) {
				timedOut = true;
				::kill(-pid, SIGKILL);
				::waitpid(pid, &status, 0);
				exited = true;
			}
		}
		if (exited) {
			// Drain whatever is still buffered, then stop.
			for (int i = 0; i < 2; ++i) {
				while (true) {
					const ssize_t n = ::read(fds[i].fd, buffer, sizeof(buffer));
					if (n <= 0) { break; }
					appendLimited(i == 0 ? out : err, buffer, static_cast<std::size_t>(n),
						HALManager::kShellMaxOutBytes, truncated);
				}
			}
			break;
		}
	}
	::close(outPipe[0]);
	::close(errPipe[0]);

	Json result = JsonObject();
	result.put("result", JsonString(timedOut ? "ERR" : "OK"));
	result.put("code", JsonInt(exited && WIFEXITED(status) ? WEXITSTATUS(status) : -1));
	result.put("truncated", JsonBool(truncated));
	result.put("out", JsonString(out));
	result.put("err", JsonString(err));
	if (timedOut) {
		result.put("message", JsonString("command timed out after "
			+ std::to_string(timeoutMs) + " ms"));
	}
	return result;
}

} // namespace

struct HALManager::Resource {
	std::string kind;
	std::string backend;	// linux / serial / loop / virtual / socket / http / shell
	std::string path;
	int fd = -1;
	int baud = 0;
	std::uint8_t mode = 0;
	std::uint8_t bits = 8;
	std::uint32_t speed = 1000000;
	std::string base;
	int timeoutMs = 10000;
	std::vector<std::uint8_t> ring;
	std::unique_ptr<FtdiBus> ftdi;
	bool closed = false;
};

HALManager::HALManager() {
	static std::once_flag once;
	std::call_once(once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
}

HALManager::~HALManager() {
	closeAll();
}

HALManager* HALManager::current() {
	return g_current;
}

void HALManager::setCurrent(HALManager* hal) {
	g_current = hal;
}

HALManager::Resource& HALManager::get(std::int64_t handle, const char* kind) {
	auto found = handles_.find(handle);
	if (found == handles_.end() || found->second->closed
			|| std::strcmp(found->second->kind.c_str(), kind) != 0) {
		throw std::runtime_error("invalid or closed hardware handle");
	}
	return *found->second;
}

std::int64_t HALManager::add(std::unique_ptr<Resource> resource, int owner) {
	const std::int64_t handle = nextHandle_++;
	resource->closed = false;
	handles_[handle] = std::move(resource);
	owners_[handle] = owner;
	return handle;
}

std::int64_t HALManager::addBus(const char* kind, const std::string& path, int fd,
		const std::string& backend, int owner, int baud) {
	auto resource = std::make_unique<Resource>();
	resource->kind = kind;
	resource->path = path;
	resource->fd = fd;
	resource->backend = backend;
	resource->baud = baud;
	return add(std::move(resource), owner);
}

void HALManager::closeResource(Resource& resource) {
	if (resource.fd >= 0) {
		::close(resource.fd);
		resource.fd = -1;
	}
	resource.ftdi.reset();
	resource.closed = true;
}

Json HALManager::call(const std::string& operation, const std::vector<Json>& args,
		int owner) {
	if (operation == "last_error") {
		return JsonString(g_lastError);
	}
	auto arg = [&](std::size_t index) -> const Json& {
		if (index >= args.size()) {
			throw std::runtime_error("missing argument " + std::to_string(index));
		}
		return args[index];
	};
	static const char* const known[] = {
		"i2c_open", "i2c_transfer", "spi_open", "spi_setup", "spi_transfer",
		"gpio_request_line", "gpio_set_value", "gpio_get_value", "gpio_free_line",
		"pwm_npwm", "pwm_exported", "pwm_export", "pwm_config",
		"pwm_set_polarity", "pwm_enable", "pwm_unexport",
		"uart_open", "uart_write", "uart_read", "uart_flush", "virt_attach",
		"tcp_open", "tcp_write", "tcp_read", "http_open", "http_request",
		"shell_open", "shell_run", "close_handle", "sleep_ms",
	};
	bool supported = false;
	for (const char* name : known) {
		if (operation == name) { supported = true; break; }
	}
	if (!supported) {
		return errorObject("Unsupported HAL operation: " + operation);
	}
	try {
		if (operation == "i2c_open") {
			return opI2cOpen(arg(0), args.size() > 1 ? arg(1) : JsonBool(false), owner);
		}
		if (operation == "i2c_transfer") {
			return opI2cTransfer(arg(0), arg(1), arg(2), arg(3));
		}
		if (operation == "spi_open") {
			return opSpiOpen(arg(0), args.size() > 1 ? arg(1) : JsonBool(false), owner);
		}
		if (operation == "spi_setup") {
			return opSpiSetup(arg(0), arg(1), arg(2), arg(3));
		}
		if (operation == "spi_transfer") {
			return opSpiTransfer(arg(0), arg(1), args.size() > 2 ? arg(2) : JsonInt(0));
		}
		if (operation == "gpio_request_line") {
			return opGpioRequestLine(arg(0), arg(1), arg(2),
				args.size() > 3 ? arg(3) : JsonInt(0),
				args.size() > 4 ? arg(4) : JsonBool(false), owner);
		}
		if (operation == "gpio_set_value") {
			return opGpioSetValue(arg(0), args.size() > 1 ? arg(1) : JsonInt(0));
		}
		if (operation == "gpio_get_value") { return opGpioGetValue(arg(0)); }
		if (operation == "gpio_free_line") { return opGpioFreeLine(arg(0)); }
		if (operation == "pwm_npwm") { return opPwmNpwm(arg(0)); }
		if (operation == "pwm_exported") { return opPwmExported(arg(0), arg(1)); }
		if (operation == "pwm_export") { return opPwmExport(arg(0), arg(1)); }
		if (operation == "pwm_config") {
			return opPwmConfig(arg(0), arg(1), arg(2), arg(3));
		}
		if (operation == "pwm_set_polarity") {
			return opPwmSetPolarity(arg(0), arg(1), arg(2));
		}
		if (operation == "pwm_enable") { return opPwmEnable(arg(0), arg(1), arg(2)); }
		if (operation == "pwm_unexport") { return opPwmUnexport(arg(0), arg(1)); }
		if (operation == "uart_open") {
			return opUartOpen(arg(0), arg(1),
				args.size() > 2 ? arg(2) : JsonBool(false), owner);
		}
		if (operation == "uart_write") { return opUartWrite(arg(0), arg(1)); }
		if (operation == "uart_read") {
			return opUartRead(arg(0), arg(1), args.size() > 2 ? arg(2) : JsonInt(0));
		}
		if (operation == "uart_flush") { return opUartFlush(arg(0)); }
		if (operation == "virt_attach") {
			// Lua virtbus handles virtual buses itself; a native virtual
			// handle simply accepts the attach as a no-op.
			return JsonInt(0);
		}
		if (operation == "tcp_open") {
			return opTcpOpen(arg(0), arg(1), args.size() > 2 ? arg(2) : JsonInt(1000), owner);
		}
		if (operation == "tcp_write") {
			return opTcpWrite(arg(0), arg(1), args.size() > 2 ? arg(2) : JsonInt(1000));
		}
		if (operation == "tcp_read") {
			return opTcpRead(arg(0), arg(1), args.size() > 2 ? arg(2) : JsonInt(1000));
		}
		if (operation == "http_open") {
			return opHttpOpen(arg(0), args.size() > 1 ? arg(1) : JsonInt(10000), owner);
		}
		if (operation == "http_request") {
			return opHttpRequest(arg(0), arg(1), arg(2),
				args.size() > 3 ? arg(3) : JsonNull(),
				args.size() > 4 ? arg(4) : JsonNull());
		}
		if (operation == "shell_open") {
			return opShellOpen(args.size() > 0 ? arg(0) : JsonInt(10000), owner);
		}
		if (operation == "shell_run") {
			return opShellRun(arg(0), arg(1),
				args.size() > 2 ? arg(2) : JsonNull());
		}
		if (operation == "close_handle") { return opCloseHandle(arg(0)); }
		if (operation == "sleep_ms") { return opSleepMs(arg(0)); }
	} catch (const std::exception& exc) {
		const std::string message = operation + ": " + exc.what();
		g_lastError = message;
		if (operation == "tcp_write") { return errorObjectSent(message, 0); }
		if (operation == "tcp_read" || operation == "http_request"
				|| operation == "shell_run") {
			return errorObject(message);
		}
		if (operation == "i2c_transfer" || operation == "spi_transfer"
				|| operation == "uart_read" || operation == "pwm_npwm") {
			return JsonNull();
		}
		if (operation == "gpio_set_value" || operation == "pwm_exported"
				|| operation == "pwm_export" || operation == "pwm_config"
				|| operation == "pwm_set_polarity" || operation == "pwm_enable"
				|| operation == "pwm_unexport") {
			return JsonBool(false);
		}
		return JsonInt(-1);
	}
	return errorObject("Unsupported HAL operation: " + operation);
}

Json HALManager::opI2cOpen(const Json& pathValue, const Json& virtualValue, int owner) {
	const std::string path = asStr(pathValue, "I2C path");
	const bool virtualBus = (virtualValue.isBool() && virtualValue.getBool())
		|| isVirtualPath(path);
	if (virtualBus) {
		return JsonInt(addBus("i2c", path, -1, "virtual", owner));
	}
	if (path.rfind("ftdi://", 0) == 0) {
		auto resource = std::make_unique<Resource>();
		resource->kind = "i2c";
		resource->backend = "ftdi";
		resource->path = path;
		resource->ftdi = std::make_unique<FtdiBus>(path, false);
		return JsonInt(add(std::move(resource), owner));
	}
	if (path.rfind("/dev/i2c-", 0) != 0) {
		throw std::runtime_error("I2C requires /dev/i2c-N, an ftdi:// URL, or a virt-* path");
	}
	const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0) { throw std::runtime_error("cannot open " + path + ": " + errText(errno)); }
	return JsonInt(addBus("i2c", path, fd, "linux", owner));
}

Json HALManager::opI2cTransfer(const Json& handleValue, const Json& addressValue,
		const Json& writeValue, const Json& readCountValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const int address = asInt(addressValue, 0, 127, "I2C address");
	const std::vector<std::uint8_t> write = asBytes(writeValue, 258);
	const int readCount = asInt(readCountValue, 0, 16, "I2C read count");
	if (write.empty() && readCount == 0) {
		throw std::runtime_error("empty I2C transaction");
	}
	Resource& resource = get(handle, "i2c");
	if (resource.backend == "virtual") {
		std::vector<std::uint8_t> zeros(static_cast<std::size_t>(readCount), 0);
		return bytesJson(zeros);
	}
	if (resource.backend == "ftdi") {
		std::vector<std::uint8_t> out;
		resource.ftdi->i2cTransfer(address, write, readCount, out);
		return bytesJson(out);
	}
	std::vector<i2c_msg> messages;
	std::vector<std::uint8_t> writeBuffer = write;
	std::vector<std::uint8_t> readBuffer(static_cast<std::size_t>(readCount), 0);
	if (!writeBuffer.empty()) {
		i2c_msg msg{};
		msg.addr = static_cast<std::uint16_t>(address);
		msg.flags = 0;
		msg.len = static_cast<std::uint16_t>(writeBuffer.size());
		msg.buf = writeBuffer.data();
		messages.push_back(msg);
	}
	if (readCount > 0) {
		i2c_msg msg{};
		msg.addr = static_cast<std::uint16_t>(address);
		msg.flags = I2C_M_RD;
		msg.len = static_cast<std::uint16_t>(readCount);
		msg.buf = readBuffer.data();
		messages.push_back(msg);
	}
	i2c_rdwr_ioctl_data data{};
	data.msgs = messages.data();
	data.nmsgs = static_cast<std::uint32_t>(messages.size());
	if (::ioctl(resource.fd, I2C_RDWR, &data) < 0) {
		throw std::runtime_error("I2C transfer failed: " + errText(errno));
	}
	return bytesJson(readBuffer);
}

Json HALManager::opSpiOpen(const Json& pathValue, const Json& virtualValue, int owner) {
	const std::string path = asStr(pathValue, "SPI path");
	const bool virtualBus = (virtualValue.isBool() && virtualValue.getBool())
		|| isVirtualPath(path);
	if (virtualBus) {
		return JsonInt(addBus("spi", path, -1, "virtual", owner));
	}
	if (path.rfind("ftdi://", 0) == 0) {
		auto resource = std::make_unique<Resource>();
		resource->kind = "spi";
		resource->backend = "ftdi";
		resource->path = path;
		resource->ftdi = std::make_unique<FtdiBus>(path, true);
		return JsonInt(add(std::move(resource), owner));
	}
	if (path.rfind("/dev/spidev", 0) != 0) {
		throw std::runtime_error("SPI requires /dev/spidevX.Y, an ftdi:// URL, or a virt-* path");
	}
	const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0) { throw std::runtime_error("cannot open " + path + ": " + errText(errno)); }
	return JsonInt(addBus("spi", path, fd, "linux", owner));
}

Json HALManager::opSpiSetup(const Json& handleValue, const Json& modeValue,
		const Json& bitsValue, const Json& speedValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const int mode = asInt(modeValue, 0, 3, "SPI mode");
	const int bits = asInt(bitsValue, 7, 16, "SPI bits");
	const int speed = asInt(speedValue, 1, 0x7FFFFFFF, "SPI speed");
	Resource& resource = get(handle, "spi");
	if (resource.backend == "virtual") {
		resource.mode = static_cast<std::uint8_t>(mode);
		resource.bits = static_cast<std::uint8_t>(bits);
		resource.speed = static_cast<std::uint32_t>(speed);
		return JsonInt(0);
	}
	if (resource.backend == "ftdi") {
		resource.ftdi->spiSetup(mode, bits, speed);
		resource.mode = static_cast<std::uint8_t>(mode);
		resource.bits = static_cast<std::uint8_t>(bits);
		resource.speed = static_cast<std::uint32_t>(speed);
		return JsonInt(0);
	}
	std::uint8_t modeByte = static_cast<std::uint8_t>(mode);
	std::uint8_t bitsByte = static_cast<std::uint8_t>(bits);
	std::uint32_t speedWord = static_cast<std::uint32_t>(speed);
	if (::ioctl(resource.fd, SPI_IOC_WR_MODE, &modeByte) < 0
			|| ::ioctl(resource.fd, SPI_IOC_WR_BITS_PER_WORD, &bitsByte) < 0
			|| ::ioctl(resource.fd, SPI_IOC_WR_MAX_SPEED_HZ, &speedWord) < 0) {
		throw std::runtime_error("SPI setup failed: " + errText(errno));
	}
	resource.mode = modeByte;
	resource.bits = bitsByte;
	resource.speed = speedWord;
	return JsonInt(0);
}

Json HALManager::opSpiTransfer(const Json& handleValue, const Json& dataValue,
		const Json& delayValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const std::vector<std::uint8_t> data = asBytes(dataValue, 64, 1);
	const int delay = asInt(delayValue, 0, 65535, "SPI delay");
	Resource& resource = get(handle, "spi");
	if (resource.backend == "virtual") {
		return bytesJson(std::vector<std::uint8_t>(data.size(), 0));
	}
	if (resource.backend == "ftdi") {
		std::vector<std::uint8_t> rx;
		resource.ftdi->spiTransfer(data, rx, delay);
		return bytesJson(rx);
	}
	std::vector<std::uint8_t> rx(data.size(), 0);
	spi_ioc_transfer transfer{};
	transfer.tx_buf = reinterpret_cast<unsigned long>(data.data());
	transfer.rx_buf = reinterpret_cast<unsigned long>(rx.data());
	transfer.len = static_cast<std::uint32_t>(data.size());
	transfer.delay_usecs = static_cast<std::uint16_t>(delay);
	transfer.speed_hz = resource.speed;
	transfer.bits_per_word = resource.bits;
	if (::ioctl(resource.fd, SPI_IOC_MESSAGE(1), &transfer) < 0) {
		throw std::runtime_error("SPI transfer failed: " + errText(errno));
	}
	return bytesJson(rx);
}

/* ---------------- GPIO（gpiod uAPI v1） ---------------- */

Json HALManager::opGpioRequestLine(const Json& chipValue, const Json& offsetValue,
		const Json& directionValue, const Json& defaultValue,
		const Json& activeLowValue, int owner) {
	const std::string chip = asStr(chipValue, "GPIO chip path");
	const std::string prefix = "/dev/gpiochip";
	if (chip.size() <= prefix.size() || chip.compare(0, prefix.size(), prefix) != 0) {
		throw std::runtime_error("GPIO requires /dev/gpiochipN, got '" + chip + "'");
	}
	for (std::size_t i = prefix.size(); i < chip.size(); ++i) {
		if (!std::isdigit(static_cast<unsigned char>(chip[i]))) {
			throw std::runtime_error("GPIO requires /dev/gpiochipN, got '" + chip + "'");
		}
	}
	const int offset = asInt(offsetValue, 0, 0x7FFFFFFF, "GPIO offset");
	const std::string direction = asStr(directionValue, "GPIO direction");
	if (direction != "in" && direction != "out") {
		throw std::runtime_error("GPIO direction must be 'in' or 'out'");
	}
	const int chipFd = ::open(chip.c_str(), O_RDWR | O_CLOEXEC);
	if (chipFd < 0) {
		throw std::runtime_error("cannot open " + chip + ": " + errText(errno));
	}
	struct gpiohandle_request request{};
	request.lineoffsets[0] = static_cast<std::uint32_t>(offset);
	request.flags = (direction == "out")
		? GPIOHANDLE_REQUEST_OUTPUT : GPIOHANDLE_REQUEST_INPUT;
	if (boolish(activeLowValue)) { request.flags |= GPIOHANDLE_REQUEST_ACTIVE_LOW; }
	if (direction == "out") {
		request.default_values[0] = numberOrZero(defaultValue) != 0 ? 1 : 0;
	}
	std::strncpy(request.consumer_label, "bot4cj", sizeof(request.consumer_label) - 1);
	request.lines = 1;
	if (::ioctl(chipFd, GPIO_GET_LINEHANDLE_IOCTL, &request) < 0 || request.fd < 0) {
		const int saved = errno;
		::close(chipFd);
		g_lastError = "GPIO request line " + std::to_string(offset)
			+ " on " + chip + " failed: " + errText(saved);
		return JsonInt(-1);
	}
	::close(chipFd);
	auto resource = std::make_unique<Resource>();
	resource->kind = "gpio";
	resource->backend = "gpiod";
	resource->path = chip;
	resource->fd = request.fd;
	return JsonInt(add(std::move(resource), owner));
}

Json HALManager::opGpioSetValue(const Json& handleValue, const Json& valueValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	Resource& resource = get(handle, "gpio");
	struct gpiohandle_data data{};
	data.values[0] = numberOrZero(valueValue) != 0 ? 1 : 0;
	if (::ioctl(resource.fd, GPIOHANDLE_SET_LINE_VALUES_IOCTL, &data) < 0) {
		g_lastError = "GPIO set value failed: " + errText(errno);
		return JsonBool(false);
	}
	return JsonBool(true);
}

Json HALManager::opGpioGetValue(const Json& handleValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	Resource& resource = get(handle, "gpio");
	struct gpiohandle_data data{};
	if (::ioctl(resource.fd, GPIOHANDLE_GET_LINE_VALUES_IOCTL, &data) < 0) {
		g_lastError = "GPIO get value failed: " + errText(errno);
		return JsonInt(-1);
	}
	return JsonInt(data.values[0]);
}

Json HALManager::opGpioFreeLine(const Json& handleValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	(void)get(handle, "gpio");
	return opCloseHandle(handleValue);
}

/* ---------------- PWM（Linux sysfs） ---------------- */

Json HALManager::opPwmNpwm(const Json& chipValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	std::string text;
	if (!readSysfs(pwmChipPath(chip, "npwm"), text)) {
		g_lastError = "PWM npwm read failed: " + errText(errno);
		return JsonNull();
	}
	try {
		const long value = std::stol(text);
		if (value < 0) { return JsonNull(); }
		return JsonInt(value);
	} catch (const std::exception&) {
		g_lastError = "PWM npwm is not an integer";
		return JsonNull();
	}
}

Json HALManager::opPwmExported(const Json& chipValue, const Json& channelValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	return JsonBool(pwmExportedPath(chip, channel));
}

Json HALManager::opPwmExport(const Json& chipValue, const Json& channelValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	if (pwmExportedPath(chip, channel)) { return JsonBool(true); }
	std::string npwmText;
	if (readSysfs(pwmChipPath(chip, "npwm"), npwmText)) {
		try {
			const long npwm = std::stol(npwmText);
			if (npwm >= 0 && channel >= npwm) {
				g_lastError = "PWM channel " + std::to_string(channel)
					+ " out of range on pwmchip" + std::to_string(chip)
					+ " (npwm=" + std::to_string(npwm) + ")";
				return JsonBool(false);
			}
		} catch (const std::exception&) {
			/* npwm 不可解析时不阻断 export：内核会给出最终判定。 */
		}
	}
	std::string error;
	if (!writeSysfs(pwmChipPath(chip, "export"), std::to_string(channel), error)) {
		g_lastError = "PWM export failed: " + error;
		return JsonBool(false);
	}
	if (!pwmExportedPath(chip, channel)) {
		g_lastError = "PWM export did not take effect: pwmchip" + std::to_string(chip)
			+ " pwm" + std::to_string(channel);
		return JsonBool(false);
	}
	return JsonBool(true);
}

Json HALManager::opPwmConfig(const Json& chipValue, const Json& channelValue,
		const Json& frequencyValue, const Json& dutyValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	const double frequency = asFiniteNumber(frequencyValue, "PWM frequency");
	const double duty = asFiniteNumber(dutyValue, "PWM duty");
	if (frequency <= 0) {
		throw std::runtime_error("PWM frequency must be > 0");
	}
	if (duty < 0 || duty > 100) {
		throw std::runtime_error("PWM duty must be 0..100");
	}
	const double period = 1e9 / frequency;
	if (!std::isfinite(period) || period > 9.0e18) {
		throw std::runtime_error("PWM frequency is too small (period overflow)");
	}
	const std::int64_t periodNs = std::max<std::int64_t>(
		1, static_cast<std::int64_t>(std::llround(period)));
	const std::int64_t dutyNs = std::min<std::int64_t>(periodNs,
		static_cast<std::int64_t>(std::llround(periodNs * duty / 100.0)));

	std::string error;
	/* 写序与 Lua HAL 一致：先 duty=0 再改 period，否则降频会被 EINVAL 拒绝。 */
	if (!writeSysfs(pwmAttrPath(chip, channel, "duty_cycle"), "0", error)
			|| !writeSysfs(pwmAttrPath(chip, channel, "period"),
				std::to_string(periodNs), error)
			|| !writeSysfs(pwmAttrPath(chip, channel, "duty_cycle"),
				std::to_string(dutyNs), error)) {
		g_lastError = "PWM config failed: " + error;
		return JsonBool(false);
	}
	Json result = JsonArray();
	result.add(JsonBool(true));
	result.add(JsonInt(periodNs));
	result.add(JsonInt(dutyNs));
	return result;
}

Json HALManager::opPwmSetPolarity(const Json& chipValue, const Json& channelValue,
		const Json& inversedValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	std::string error;
	if (!writeSysfs(pwmAttrPath(chip, channel, "polarity"),
			boolish(inversedValue) ? "inversed" : "normal", error)) {
		g_lastError = "PWM polarity failed: " + error;
		return JsonBool(false);
	}
	return JsonBool(true);
}

Json HALManager::opPwmEnable(const Json& chipValue, const Json& channelValue,
		const Json& onValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	std::string error;
	if (!writeSysfs(pwmAttrPath(chip, channel, "enable"),
			boolish(onValue) ? "1" : "0", error)) {
		g_lastError = "PWM enable failed: " + error;
		return JsonBool(false);
	}
	return JsonBool(true);
}

Json HALManager::opPwmUnexport(const Json& chipValue, const Json& channelValue) {
	const int chip = asInt(chipValue, 0, kPwmMaxId, "PWM chip");
	const int channel = asInt(channelValue, 0, kPwmMaxId, "PWM channel");
	/* 先停输出再取消导出；disable 失败不阻断 unexport（可能本就未导出）。 */
	(void)opPwmEnable(chipValue, channelValue, JsonBool(false));
	std::string error;
	if (!writeSysfs(pwmChipPath(chip, "unexport"), std::to_string(channel), error)) {
		g_lastError = "PWM unexport failed: " + error;
		return JsonBool(false);
	}
	return JsonBool(true);
}

Json HALManager::opUartOpen(const Json& pathValue, const Json& baudValue,
		const Json& virtualValue, int owner) {
	const std::string path = asStr(pathValue, "UART path");
	const int baud = asInt(baudValue, 1, 1000000, "UART baud");
	const bool virtualBus = (virtualValue.isBool() && virtualValue.getBool())
		|| isVirtualPath(path) || path == "loop://";
	if (virtualBus) {
		return JsonInt(addBus("uart", path, -1, "loop", owner, baud));
	}
	if (path.rfind("/dev/", 0) != 0) {
		throw std::runtime_error("UART requires a /dev path, loop://, or a virt-* path");
	}
	const int fd = ::open(path.c_str(), O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (fd < 0) { throw std::runtime_error("cannot open " + path + ": " + errText(errno)); }
	try {
		configureSerial(fd, baudToSpeed(baud));
	} catch (...) {
		::close(fd);
		throw;
	}
	return JsonInt(addBus("uart", path, fd, "serial", owner, baud));
}

Json HALManager::opUartWrite(const Json& handleValue, const Json& dataValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const std::vector<std::uint8_t> data = asBytes(dataValue, kUartMaxBytes, 1);
	Resource& resource = get(handle, "uart");
	if (resource.backend == "loop" || resource.backend == "virtual") {
		resource.ring.insert(resource.ring.end(), data.begin(), data.end());
		return JsonInt(static_cast<int>(data.size()));
	}
	std::size_t sent = 0;
	while (sent < data.size()) {
		checkStop();
		const ssize_t n = ::write(resource.fd, data.data() + sent, data.size() - sent);
		if (n < 0) {
			if (errno == EINTR) { continue; }
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				if (pollFd(resource.fd, POLLOUT, 1000) < 0) {
					throw std::runtime_error("UART write poll failed: " + errText(errno));
				}
				continue;
			}
			throw std::runtime_error("UART write failed: " + errText(errno));
		}
		sent += static_cast<std::size_t>(n);
	}
	return JsonInt(static_cast<int>(sent));
}

Json HALManager::opUartRead(const Json& handleValue, const Json& countValue,
		const Json& timeoutValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const int count = std::min(asInt(countValue, 1, kUartMaxBytes, "UART count"),
		kUartMaxBytes);
	const int timeoutMs = asInt(timeoutValue, 0, kUartMaxMs, "UART timeout");
	Resource& resource = get(handle, "uart");
	if (resource.backend == "loop" || resource.backend == "virtual") {
		const std::size_t take = std::min<std::size_t>(count, resource.ring.size());
		std::vector<std::uint8_t> out(resource.ring.begin(), resource.ring.begin() + take);
		resource.ring.erase(resource.ring.begin(), resource.ring.begin() + take);
		return bytesJson(out);
	}
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(timeoutMs);
	std::vector<std::uint8_t> out;
	out.reserve(static_cast<std::size_t>(count));
	while (static_cast<int>(out.size()) < count) {
		checkStop();
		const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
			deadline - std::chrono::steady_clock::now()).count();
		if (remaining <= 0) { break; }
		if (pollFd(resource.fd, POLLIN, static_cast<int>(std::min<long long>(remaining, 50))) <= 0) {
			continue;
		}
		std::uint8_t buffer[64];
		const std::size_t want = std::min<std::size_t>(
			sizeof(buffer), static_cast<std::size_t>(count) - out.size());
		const ssize_t n = ::read(resource.fd, buffer, want);
		if (n > 0) {
			out.insert(out.end(), buffer, buffer + n);
		} else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
			throw std::runtime_error("UART read failed: " + errText(errno));
		}
	}
	return bytesJson(out);
}

Json HALManager::opUartFlush(const Json& handleValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	Resource& resource = get(handle, "uart");
	if (resource.backend == "loop" || resource.backend == "virtual") {
		resource.ring.clear();
	} else {
		::tcflush(resource.fd, TCIFLUSH);
	}
	return JsonInt(0);
}

Json HALManager::opTcpOpen(const Json& hostValue, const Json& portValue,
		const Json& timeoutValue, int owner) {
	const std::string host = asStr(hostValue, "TCP host");
	const int port = asInt(portValue, 1, 65535, "TCP port");
	const int timeoutMs = asInt(timeoutValue, 1, kTcpMaxMs, "TCP timeout");
	addrinfo hints{};
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_flags = AI_NUMERICHOST;
	addrinfo* result = nullptr;
	const std::string portText = std::to_string(port);
	if (::getaddrinfo(host.c_str(), portText.c_str(), &hints, &result) != 0
			|| result == nullptr) {
		throw std::runtime_error("TCP host must be an IPv4 or IPv6 address");
	}
	int fd = -1;
	int lastError = 0;
	for (addrinfo* ai = result; ai != nullptr; ai = ai->ai_next) {
		fd = ::socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
		if (fd < 0) { lastError = errno; continue; }
		::fcntl(fd, F_SETFL, O_NONBLOCK);
		const int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (rc == 0) { break; }
		if (errno != EINPROGRESS) { lastError = errno; ::close(fd); fd = -1; continue; }
		const int ready = pollFd(fd, POLLOUT, timeoutMs);
		if (ready == 0) {
			lastError = ETIMEDOUT;
			::close(fd); fd = -1;
			continue;
		}
		int socketError = 0;
		socklen_t length = sizeof(socketError);
		if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) != 0
				|| socketError != 0) {
			lastError = socketError != 0 ? socketError : errno;
			::close(fd); fd = -1;
			continue;
		}
		break;
	}
	::freeaddrinfo(result);
	if (fd < 0) {
		throw std::runtime_error("TCP connection failed: " + errText(lastError));
	}
	return JsonInt(addBus("tcp", host + ":" + portText, fd, "socket", owner));
}

Json HALManager::opTcpWrite(const Json& handleValue, const Json& dataValue,
		const Json& timeoutValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const std::vector<std::uint8_t> data = asBytes(dataValue, kTcpMaxBytes);
	const int timeoutMs = asInt(timeoutValue, 1, kTcpMaxMs, "TCP timeout");
	Resource& resource = get(handle, "tcp");
	int sent = 0;
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(timeoutMs);
	try {
		while (sent < static_cast<int>(data.size())) {
			checkStop();
			const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
				deadline - std::chrono::steady_clock::now()).count();
			if (remaining <= 0) { throw std::runtime_error("TCP send timed out"); }
			if (pollFd(resource.fd, POLLOUT, static_cast<int>(std::min<long long>(remaining, 50))) <= 0) {
				continue;
			}
			const ssize_t n = ::send(resource.fd, data.data() + sent,
				data.size() - static_cast<std::size_t>(sent), MSG_NOSIGNAL);
			if (n < 0) {
				if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue; }
				throw std::runtime_error("TCP send failed: " + errText(errno));
			}
			if (n == 0) { throw std::runtime_error("TCP connection closed during send"); }
			sent += static_cast<int>(n);
		}
		Json result = JsonObject();
		result.put("result", JsonString("OK"));
		result.put("sent", JsonInt(sent));
		return result;
	} catch (const std::exception& exc) {
		closeResource(resource);
		Json result = errorObjectSent("tcp_write: " + std::string(exc.what())
			+ " (sent " + std::to_string(sent) + " bytes; peer execution is unknown)", sent);
		return result;
	}
}

Json HALManager::opTcpRead(const Json& handleValue, const Json& countValue,
		const Json& timeoutValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const int count = asInt(countValue, 1, kTcpMaxBytes, "TCP count");
	const int timeoutMs = asInt(timeoutValue, 1, kTcpMaxMs, "TCP timeout");
	Resource& resource = get(handle, "tcp");
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(timeoutMs);
	while (true) {
		checkStop();
		const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
			deadline - std::chrono::steady_clock::now()).count();
		if (remaining <= 0) {
			Json result = JsonObject();
			result.put("result", JsonString("OK"));
			result.put("status", JsonString("timeout"));
			result.put("data", JsonArray());
			return result;
		}
		if (pollFd(resource.fd, POLLIN, static_cast<int>(std::min<long long>(remaining, 50))) <= 0) {
			continue;
		}
		std::vector<std::uint8_t> buffer(static_cast<std::size_t>(count), 0);
		const ssize_t n = ::recv(resource.fd, buffer.data(), buffer.size(), 0);
		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue; }
			closeResource(resource);
			throw std::runtime_error("TCP receive failed: " + errText(errno));
		}
		buffer.resize(static_cast<std::size_t>(n));
		Json result = JsonObject();
		result.put("result", JsonString("OK"));
		if (n == 0) {
			closeResource(resource);
			result.put("status", JsonString("eof"));
		} else {
			result.put("status", JsonString("data"));
		}
		result.put("data", bytesJson(buffer));
		return result;
	}
}

Json HALManager::opHttpOpen(const Json& baseValue, const Json& timeoutValue, int owner) {
	const std::string base = asStr(baseValue, "HTTP base");
	const int timeoutMs = asInt(timeoutValue, 1, kHttpTimeoutMs, "HTTP timeout");
	if (base.rfind("http://", 0) != 0 && base.rfind("https://", 0) != 0) {
		throw std::runtime_error("HTTP base requires an http(s):// URL with a host");
	}
	const std::string host = urlHost(base);
	if (host.empty()) { throw std::runtime_error("HTTP base requires a host"); }
	auto resource = std::make_unique<Resource>();
	resource->kind = "http";
	resource->backend = "http";
	resource->base = base;
	resource->timeoutMs = timeoutMs;
	return JsonInt(add(std::move(resource), owner));
}

Json HALManager::opHttpRequest(const Json& handleValue, const Json& methodValue,
		const Json& pathValue, const Json& headersValue, const Json& bodyValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const std::string method = asStr(methodValue, "HTTP method");
	std::string path = asStr(pathValue, "HTTP path");
	if (method != "GET" && method != "POST" && method != "PUT"
			&& method != "DELETE" && method != "PATCH") {
		throw std::runtime_error("HTTP method must be GET, POST, PUT, DELETE, or PATCH");
	}
	if (path.find("://") != std::string::npos || path.rfind("//", 0) == 0) {
		throw std::runtime_error("HTTP path must be relative to the declared base URL");
	}
	if (!path.empty() && path.front() != '/') { path = "/" + path; }
	Resource& resource = get(handle, "http");
	CURL* curl = curl_easy_init();
	if (curl == nullptr) { throw std::runtime_error("cannot initialize libcurl"); }
	HttpCapture capture;
	curl_slist* headerList = nullptr;
	if (headersValue.isObj()) {
		if (headersValue.objSize() > static_cast<std::size_t>(kHttpMaxHeaders)) {
			curl_easy_cleanup(curl);
			throw std::runtime_error("HTTP headers exceed the entry ceiling");
		}
		for (const auto& entry : headersValue.items()) {
			const std::string header = entry.first + ": " + entry.second.getValue();
			headerList = curl_slist_append(headerList, header.c_str());
		}
	}
	std::string body;
	if (bodyValue.isStr()) { body = bodyValue.getValue(); }
	const std::string url = resource.base + path;
	curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
	curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
	curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
	curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(resource.timeoutMs));
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, httpWrite);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, &capture);
	curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, httpHeader);
	curl_easy_setopt(curl, CURLOPT_HEADERDATA, &capture);
	if (headerList != nullptr) { curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerList); }
	if (!body.empty()) {
		curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.data());
		curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
	}
	const CURLcode code = curl_easy_perform(curl);
	long status = 0;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
	if (headerList != nullptr) { curl_slist_free_all(headerList); }
	curl_easy_cleanup(curl);
	if (code != CURLE_OK) {
		throw std::runtime_error(std::string("HTTP request failed: ")
			+ curl_easy_strerror(code));
	}
	if (capture.tooLarge || capture.body.size() > static_cast<std::size_t>(kHttpMaxBytes)) {
		throw std::runtime_error("HTTP response exceeds the size ceiling");
	}
	Json result = JsonObject();
	result.put("result", JsonString("OK"));
	result.put("status", JsonInt(status));
	result.put("body", JsonString(capture.body));
	Json headers = JsonObject();
	for (const auto& entry : capture.headers) {
		headers.put(entry.first, JsonString(entry.second));
	}
	result.put("headers", headers);
	return result;
}

Json HALManager::opShellOpen(const Json& timeoutValue, int owner) {
	const int timeoutMs = asInt(timeoutValue, 1, kShellTimeoutMs, "shell timeout");
	auto resource = std::make_unique<Resource>();
	resource->kind = "shell";
	resource->backend = "shell";
	resource->timeoutMs = timeoutMs;
	return JsonInt(add(std::move(resource), owner));
}

Json HALManager::opShellRun(const Json& handleValue, const Json& commandValue,
		const Json& timeoutValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	const std::string command = asStr(commandValue, "shell command");
	const int timeoutMs = timeoutValue.isNull()
		? get(handle, "shell").timeoutMs
		: asInt(timeoutValue, 1, kShellTimeoutMs, "shell timeout");
	(void)handle;
	return runShell(command, timeoutMs);
}

Json HALManager::opCloseHandle(const Json& handleValue) {
	const std::int64_t handle = asInt(handleValue, 0, kMaxHandle, "handle");
	auto found = handles_.find(handle);
	if (found == handles_.end()) { return JsonInt(-1); }
	closeResource(*found->second);
	handles_.erase(found);
	owners_.erase(handle);
	return JsonInt(0);
}

Json HALManager::opSleepMs(const Json& msValue) {
	double ms = 0;
	if (msValue.isInt()) { ms = static_cast<double>(msValue.getInt()); }
	else if (msValue.isFloat()) { ms = msValue.getFloat(); }
	else if (msValue.isStr()) {
		try { ms = std::stod(msValue.getValue()); } catch (...) { ms = 0; }
	}
	if (!std::isfinite(ms) || ms <= 0) { return JsonInt(0); }
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(static_cast<long long>(std::min(ms, 4294967.0)));
	while (true) {
		checkStop();
		const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
			deadline - std::chrono::steady_clock::now()).count();
		if (remaining <= 0) { return JsonInt(0); }
		std::this_thread::sleep_for(std::chrono::milliseconds(
			std::min<long long>(remaining, 50)));
	}
}

void HALManager::closeAll() {
	for (auto& entry : handles_) { closeResource(*entry.second); }
	handles_.clear();
	owners_.clear();
}

} // namespace bot
