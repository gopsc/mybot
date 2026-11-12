#include "native_driver.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include <unistd.h>

namespace bot {
namespace {

namespace fs = std::filesystem;

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

std::vector<std::string> listDir(const std::string& path) {
	std::vector<std::string> names;
	std::error_code code;
	for (const auto& entry : fs::directory_iterator(path, code)) {
		names.push_back(entry.path().filename().string());
	}
	std::sort(names.begin(), names.end());
	return names;
}

std::optional<std::string> readText(const std::string& path) {
	std::ifstream stream(path);
	if (!stream) { return std::nullopt; }
	std::string text((std::istreambuf_iterator<char>(stream)),
		std::istreambuf_iterator<char>());
	while (!text.empty() && (text.back() == '\n' || text.back() == '\r'
			|| text.back() == ' ' || text.back() == '\t')) {
		text.pop_back();
	}
	return text;
}

bool startsWith(const std::string& text, const std::string& prefix) {
	return text.rfind(prefix, 0) == 0;
}

bool endsWith(const std::string& text, const std::string& suffix) {
	return text.size() >= suffix.size()
		&& text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool allDigits(const std::string& text) {
	return !text.empty() && std::all_of(text.begin(), text.end(),
		[](unsigned char c) { return std::isdigit(c) != 0; });
}

std::string driverLink(const std::string& path) {
	std::error_code code;
	if (!fs::is_symlink(path, code)) { return std::string(); }
	const fs::path target = fs::canonical(path, code);
	if (code) { return std::string(); }
	return target.filename().string();
}

Json i2cReport() {
	Json result = JsonObject();
	result.put("supported", JsonBool(true));
	Json adapters = JsonArray();
	Json clients = JsonArray();
	Json notes = JsonArray();
	std::vector<int> seen;

	for (const std::string& name : listDir("/dev")) {
		if (!startsWith(name, "i2c-") || !allDigits(name.substr(4))) { continue; }
		const int bus = std::stoi(name.substr(4));
		seen.push_back(bus);
		const std::string device = "/dev/" + name;
		Json record = JsonObject();
		record.put("device", JsonString(device));
		record.put("node_present", JsonBool(true));
		record.put("readable", JsonBool(::access(device.c_str(), R_OK) == 0));
		record.put("writable", JsonBool(::access(device.c_str(), W_OK) == 0));
		record.put("bus", JsonInt(bus));
		if (auto adapter = readText("/sys/class/i2c-dev/i2c-" + std::to_string(bus) + "/name")) {
			record.put("adapter_name", JsonString(*adapter));
		}
		adapters.add(record);
	}

	int hidden = 0;
	for (const std::string& name : listDir("/sys/class/i2c-dev")) {
		if (!startsWith(name, "i2c-") || !allDigits(name.substr(4))) { continue; }
		const int bus = std::stoi(name.substr(4));
		if (std::find(seen.begin(), seen.end(), bus) != seen.end()) { continue; }
		Json record = JsonObject();
		record.put("device", JsonString("/dev/i2c-" + std::to_string(bus)));
		record.put("bus", JsonInt(bus));
		record.put("node_present", JsonBool(false));
		record.put("source", JsonString("sysfs"));
		record.put("readable", JsonNull());
		record.put("writable", JsonNull());
		if (auto adapter = readText("/sys/class/i2c-dev/" + name + "/name")) {
			record.put("adapter_name", JsonString(*adapter));
		}
		adapters.add(record);
		++hidden;
	}
	if (hidden > 0) {
		result.put("node_visibility", JsonString("masked"));
		notes.add(JsonString(std::to_string(hidden)
			+ " adapter(s) in sysfs but /dev node not visible"));
	}
	if (adapters.size() == 0) {
		notes.add(JsonString("no /dev/i2c-* node: load i2c-dev or enable the bus in the device tree"));
	}

	for (const std::string& name : listDir("/sys/bus/i2c/devices")) {
		const std::size_t dash = name.find('-');
		if (dash == std::string::npos || dash == 0) { continue; }
		const std::string busText = name.substr(0, dash);
		const std::string addressText = name.substr(dash + 1);
		if (!allDigits(busText) || addressText.size() != 4) { continue; }
		bool hex = true;
		for (char c : addressText) {
			if (std::isxdigit(static_cast<unsigned char>(c)) == 0) { hex = false; }
		}
		if (!hex) { continue; }
		Json record = JsonObject();
		record.put("bus", JsonInt(std::stoi(busText)));
		char address[8];
		std::snprintf(address, sizeof(address), "0x%02X", std::stoi(addressText, nullptr, 16));
		record.put("address", JsonString(address));
		if (auto nameText = readText("/sys/bus/i2c/devices/" + name + "/name")) {
			record.put("name", JsonString(*nameText));
		} else {
			record.put("name", JsonNull());
		}
		const std::string driver = driverLink("/sys/bus/i2c/devices/" + name + "/driver");
		record.put("driver", driver.empty() ? JsonNull() : JsonString(driver));
		clients.add(record);
	}

	result.put("adapters", adapters);
	result.put("clients", clients);
	result.put("notes", notes);
	return result;
}

Json spiReport() {
	Json result = JsonObject();
	result.put("supported", JsonBool(true));
	Json controllers = JsonArray();
	Json devices = JsonArray();
	Json notes = JsonArray();

	for (const std::string& name : listDir("/sys/class/spi_master")) {
		if (!startsWith(name, "spi")) { continue; }
		Json controller = JsonObject();
		controller.put("name", JsonString(name));
		const std::string driver = driverLink("/sys/class/spi_master/" + name + "/device/driver");
		if (!driver.empty()) { controller.put("driver", JsonString(driver)); }
		controllers.add(controller);
	}

	for (const std::string& name : listDir("/dev")) {
		if (!startsWith(name, "spidev")) { continue; }
		const std::string suffix = name.substr(6);
		const std::size_t dot = suffix.find('.');
		if (dot == std::string::npos || !allDigits(suffix.substr(0, dot))
				|| !allDigits(suffix.substr(dot + 1))) {
			continue;
		}
		const std::string device = "/dev/" + name;
		Json record = JsonObject();
		record.put("device", JsonString(device));
		record.put("readable", JsonBool(::access(device.c_str(), R_OK) == 0));
		record.put("writable", JsonBool(::access(device.c_str(), W_OK) == 0));
		record.put("bus", JsonInt(std::stoi(suffix.substr(0, dot))));
		record.put("chip_select", JsonInt(std::stoi(suffix.substr(dot + 1))));
		if (auto modalias = readText("/sys/class/spidev/" + name + "/device/modalias")) {
			record.put("modalias", JsonString(*modalias));
		}
		devices.add(record);
	}

	bool general = false;
	for (std::size_t index = 0; index < controllers.size(); ++index) {
		const Json& controller = controllers.at(index);
		const Json* driver = controller.find("driver");
		if (driver == nullptr || !driver->isStr() || driver->getValue() != "intel-spi") {
			general = true;
		}
	}
	if (devices.size() == 0 && general) {
		notes.add(JsonString("no /dev/spidev*: enable CONFIG_SPI_SPIDEV or add a device tree overlay"));
	}

	result.put("controllers", controllers);
	result.put("devices", devices);
	result.put("notes", notes);
	return result;
}

bool serialPrefix(const std::string& name) {
	static const char* const prefixes[] = {"ttyS", "ttyUSB", "ttyACM", "ttyAMA",
		"ttyCH", "ttyXR", "ttySC", "ttyGS", "rfcomm"};
	for (const char* prefix : prefixes) {
		if (startsWith(name, prefix)) { return true; }
	}
	return false;
}

Json uartReport() {
	Json result = JsonObject();
	result.put("supported", JsonBool(true));
	result.put("backend", JsonString("os"));
	Json ports = JsonArray();
	Json notes = JsonArray();
	std::vector<std::string> seen;

	auto addDevice = [&](const std::string& device) {
		if (std::find(seen.begin(), seen.end(), device) != seen.end()) { return; }
		seen.push_back(device);
		Json record = JsonObject();
		record.put("device", JsonString(device));
		ports.add(record);
	};
	for (const std::string& name : listDir("/dev")) {
		if (serialPrefix(name)) { addDevice("/dev/" + name); }
	}
	for (const std::string& name : listDir("/sys/class/tty")) {
		if (!serialPrefix(name)) { continue; }
		const std::string device = "/dev/" + name;
		if (std::find(seen.begin(), seen.end(), device) != seen.end()) { continue; }
		seen.push_back(device);
		Json record = JsonObject();
		record.put("device", JsonString(device));
		record.put("source", JsonString("sysfs"));
		record.put("node_present", JsonBool(false));
		if (auto type = readText("/sys/class/tty/" + name + "/type")) {
			try { record.put("uart_type", JsonInt(std::stoi(*type))); } catch (...) {}
		}
		ports.add(record);
	}

	for (const char* directory : {"/dev/serial/by-id", "/dev/serial/by-path"}) {
		for (const std::string& name : listDir(directory)) {
			const std::string link = std::string(directory) + "/" + name;
			std::error_code code;
			const fs::path target = fs::canonical(link, code);
			if (code) { continue; }
			const std::string device = target.string();
			for (std::size_t index = 0; index < ports.size(); ++index) {
				Json& record = ports.arr[index];
				const Json* field = record.find("device");
				if (field == nullptr || !field->isStr() || field->getValue() != device) {
					continue;
				}
				Json* links = record.getPtr("stable_links");
				if (links == nullptr) {
					record.put("stable_links", JsonArray());
					links = record.getPtr("stable_links");
				}
				links->add(JsonString(link));
				break;
			}
		}
	}

	result.put("ports", ports);
	result.put("notes", notes);
	return result;
}

std::vector<std::string> parseBuses(const Json* value) {
	std::vector<std::string> selected;
	std::string text = "all";
	if (value != nullptr && value->isStr()) { text = value->getValue(); }
	std::vector<std::string> tokens;
	std::size_t start = 0;
	while (start <= text.size()) {
		const std::size_t comma = text.find(',', start);
		std::string token = text.substr(start,
			comma == std::string::npos ? std::string::npos : comma - start);
		const std::size_t begin = token.find_first_not_of(" \t\r\n");
		const std::size_t end = token.find_last_not_of(" \t\r\n");
		if (begin != std::string::npos) {
			token = token.substr(begin, end - begin + 1);
			std::transform(token.begin(), token.end(), token.begin(),
				[](unsigned char c) { return static_cast<char>(std::tolower(c)); });
			tokens.push_back(token);
		}
		if (comma == std::string::npos) { break; }
		start = comma + 1;
	}
	const bool all = std::find(tokens.begin(), tokens.end(), "all") != tokens.end()
		|| tokens.empty();
	for (const char* name : {"i2c", "spi", "uart"}) {
		if (all || std::find(tokens.begin(), tokens.end(), name) != tokens.end()) {
			selected.push_back(name);
		}
	}
	return selected;
}

class DevEnumDriver final : public NativeDriver {
public:
	explicit DevEnumDriver(HALManager&) {}

	Json build(const Json&) override { return ok(); }

	Json call(const Json& data) override {
		const std::vector<std::string> buses = parseBuses(data.find("buses"));
		Json result = ok();
		result.put("platform", JsonString("linux"));
		Json selected = JsonArray();
		for (const std::string& bus : buses) { selected.add(JsonString(bus)); }
		result.put("buses", selected);
		for (const std::string& bus : buses) {
			if (bus == "i2c") { result.put("i2c", i2cReport()); }
			else if (bus == "spi") { result.put("spi", spiReport()); }
			else if (bus == "uart") { result.put("uart", uartReport()); }
		}
		return result;
	}

	Json destroy(const Json&) override { return ok(); }
};

} // namespace

std::unique_ptr<NativeDriver> makeDevEnumDriver(HALManager& hal) {
	return std::make_unique<DevEnumDriver>(hal);
}

} // namespace bot
