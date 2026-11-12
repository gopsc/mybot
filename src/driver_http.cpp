#include "native_driver.hpp"

#include <cmath>
#include <cstdio>
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

std::string textValue(const Json& value) {
	if (value.isStr()) { return value.getValue(); }
	if (value.isBool()) { return value.getBool() ? "true" : "false"; }
	if (value.isInt()) { return std::to_string(value.getInt()); }
	if (value.isFloat()) {
		char buffer[64];
		std::snprintf(buffer, sizeof(buffer), "%.14g", value.getFloat());
		return buffer;
	}
	return std::string();
}

std::string trim(const std::string& text) {
	const std::size_t begin = text.find_first_not_of(" \t\r\n");
	if (begin == std::string::npos) { return std::string(); }
	const std::size_t end = text.find_last_not_of(" \t\r\n");
	return text.substr(begin, end - begin + 1);
}

bool parseHeaders(const Json& value, Json& out) {
	out = JsonObject();
	if (value.isObj()) {
		for (const auto& entry : value.items()) {
			out.put(entry.first, JsonString(textValue(entry.second)));
		}
		return true;
	}
	if (!value.isStr()) { return false; }
	const std::string spec = value.getValue();
	if (spec.empty() || spec == "-") { return true; }
	std::size_t start = 0;
	while (start <= spec.size()) {
		const std::size_t bar = spec.find('|', start);
		const std::string pair = spec.substr(start,
			bar == std::string::npos ? std::string::npos : bar - start);
		if (!pair.empty()) {
			const std::size_t equal = pair.find('=');
			if (equal == std::string::npos) { return false; }
			const std::string key = trim(pair.substr(0, equal));
			const std::string val = trim(pair.substr(equal + 1));
			if (key.empty()) { return false; }
			out.put(key, JsonString(val));
		}
		if (bar == std::string::npos) { break; }
		start = bar + 1;
	}
	return true;
}

bool hasHeader(const Json& headers, const std::string& name) {
	if (!headers.isObj()) { return false; }
	for (const auto& entry : headers.items()) {
		if (entry.first == name) { return true; }
	}
	return false;
}

class HttpDriver final : public NativeDriver {
public:
	explicit HttpDriver(HALManager& hal) : hal_(hal) {}

	Json build(const Json& data) override {
		const Json* baseValue = data.find("base");
		if (baseValue == nullptr || !baseValue->isStr()) {
			return error("Invalid Arguments: base (credential-free http(s):// URL)");
		}
		auto timeout = finiteNumber(data.find("timeout"));
		if (!timeout) { timeout = 10000; }
		if (*timeout < 1 || *timeout > 60000) {
			return error("Invalid Arguments: timeout (1..60000 ms)");
		}
		close();
		Json opened = hal_.call("http_open",
			{JsonString(baseValue->getValue()), JsonInt(static_cast<std::int64_t>(*timeout))});
		if (!opened.isInt() || opened.getInt() < 0) {
			Json last = hal_.call("last_error", {});
			return error("Failed to open HTTP endpoint: "
				+ (last.isStr() ? last.getValue() : std::string()));
		}
		fd_ = static_cast<int>(opened.getInt());
		base_ = baseValue->getValue();
		timeoutMs_ = static_cast<int>(*timeout);
		return ok();
	}

	Json call(const Json& data) override {
		if (fd_ < 0) { return error("HTTP endpoint not opened (build first)"); }
		const Json* methodValue = data.find("method");
		const Json* pathValue = data.find("path");
		if (methodValue == nullptr && pathValue == nullptr) {
			Json out = ok();
			out.put("fd", JsonInt(fd_));
			out.put("base", JsonString(base_));
			out.put("timeout", JsonInt(timeoutMs_));
			return out;
		}
		std::string method = "GET";
		if (methodValue != nullptr && !methodValue->isNull()
				&& !(methodValue->isBool() && !methodValue->getBool())) {
			if (!methodValue->isStr()) { return error("Invalid Arguments: method (text)"); }
			method = methodValue->getValue();
		}
		std::string path;
		if (pathValue != nullptr && !pathValue->isNull()
				&& !(pathValue->isBool() && !pathValue->getBool())) {
			if (!pathValue->isStr()) { return error("Invalid Arguments: path (text)"); }
			path = pathValue->getValue();
		}
		Json headers = JsonNull();
		if (const Json* headerValue = data.find("headers"); headerValue != nullptr) {
			if (!parseHeaders(*headerValue, headers)) {
				return error("Invalid Arguments: headers (table or k=v|k=v text)");
			}
		}
		Json body = JsonNull();
		if (const Json* jsonValue = data.find("json");
				jsonValue != nullptr && (jsonValue->isObj() || jsonValue->isArr())) {
			body = JsonString(jsonValue->toString());
			if (!headers.isObj()) { headers = JsonObject(); }
			if (!hasHeader(headers, "Content-Type")
					&& !hasHeader(headers, "content-type")) {
				headers.put("Content-Type", JsonString("application/json"));
			}
		} else if (const Json* bodyValue = data.find("body");
				bodyValue != nullptr && bodyValue->isStr()) {
			body = JsonString(bodyValue->getValue());
		}
		Json result = hal_.call("http_request",
			{JsonInt(fd_), JsonString(method), JsonString(path), headers, body});
		if (result.isObj()) {
			const Json* status = result.find("result");
			if (status != nullptr && status->isStr()
					&& (status->getValue() == "OK" || status->getValue() == "ERR")) {
				return result;
			}
		}
		return error("Failed to execute HTTP request");
	}

	Json destroy(const Json&) override {
		close();
		return ok();
	}

private:
	void close() {
		base_.clear();
		if (fd_ >= 0) {
			hal_.call("close_handle", {JsonInt(fd_)});
			fd_ = -1;
		}
	}

	HALManager& hal_;
	int fd_ = -1;
	std::string base_;
	int timeoutMs_ = 10000;
};

} // namespace

std::unique_ptr<NativeDriver> makeHttpDriver(HALManager& hal) {
	return std::make_unique<HttpDriver>(hal);
}

} // namespace bot
