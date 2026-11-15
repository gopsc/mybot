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
 *
 * Speaker/ALSA 自 2026-11 起走本层：C++ 侧 dlopen libasound（不引入
 * libasound2-dev 构建依赖），Lua 侧只合成 S16_LE 波形块；独立 luajit
 * 测试仍可回退 modules/lib/asound.lua 的 ffi 路径。
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

	/* 当前 RobotStruct 的 HAL（Lua 状态创建时从这里取桥）。
	 * 2026-11-15 审计修复：current 的返回值只供比较/诊断；需要跨 Lua 状态
	 * 持有生命周期时必须用 currentShared()，不能把裸指针塞进 Lua upvalue。 */
	static HALManager* current();
	static std::shared_ptr<HALManager> currentShared();
	static void setCurrent(std::shared_ptr<HALManager> hal);

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
	/* Speaker：一次 speaker_write 的原始 S16_LE 单声道字节上限。Speaker.lua
	 * 按 4096 帧（8192B）分块写，1 MiB 足够容纳整块且防止误传大缓冲区。 */
	static constexpr int kSpeakerMaxBytes = 1024 * 1024;
	/* 宿主状态文件（当前用于 SGP30 baseline 的 6 字节持久化）：单文件上限。
	 * 路径只允许 state 根下的单个文件名，不允许目录/绝对路径/traversal。 */
	static constexpr int kStateMaxBytes = 64 * 1024;

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
	/* Speaker/ALSA：宿主 C++ HAL 经 dlopen 动态加载 libasound，避免把 ALSA
	 * 开发头文件变成构建依赖。Lua 侧只负责合成波形，PCM 设备生命周期与
	 * 原始 S16_LE 写入在本层完成。 */
	Json opSpeakerOpen(const Json& device, const Json& rate, int owner);
	Json opSpeakerWrite(const Json& handle, const Json& data);
	Json opSpeakerPrepare(const Json& handle);
	Json opSpeakerDrain(const Json& handle);
	Json opSpeakerClose(const Json& handle);
	Json opSpeakerErrmsg(const Json& code);
	/* 宿主状态文件：仅允许 BOT4CJ_STATE_DIR 根下的单个安全文件名。
	 * state_read 返回字节数组（缺失返回 null），state_write 接收字节数组。 */
	Json opStateRead(const Json& name);
	Json opStateWrite(const Json& name, const Json& data);
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
