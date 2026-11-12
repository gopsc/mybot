#include "native_driver.hpp"

#include <cmath>
#include <optional>
#include <string>
#include <vector>

#include "hal.hpp"

namespace bot {
namespace {

Json error(const std::string& message) {
	Json out = JsonObject();
	out.put("result", JsonString("ERR"));
	out.put("message", JsonString(message));
	return out;
}

Json ok() {
	Json out = JsonObject();
	out.put("result", JsonString("OK"));
	return out;
}

std::optional<double> finiteNumber(const Json* value) {
	if (value == nullptr) { return std::nullopt; }
	if (value->isInt()) { return static_cast<double>(value->getInt()); }
	if (value->isFloat()) { return value->getFloat(); }
	if (value->isStr()) {
		try { return std::stod(value->getValue()); } catch (...) { return std::nullopt; }
	}
	return std::nullopt;
}

class ShellDriver final : public NativeDriver {
public:
	explicit ShellDriver(HALManager& hal) : hal_(hal) {}

	Json build(const Json& data) override {
		auto timeout = finiteNumber(data.find("timeout"));
		if (!timeout) { timeout = 10000; }
		if (*timeout < 1 || *timeout > 60000) {
			return error("Invalid Arguments: timeout (1..60000 ms)");
		}
		close();
		Json opened = hal_.call("shell_open", {JsonInt(static_cast<std::int64_t>(*timeout))});
		if (!opened.isInt() || opened.getInt() < 0) {
			Json last = hal_.call("last_error", {});
			return error("Failed to open shell session: "
				+ (last.isStr() ? last.getValue() : std::string()));
		}
		fd_ = static_cast<int>(opened.getInt());
		timeoutMs_ = static_cast<int>(*timeout);
		return ok();
	}

	Json call(const Json& data) override {
		if (fd_ < 0) { return error("Shell session not opened (build first)"); }
		const Json* commandValue = data.find("cmd");
		if (commandValue == nullptr || !commandValue->isStr()
				|| commandValue->getValue().empty() || commandValue->getValue() == "-") {
			return error("Invalid Arguments: cmd (command text)");
		}
		const std::string command = commandValue->getValue();
		if (command.size() > 65536) {
			return error("Invalid Arguments: cmd (over 65536 bytes)");
		}
		auto timeout = finiteNumber(data.find("timeout"));
		if (!timeout) { timeout = timeoutMs_; }
		if (*timeout < 1 || *timeout > 60000) {
			return error("Invalid Arguments: timeout (1..60000 ms)");
		}
		Json result = hal_.call("shell_run",
			{JsonInt(fd_), JsonString(command), JsonInt(static_cast<std::int64_t>(*timeout))});
		if (result.isObj()) {
			const Json* status = result.find("result");
			if (status != nullptr && status->isStr()
					&& (status->getValue() == "OK" || status->getValue() == "ERR")) {
				return result;
			}
		}
		return error("Failed to execute shell command");
	}

	Json destroy(const Json&) override {
		close();
		return ok();
	}

private:
	void close() {
		if (fd_ >= 0) {
			hal_.call("close_handle", {JsonInt(fd_)});
			fd_ = -1;
		}
	}

	HALManager& hal_;
	int fd_ = -1;
	int timeoutMs_ = 10000;
};

} // namespace

std::unique_ptr<NativeDriver> makeShellDriver(HALManager& hal) {
	return std::make_unique<ShellDriver>(hal);
}

} // namespace bot
