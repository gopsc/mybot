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

std::optional<int> integer(const Json* value) {
	if (value == nullptr) { return std::nullopt; }
	double number = 0;
	if (value->isInt()) { number = static_cast<double>(value->getInt()); }
	else if (value->isFloat()) { number = value->getFloat(); }
	else if (value->isStr()) {
		try { number = std::stod(value->getValue()); } catch (...) { return std::nullopt; }
	} else { return std::nullopt; }
	if (!std::isfinite(number) || std::floor(number) != number) { return std::nullopt; }
	return static_cast<int>(number);
}

class LoopbackProbeDriver final : public NativeDriver {
public:
	explicit LoopbackProbeDriver(HALManager& hal) : hal_(hal) {}

	Json build(const Json&) override { return ok(); }

	Json call(const Json& data) override {
		auto fd = integer(data.find("fd"));
		if (!fd) { return error("Invalid Arguments: fd"); }
		auto value = integer(data.find("value"));
		if (!value) { value = 0; }
		Json payload = JsonArray();
		payload.add(JsonInt(*value));
		std::vector<Json> writeArgs{JsonInt(*fd), payload};
		Json written = hal_.call("uart_write", writeArgs);
		if (!written.isInt() || written.getInt() != 1) {
			Json last = hal_.call("last_error", {});
			return error("UART write failed: " + (last.isStr() ? last.getValue() : std::string()));
		}
		std::vector<Json> readArgs{JsonInt(*fd), JsonInt(1), JsonInt(200)};
		Json reply = hal_.call("uart_read", readArgs);
		if (!reply.isArr() || reply.size() != 1) {
			return error("UART echo timed out or failed");
		}
		Json out = ok();
		out.put("rx", reply.at(0));
		return out;
	}

	Json destroy(const Json&) override { return ok(); }

private:
	HALManager& hal_;
};

} // namespace

std::unique_ptr<NativeDriver> makeLoopbackProbeDriver(HALManager& hal) {
	return std::make_unique<LoopbackProbeDriver>(hal);
}

} // namespace bot
