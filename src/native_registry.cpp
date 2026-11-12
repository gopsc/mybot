#include "native_driver.hpp"

#include <map>

namespace bot {
namespace {

const std::map<std::string, NativeDriverFactory>& registry() {
	static const std::map<std::string, NativeDriverFactory> drivers = {
		{"Time", makeTimeDriver},
		{"LoopbackProbe", makeLoopbackProbeDriver},
		{"Shell", makeShellDriver},
		{"HTTP", makeHttpDriver},
		{"TCP", makeTcpDriver},
	};
	return drivers;
}

} // namespace

bool hasNativeDriver(const std::string& table) {
	return registry().count(table) != 0;
}

std::unique_ptr<NativeDriver> createNativeDriver(const std::string& table, HALManager& hal) {
	auto found = registry().find(table);
	if (found == registry().end()) { return nullptr; }
	return found->second(hal);
}

} // namespace bot
