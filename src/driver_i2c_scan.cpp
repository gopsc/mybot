#include "native_driver.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

#include "hal.hpp"

namespace bot {
namespace {

constexpr int kDefaultStart = 0x08;
constexpr int kDefaultEnd = 0x77;

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

int parseAddress(const Json* value, int fallback) {
	if (value == nullptr || value->isNull() || value->isBool()) { return fallback; }
	if (value->isInt()) { return static_cast<int>(value->getInt()); }
	if (value->isFloat()) {
		const double number = value->getFloat();
		if (std::isfinite(number) && std::floor(number) == number) {
			return static_cast<int>(number);
		}
		return fallback;
	}
	if (value->isStr()) {
		std::string text = value->getValue();
		const std::size_t begin = text.find_first_not_of(" \t\r\n");
		if (begin == std::string::npos) { return fallback; }
		const std::size_t end = text.find_last_not_of(" \t\r\n");
		text = text.substr(begin, end - begin + 1);
		if (text.empty() || text == "-") { return fallback; }
		try {
			std::size_t used = 0;
			const int number = std::stoi(text, &used, 0);
			return used == text.size() ? number : fallback;
		} catch (...) {
			return fallback;
		}
	}
	return fallback;
}

std::string hexByte(int value) {
	char buffer[8];
	std::snprintf(buffer, sizeof(buffer), "0x%02X", value);
	return buffer;
}

class I2cScanDriver final : public NativeDriver {
public:
	explicit I2cScanDriver(HALManager& hal) : hal_(hal) {}

	Json build(const Json& data) override {
		const Json* pathValue = data.find("path");
		if (pathValue == nullptr || !pathValue->isStr()) {
			return error("No I2C path");
		}
		close();
		const std::string path = pathValue->getValue();
		bool virtualBus = false;
		if (const Json* proto = data.find("proto"); proto != nullptr && proto->isStr()) {
			virtualBus = proto->getValue() == "virt";
		}
		Json opened = hal_.call("i2c_open",
			{JsonString(path), JsonBool(virtualBus)});
		if (!opened.isInt() || opened.getInt() < 0) {
			return error("Failed to open I2C bus");
		}
		fd_ = static_cast<int>(opened.getInt());
		bus_ = path;
		Json out = ok();
		out.put("fd", JsonInt(fd_));
		out.put("bus", JsonString(bus_));
		return out;
	}

	Json call(const Json& data) override {
		if (fd_ < 0) { return error("I2C bus not opened (build first)"); }
		int start = parseAddress(data.find("start_address"), kDefaultStart);
		int end = parseAddress(data.find("end_address"), kDefaultEnd);
		start = std::clamp(start, 0, 0x7F);
		end = std::clamp(end, 0, 0x7F);
		if (start > end) { std::swap(start, end); }
		Json found = JsonArray();
		for (int address = start; address <= end; ++address) {
			Json write = JsonArray();
			Json reply = hal_.call("i2c_transfer",
				{JsonInt(fd_), JsonInt(address), write, JsonInt(1)});
			if (!reply.isNull()) {
				found.add(JsonString(hexByte(address)));
			}
		}
		Json out = ok();
		out.put("bus", JsonString(bus_));
		out.put("found", found);
		out.put("count", JsonInt(static_cast<std::int64_t>(found.size())));
		out.put("range", JsonString(hexByte(start) + "-" + hexByte(end)));
		return out;
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
		bus_.clear();
	}

	HALManager& hal_;
	int fd_ = -1;
	std::string bus_;
};

} // namespace

std::unique_ptr<NativeDriver> makeI2cScanDriver(HALManager& hal) {
	return std::make_unique<I2cScanDriver>(hal);
}

} // namespace bot
