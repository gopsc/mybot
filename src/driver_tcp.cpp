#include "native_driver.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <cmath>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

#include "hal.hpp"

namespace bot {
namespace {

constexpr int kMaxBytes = 512;
constexpr int kMaxTimeoutMs = 60000;

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

std::optional<int> integer(const Json* value, int low, int high) {
	if (value == nullptr) { return std::nullopt; }
	double number = 0;
	if (value->isInt()) { number = static_cast<double>(value->getInt()); }
	else if (value->isFloat()) { number = value->getFloat(); }
	else if (value->isStr()) {
		try { number = std::stod(value->getValue()); } catch (...) { return std::nullopt; }
	} else { return std::nullopt; }
	if (!std::isfinite(number) || std::floor(number) != number
			|| number < low || number > high) {
		return std::nullopt;
	}
	return static_cast<int>(number);
}

bool isFlagOne(const Json& value) {
	if (value.isBool()) { return value.getBool(); }
	if (value.isInt()) { return value.getInt() == 1; }
	if (value.isFloat()) { return value.getFloat() == 1.0; }
	return false;
}

bool isFlagZeroOrOne(const Json& value) {
	if (value.isBool()) { return true; }
	if (value.isInt()) { return value.getInt() == 0 || value.getInt() == 1; }
	if (value.isFloat()) { return value.getFloat() == 0.0 || value.getFloat() == 1.0; }
	return false;
}

std::string hexUpper(const std::string& raw) {
	static const char* digits = "0123456789ABCDEF";
	std::string out;
	out.reserve(raw.size() * 3);
	for (std::size_t i = 0; i < raw.size(); ++i) {
		if (i != 0) { out.push_back(' '); }
		const unsigned char byte = static_cast<unsigned char>(raw[i]);
		out.push_back(digits[byte >> 4]);
		out.push_back(digits[byte & 0x0F]);
	}
	return out;
}

bool parseHex(const std::string& text, std::string& out) {
	out.clear();
	int high = -1;
	for (char ch : text) {
		if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') { continue; }
		int value = 0;
		if (ch >= '0' && ch <= '9') { value = ch - '0'; }
		else if (ch >= 'a' && ch <= 'f') { value = ch - 'a' + 10; }
		else if (ch >= 'A' && ch <= 'F') { value = ch - 'A' + 10; }
		else { return false; }
		if (high < 0) { high = value; }
		else { out.push_back(static_cast<char>((high << 4) | value)); high = -1; }
	}
	return high < 0;
}

bool validUtf8Prefix(const std::string& input, std::string& output, std::string& pending,
		bool eof, std::string& message) {
	output.clear();
	std::size_t index = 0;
	while (index < input.size()) {
		const unsigned char first = static_cast<unsigned char>(input[index]);
		int length = 0;
		if (first < 0x80) { length = 1; }
		else if ((first & 0xE0) == 0xC0) { length = 2; }
		else if ((first & 0xF0) == 0xE0) { length = 3; }
		else if ((first & 0xF8) == 0xF0) { length = 4; }
		else {
			message = "Invalid UTF-8 received";
			return false;
		}
		if (index + static_cast<std::size_t>(length) > input.size()) {
			pending = input.substr(index);
			if (eof) {
				message = "Incomplete UTF-8 at EOF";
				return false;
			}
			return true;
		}
		for (int offset = 1; offset < length; ++offset) {
			const unsigned char next = static_cast<unsigned char>(input[index + offset]);
			if ((next & 0xC0) != 0x80) {
				message = "Invalid UTF-8 received";
				return false;
			}
		}
		if (length == 2 && first < 0xC2) {
			message = "Invalid UTF-8 received";
			return false;
		}
		if (length == 3) {
			const unsigned char second = static_cast<unsigned char>(input[index + 1]);
			if ((first == 0xE0 && second < 0xA0) || (first == 0xED && second >= 0xA0)) {
				message = "Invalid UTF-8 received";
				return false;
			}
		}
		if (length == 4) {
			const unsigned char second = static_cast<unsigned char>(input[index + 1]);
			if ((first == 0xF0 && second < 0x90) || first > 0xF4
					|| (first == 0xF4 && second >= 0x90)) {
				message = "Invalid UTF-8 received";
				return false;
			}
		}
		output.append(input, index, static_cast<std::size_t>(length));
		index += static_cast<std::size_t>(length);
	}
	pending.clear();
	if (eof && !pending.empty()) {
		message = "Incomplete UTF-8 at EOF";
		return false;
	}
	return true;
}

class TcpDriver final : public NativeDriver {
public:
	explicit TcpDriver(HALManager& hal) : hal_(hal) {}

	Json build(const Json& data) override {
		const Json* hostValue = data.find("host");
		if (hostValue == nullptr || !hostValue->isStr()) {
			return error("Invalid Arguments: host (IPv4/IPv6 literal without scope)");
		}
		const std::string host = hostValue->getValue();
		if (host.find('%') != std::string::npos) {
			return error("Invalid Arguments: host (IPv4/IPv6 literal without scope)");
		}
		in_addr v4{};
		in6_addr v6{};
		if (inet_pton(AF_INET, host.c_str(), &v4) != 1
				&& inet_pton(AF_INET6, host.c_str(), &v6) != 1) {
			return error("Invalid Arguments: host (IPv4/IPv6 literal without scope)");
		}
		auto port = integer(data.find("port"), 1, 65535);
		if (!port) { return error("Invalid Arguments: port (integer 1..65535)"); }
		auto timeout = integer(data.find("timeout"), 1, kMaxTimeoutMs);
		if (data.find("timeout") != nullptr && !timeout) {
			return error("Invalid Arguments: timeout (integer 1..60000 ms)");
		}
		auto numRecv = integer(data.find("num_recv"), 1, kMaxBytes);
		if (data.find("num_recv") != nullptr && !numRecv) {
			return error("Invalid Arguments: num_recv (integer 1..512)");
		}
		Json closed = closeConnection();
		if (!closed.isNull()) { return closed; }
		host_ = host;
		port_ = *port;
		timeoutMs_ = timeout ? *timeout : 1000;
		numRecv_ = numRecv ? *numRecv : 512;
		utf8Pending_.clear();
		return metadata();
	}

	Json call(const Json& data) override {
		int timeout = timeoutMs_;
		int numRecv = numRecv_;
		std::string operation;
		std::string payload;
		for (const auto& entry : data.items()) {
			const std::string& key = entry.first;
			if (key == "name" || key == "host" || key == "port" || key == "mode"
					|| key == "fd" || key == "connected" || key == "result"
					|| key == "message" || key == "status" || key == "received"
					|| key == "sent") {
				continue;
			}
			if (key == "timeout") {
				auto value = integer(&entry.second, 1, kMaxTimeoutMs);
				if (!value) { return error("Invalid Arguments: timeout (integer 1..60000 ms)"); }
				timeout = *value;
			} else if (key == "num_recv") {
				auto value = integer(&entry.second, 1, kMaxBytes);
				if (!value) { return error("Invalid Arguments: num_recv (integer 1..512)"); }
				numRecv = *value;
			} else if (key == "connect" || key == "close"
					|| key == "recv_hex" || key == "recv_str") {
				if (!isFlagZeroOrOne(entry.second)) {
					return error("Invalid Arguments: " + key + " (numeric flag 0 or 1)");
				}
				if (isFlagOne(entry.second)) {
					if (!operation.empty()) {
						return error("At most one TCP operation is allowed per call");
					}
					operation = key;
				}
			} else if (key == "send_hex" || key == "send_str") {
				if (!entry.second.isStr()) {
					return error("Invalid Arguments: " + key + " (string)");
				}
				if (!operation.empty()) {
					return error("At most one TCP operation is allowed per call");
				}
				const std::string text = entry.second.getValue();
				if (key == "send_hex") {
					if (!parseHex(text, payload)) {
						return error("Invalid Arguments: send_hex (ASCII hex byte pairs)");
					}
				} else {
					payload = text;
				}
				if (payload.size() > static_cast<std::size_t>(kMaxBytes)) {
					return error("Invalid Arguments: " + key + " (at most 512 bytes)");
				}
				operation = key;
			} else {
				return error("Unknown TCP action: " + key);
			}
		}
		if (operation == "connect" && host_.empty()) {
			return error("TCP endpoint not configured (build first)");
		}
		if ((operation == "send_hex" || operation == "send_str"
				|| operation == "recv_hex" || operation == "recv_str") && fd_ < 0) {
			return error("TCP not connected (connect first)");
		}
		timeoutMs_ = timeout;
		numRecv_ = numRecv;
		if (operation.empty()) { return metadata(); }
		if (operation == "close") {
			Json closed = closeConnection();
			return closed.isNull() ? metadata() : closed;
		}
		if (operation == "connect") {
			if (fd_ < 0) {
				Json opened = hal_.call("tcp_open",
					{JsonString(host_), JsonInt(port_), JsonInt(timeoutMs_)});
				if (!opened.isInt() || opened.getInt() < 0) {
					Json last = hal_.call("last_error", {});
					return error(last.isStr() ? last.getValue()
						: "Failed to connect TCP endpoint");
				}
				fd_ = static_cast<int>(opened.getInt());
			}
			return metadata();
		}
		if (operation == "send_hex" || operation == "send_str") {
			return send(payload);
		}
		return receive(operation);
	}

	Json read(const Json&) override { return metadata(); }

	Json destroy(const Json&) override {
		Json closed = closeConnection();
		return closed.isNull() ? ok() : closed;
	}

private:
	Json metadata() const {
		Json out = ok();
		out.put("fd", JsonInt(fd_));
		out.put("connected", JsonBool(fd_ >= 0));
		out.put("host", JsonString(host_));
		out.put("port", JsonInt(port_));
		out.put("timeout", JsonInt(timeoutMs_));
		out.put("num_recv", JsonInt(numRecv_));
		return out;
	}

	Json closeConnection() {
		utf8Pending_.clear();
		if (fd_ < 0) { return JsonNull(); }
		const int fd = fd_;
		fd_ = -1;
		Json result = hal_.call("close_handle", {JsonInt(fd)});
		if (result.isObj()) {
			const Json* status = result.find("result");
			if (status != nullptr && status->isStr() && status->getValue() == "ERR") {
				return result;
			}
		}
		if (result.isInt() && result.getInt() == -1) {
			Json last = hal_.call("last_error", {});
			return error(last.isStr() ? last.getValue() : "Failed to close TCP connection");
		}
		return JsonNull();
	}

	Json send(const std::string& payload) {
		Json bytes = JsonArray();
		for (unsigned char byte : payload) { bytes.add(JsonInt(byte)); }
		Json result = hal_.call("tcp_write",
			{JsonInt(fd_), bytes, JsonInt(timeoutMs_)});
		if (result.isObj()) {
			const Json* status = result.find("result");
			if (status != nullptr && status->isStr() && status->getValue() == "ERR") {
				closeConnection();
				return result;
			}
			const Json* sent = result.find("sent");
			if (status != nullptr && status->isStr() && status->getValue() == "OK"
					&& sent != nullptr && sent->isInt()
					&& sent->getInt() >= 0
					&& sent->getInt() <= static_cast<std::int64_t>(payload.size())) {
				Json out = ok();
				out.put("sent", JsonInt(sent->getInt()));
				return out;
			}
		}
		closeConnection();
		return error("Invalid TCP write response");
	}

	Json receive(const std::string& operation) {
		if (operation == "recv_hex" && !utf8Pending_.empty()) {
			const std::size_t take = std::min<std::size_t>(numRecv_, utf8Pending_.size());
			const std::string raw = utf8Pending_.substr(0, take);
			utf8Pending_.erase(0, take);
			Json out = ok();
			out.put("status", JsonString("data"));
			out.put("received", JsonInt(static_cast<std::int64_t>(raw.size())));
			out.put("recv_hex", JsonString(hexUpper(raw)));
			return out;
		}
		Json result = hal_.call("tcp_read",
			{JsonInt(fd_), JsonInt(numRecv_), JsonInt(timeoutMs_)});
		if (result.isObj()) {
			const Json* statusField = result.find("result");
			if (statusField != nullptr && statusField->isStr()
					&& statusField->getValue() == "ERR") {
				closeConnection();
				return result;
			}
		}
		if (!result.isObj()) {
			closeConnection();
			return error("Invalid TCP read response");
		}
		const Json* statusValue = result.find("status");
		const Json* dataValue = result.find("data");
		if (statusValue == nullptr || !statusValue->isStr()
				|| dataValue == nullptr || !dataValue->isArr()
				|| dataValue->size() > static_cast<std::size_t>(numRecv_)) {
			closeConnection();
			return error("Invalid TCP read response");
		}
		const std::string status = statusValue->getValue();
		if (status != "data" && status != "timeout" && status != "eof") {
			closeConnection();
			return error("Invalid TCP read response");
		}
		std::string raw;
		raw.reserve(dataValue->size());
		for (std::size_t index = 0; index < dataValue->size(); ++index) {
			const Json& byte = dataValue->at(index);
			if (!byte.isInt() || byte.getInt() < 0 || byte.getInt() > 255) {
				closeConnection();
				return error("Invalid TCP read response");
			}
			raw.push_back(static_cast<char>(byte.getInt()));
		}
		Json out = ok();
		out.put("status", JsonString(status));
		out.put("received", JsonInt(static_cast<std::int64_t>(raw.size())));
		if (operation == "recv_hex") {
			out.put("recv_hex", JsonString(hexUpper(raw)));
		} else {
			std::string decoded;
			std::string message;
			if (!validUtf8Prefix(utf8Pending_ + raw, decoded, utf8Pending_,
					status == "eof", message)) {
				closeConnection();
				return error(message);
			}
			out.put("recv_str", JsonString(decoded));
		}
		if (status == "eof") { closeConnection(); }
		return out;
	}

	HALManager& hal_;
	std::string host_;
	int port_ = 0;
	int fd_ = -1;
	int timeoutMs_ = 1000;
	int numRecv_ = 512;
	std::string utf8Pending_;
};

} // namespace

std::unique_ptr<NativeDriver> makeTcpDriver(HALManager& hal) {
	return std::make_unique<TcpDriver>(hal);
}

} // namespace bot
