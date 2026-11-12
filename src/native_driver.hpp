#pragma once
/* native_driver.hpp —— 宿主侧 C++ 原生驱动接口
 *
 * Lua 驱动仍是默认（modules/<表名>.lua）；本接口用于不适合放进 Lua 的宿主
 * 能力（系统时间、TCP/HTTP/Shell、设备枚举等）。HwFactory 先查原生注册表，
 * 命中即装配 MtVars_Native，否则回落 Lua。
 */

#include <functional>
#include <memory>
#include <string>

#include "json.hpp"

namespace bot {

class HALManager;

class NativeDriver {
public:
	virtual ~NativeDriver() = default;

	/* build/call/read/destroy 与 Lua 驱动同契约：返回非空 Json 对象；
	 * 含 result 时必须是 "OK"/"ERR"。 */
	virtual Json build(const Json& data) = 0;
	virtual Json call(const Json& data) = 0;
	virtual Json read(const Json& data) { return call(data); }
	virtual Json destroy(const Json& data) {
		(void)data;
		Json ok = JsonObject();
		ok.put("result", JsonString("OK"));
		return ok;
	}
};

using NativeDriverFactory = std::function<std::unique_ptr<NativeDriver>(HALManager&)>;

bool hasNativeDriver(const std::string& table);
std::unique_ptr<NativeDriver> createNativeDriver(const std::string& table, HALManager& hal);

/* 各驱动的工厂声明（实现分散在 driver_*.cpp）。 */
std::unique_ptr<NativeDriver> makeTimeDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeLoopbackProbeDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeShellDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeHttpDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeTcpDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeDevEnumDriver(HALManager& hal);
std::unique_ptr<NativeDriver> makeI2cScanDriver(HALManager& hal);

} // namespace bot
