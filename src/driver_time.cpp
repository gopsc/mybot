#include "native_driver.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <optional>
#include <string>

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

std::optional<double> finiteNumber(const Json& value) {
	if (value.isInt()) { return static_cast<double>(value.getInt()); }
	if (value.isFloat()) { return value.getFloat(); }
	if (value.isStr()) {
		try { return std::stod(value.getValue()); } catch (...) { return std::nullopt; }
	}
	return std::nullopt;
}

std::optional<int> flag(const Json& value) {
	if (value.isNull()) { return 0; }
	if (value.isBool()) { return value.getBool() ? 1 : 0; }
	auto number = finiteNumber(value);
	if (!number || !std::isfinite(*number) || (*number != 0.0 && *number != 1.0)) {
		return std::nullopt;
	}
	return static_cast<int>(*number);
}


std::optional<std::string> checkFormat(const Json& value) {
	if (!value.isStr()) { return std::nullopt; }
	const std::string format = value.getValue();
	if (format.find('\0') != std::string::npos || format.size() > 256) { return std::nullopt; }
	static const std::string allowed = "%HIMSUWYdfjmwyz";
	for (std::size_t index = 0; index < format.size(); ++index) {
		if (format[index] != '%') { continue; }
		if (index + 1 >= format.size()
				|| allowed.find(format[index + 1]) == std::string::npos) {
			return std::nullopt;
		}
		++index;
	}
	return format;
}

std::string isoTime(const std::tm& value, int microsecond, const std::string& suffix) {
	char buffer[64];
	if (std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S", &value) == 0) {
		return std::string();
	}
	char micro[16];
	std::snprintf(micro, sizeof(micro), ".%06d", microsecond);
	return std::string(buffer) + micro + suffix;
}

std::string offsetText(long seconds) {
	const char sign = seconds < 0 ? '-' : '+';
	const long total = seconds < 0 ? -seconds : seconds;
	char buffer[32];
	std::snprintf(buffer, sizeof(buffer), "%c%02ld:%02ld", sign, total / 3600, (total % 3600) / 60);
	return buffer;
}

class TimeDriver final : public NativeDriver {
public:
	explicit TimeDriver(HALManager&) {}

	Json build(const Json&) override { return ok(); }

	Json call(const Json& data) override {
		const auto now = std::chrono::system_clock::now();
		const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
			now.time_since_epoch()).count();
		const std::time_t seconds = static_cast<std::time_t>(ns / 1000000000LL);
		const int microsecond = static_cast<int>((ns % 1000000000LL) / 1000);
		std::tm utc{};
		std::tm local{};
		if (::gmtime_r(&seconds, &utc) == nullptr || ::localtime_r(&seconds, &local) == nullptr) {
			return error("system time unavailable");
		}
		const std::string localOffset = offsetText(local.tm_gmtoff);
		Json result = JsonObject();
		result.put("result", JsonString("OK"));
		result.put("epoch", JsonInt(static_cast<std::int64_t>(seconds)));
		result.put("epoch_ms", JsonInt(static_cast<std::int64_t>(ns / 1000000LL)));
		result.put("utc", JsonString(isoTime(utc, microsecond, "Z")));
		result.put("local", JsonString(isoTime(local, microsecond, localOffset)));
		result.put("tz_offset", JsonString(localOffset));
		result.put("year", JsonInt(local.tm_year + 1900));
		result.put("month", JsonInt(local.tm_mon + 1));
		result.put("day", JsonInt(local.tm_mday));
		result.put("hour", JsonInt(local.tm_hour));
		result.put("minute", JsonInt(local.tm_min));
		result.put("second", JsonInt(local.tm_sec));
		result.put("microsecond", JsonInt(microsecond));
		result.put("weekday", JsonInt((local.tm_wday + 6) % 7 + 1));
		result.put("yday", JsonInt(local.tm_yday + 1));
		result.put("isdst", JsonInt(local.tm_isdst > 0 ? 1 : 0));

		const Json* utcValue = data.find("utc");
		const auto utcFlag = flag(utcValue == nullptr ? JsonNull() : *utcValue);
		if (!utcFlag) { return error("Invalid Arguments: utc (0|1)"); }
		const Json* formatValue = data.find("format");
		if (formatValue != nullptr && !formatValue->isNull()) {
			auto format = checkFormat(*formatValue);
			if (!format) {
				return error("Invalid Arguments: format (unsupported or over 256 bytes)");
			}
			const std::tm& target = *utcFlag == 1 ? utc : local;
			char buffer[4096];
			const std::size_t written = std::strftime(buffer, sizeof(buffer), format->c_str(), &target);
			if (written == 0 && !format->empty()) {
				return error("Invalid Arguments: format (strftime failed)");
			}
			result.put("formatted", JsonString(std::string(buffer, written)));
		}
		return result;
	}

	Json destroy(const Json&) override { return ok(); }
};

} // namespace

std::unique_ptr<NativeDriver> makeTimeDriver(HALManager& hal) {
	return std::make_unique<TimeDriver>(hal);
}

} // namespace bot
