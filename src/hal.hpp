#pragma once
/* hal.hpp —— C++ 硬件抽象层（替代 modules/lib/HAL.lua 的 FFI 物理后端）
 *
 * 所有操作名与当前 Python HAL 保持一致，Lua 驱动通过宿主注入的 __hal_call
 * 调用这里。物理设备、非回环网络和宿主 Shell 默认允许；virt-* / loop://
 * 与回环地址照常可用。
 *
 * GPIO/PWM 自 2026-11 起也走本层：GPIO 用 gpiod uAPI v1（/dev/gpiochipN
 * ioctl），PWM 用 Linux sysfs（/sys/class/pwm）。两者此前只在独立 luajit
 * 测试的 HAL_ffi 回退后端里可用，宿主运行期会报 unsupported。
 */

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "json.hpp"

namespace bot {

class HALManager {
public:
	HALManager();
	~HALManager();
	HALManager(const HALManager&) = delete;
	HALManager& operator=(const HALManager&) = delete;

	/* 返回值约定：
	 *   open/setup/close/sleep、gpio_request_line、pwm_npwm → JSON int/null
	 *   i2c/spi/uart 读 → JSON array 或 null
	 *   gpio_set_value、pwm_export/exported/enable/set_polarity/unexport → JSON bool
	 *   pwm_config → [true, period_ns, duty_ns] 或 false
	 *   tcp_write/tcp_read/http_request/shell_run → JSON object
	 *   last_error → JSON string
	 * 异常在内部折成与 Lua HAL 相同的失败形态。 */
	Json call(const std::string& operation, const std::vector<Json>& args,
		int owner = 0);

	/* 关闭本管理器持有的全部句柄（deactivate 兜底）。 */
	void closeAll();

	/* 当前 RobotStruct 的 HAL（Lua 状态创建时从这里取桥）。 */
	static HALManager* current();
	static void setCurrent(HALManager* hal);

	static constexpr int kUartMaxBytes = 512;
	static constexpr int kUartMaxMs = 60000;
	static constexpr int kTcpMaxBytes = 512;
	static constexpr int kTcpMaxMs = 60000;
	static constexpr int kHttpMaxBytes = 4 * 1024 * 1024;
	static constexpr int kHttpMaxHeaders = 16;
	static constexpr int kHttpTimeoutMs = 60000;
	static constexpr int kShellMaxCmdBytes = 64 * 1024;
	static constexpr int kShellMaxOutBytes = 1024 * 1024;
	static constexpr int kShellTimeoutMs = 60000;
	static constexpr int kPwmMaxId = 65535;

private:
	struct Resource;

	/* 句柄租约：map 只保护「句柄 → Resource」的所有权，Resource 自己的
	 * recursive_mutex 保护「操作期间不被 close」。两者分锁，避免长时间
	 * HTTP/Shell 阻塞所有句柄的 open/close；recursive 允许 TCP 错误路径在
	 * 租约内直接 closeResource。 */
	struct Lease {
		std::shared_ptr<Resource> resource;
		std::unique_lock<std::recursive_mutex> lock;
		explicit Lease(std::shared_ptr<Resource> r);
	};

	Json opI2cOpen(const Json& path, const Json& virtualFlag, int owner);
	Json opI2cTransfer(const Json& handle, const Json& address,
		const Json& write, const Json& readCount);
	Json opSpiOpen(const Json& path, const Json& virtualFlag, int owner);
	Json opSpiSetup(const Json& handle, const Json& mode,
		const Json& bits, const Json& speed);
	Json opSpiTransfer(const Json& handle, const Json& data, const Json& delayUs);
	Json opGpioRequestLine(const Json& chip, const Json& offset,
		const Json& direction, const Json& defaultValue, const Json& activeLow,
		int owner);
	Json opGpioSetValue(const Json& handle, const Json& value);
	Json opGpioGetValue(const Json& handle);
	Json opGpioFreeLine(const Json& handle);
	Json opPwmNpwm(const Json& chip);
	Json opPwmExported(const Json& chip, const Json& channel);
	Json opPwmExport(const Json& chip, const Json& channel);
	Json opPwmConfig(const Json& chip, const Json& channel,
		const Json& frequency, const Json& duty);
	Json opPwmSetPolarity(const Json& chip, const Json& channel, const Json& inversed);
	Json opPwmEnable(const Json& chip, const Json& channel, const Json& on);
	Json opPwmUnexport(const Json& chip, const Json& channel);
	Json opUartOpen(const Json& path, const Json& baud, const Json& virtualFlag,
		int owner);
	Json opUartWrite(const Json& handle, const Json& data);
	Json opUartRead(const Json& handle, const Json& count, const Json& timeoutMs);
	Json opUartFlush(const Json& handle);
	Json opTcpOpen(const Json& host, const Json& port, const Json& timeoutMs,
		int owner);
	Json opTcpWrite(const Json& handle, const Json& data, const Json& timeoutMs);
	Json opTcpRead(const Json& handle, const Json& count, const Json& timeoutMs);
	Json opHttpOpen(const Json& base, const Json& timeoutMs, int owner);
	Json opHttpRequest(const Json& handle, const Json& method, const Json& path,
		const Json& headers, const Json& body);
	Json opShellOpen(const Json& timeoutMs, int owner);
	Json opShellRun(const Json& handle, const Json& command, const Json& timeoutMs);
	Json opCloseHandle(const Json& handle);
	Json opSleepMs(const Json& ms);

	std::shared_ptr<Resource> lookup(std::int64_t handle, const char* kind);
	Lease acquire(std::int64_t handle, const char* kind);
	std::int64_t add(std::unique_ptr<Resource> resource, int owner);
	std::int64_t addBus(const char* kind, const std::string& path, int fd,
		const std::string& backend, int owner, int baud = 0);
	void closeResource(Resource& resource);

	mutable std::mutex mutex_;	/* handles_/owners_/nextHandle_ 的锁 */
	std::map<std::int64_t, std::shared_ptr<Resource>> handles_;
	std::map<std::int64_t, int> owners_;
	std::int64_t nextHandle_ = 1LL << 20;
	bool closed_ = false;
};

} // namespace bot
