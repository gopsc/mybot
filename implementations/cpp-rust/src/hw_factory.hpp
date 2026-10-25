#pragma once
/* hw_factory.hpp —— 硬件装配（拆自 robot.hpp，2026-09-29 A2；实现在 hw_factory.cpp） */

#include <cstdint>
#include <deque>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "daemon_registry.hpp"
#include "hardware.hpp"
#include "hw_registry.hpp"
#include "matrix.hpp"
#include "meta_provider.hpp"
#include "meta_registry.hpp"
#include "util_except.hpp"

namespace bot {

/* 重构计划 2.2：本头文件不再传导 LuaJIT 头（luaend.hpp 经 daemonvar/luavar
 * 拉入 lua.h，所有 include robot.hpp 的 TU 都被迫解析 Lua 头）。守护域改经
 * DaemonRegistry 门面引用，该门面自身以 shared_ptr 持有 DaemonRunner 且对
 * 不完整类型安全——本头无须见到 DaemonRunner。 */

/* ---- 硬件装配：矩阵表 → 硬件变量（R-1 拆自 RobotStruct）---- */
class HwFactory {
	HwRegistry& registry_;
	DaemonRegistry& daemons_;
	MetaRegistry& metas_;

	/* 重名前置判重（资源泄漏防线：Lua 状态机/共享槽先申请，此处先确认可注册）。
	 * 文案走 duplicateHwNameMsg 单点：本检查是 HwRegistry::add 的**提前版**，同一次
	 * 重名先命中哪个都要报得一样（理由见 hw_registry.hpp 的声明处）；source 后缀
	 * 与 hw_factory.cpp 里 createDaemonVars / createLuaVars 两处 add 调用同款。 */
	void precheckDuplicate(const std::string& name, const std::string& mtName) {
		if (registry_.contains(name)) {
			throw IllegalArgumentException(
				duplicateHwNameMsg(name, " (in table '" + mtName + "')"));
		}
	}

	void createDaemonVars(const mt::MatrixObject& matrix, const std::string& mtName,
			std::int64_t fromRow);
	void createLuaVars(const mt::MatrixObject& matrix, const std::string& mtName,
			std::int64_t fromRow);

	/* 装配前的单消费者判据（审计 1.3）：只对**自己声明** SINGLE_CONSUMER 的驱动
	 * 生效（其寄存器访问跨多个总线事务，器件侧地址相位会被第二个消费者踩掉）。
	 * HAL 的每次访问是单次 I2C_RDWR 原子事务，故绝大多数器件允许多消费者，
	 * 不做一刀切。判据 = (总线设备路径, 归一化地址) 唯一；冲突即报错并点名双方。
	 * 实现与理由见 hw_factory.cpp 的同名函数注释。 */
	static void checkSingleConsumer(const std::deque<mt::MatrixObject>& matrices);

	/* F5-4 → P1-3：同一物理串口被 2+ 个「各自 open 独立 fd」的消费者（UART 总线
	 * 变量 / 真机守护）声明时硬拒绝——HAL 不做跨变量引用计数，后关闭者以自己
	 * open 时的配置为准，混用波特率会互相改线速。此前只告警（同配置轮询下实际
	 * 可用），但告警容易被日志淹没、配置漂移无人感知；升级为加载期硬门禁，
	 * 强制使用者显式共享一个 UART 总线变量（'$uart-x' 引用）或走守护采样。
	 * 实现与理由见 hw_factory.cpp 的同名函数注释。 */
	static void rejectSharedUartPaths(const std::deque<mt::MatrixObject>& matrices);

	/* 标量文本矩阵种类：@Alias(参数别名的目标) / @Vars(命名数值) */
	enum class ScalarKind { Alias, Vars };

	/* 注册标量文本矩阵的公共实现（启动期/动作脚本期两路，见实现处）。
	 * fromRow 是**首个待装配的行号**（1 = 全量；热插表的增量装配传旧行数），
	 * 行 0 恒为列头。 */
	void registerScalarMatrix(const mt::MatrixObject& matrix, std::set<std::string>* session,
			ScalarKind kind, std::int64_t fromRow);

public:
	/* 守护侧缺省值（2026-09-21 第七轮审计）。单消费者判据遇到 Daemon 行**缺列**时
	 * 必须按守护侧的缺省补全，否则「省略 proto/path」这类被 docs/daemon.md 认可的
	 * 最小写法（`INSERT INTO Daemon (name, chunk)`）会整体绕过判据——运行期真的
	 * 开了总线 fd 却从不登记，漏标即双消费者静默数据错乱，且无运行期症状。
	 * 这三个值**必须**与 modules/lib/sensor_daemon.lua 的
	 *   local proto = cfg.proto or "i2c"
	 *   local path  = cfg.path or (proto == "spi" and "/dev/spidev0.0" or "/dev/i2c-1")
	 * 逐字一致；漂移由 test/cpp/test_robot.cpp 的 daemon_defaults_match_lua_source
	 * 读 Lua 源按文本钉住（不是在两处各手抄一遍就算数）。放成 public 正是为了让
	 * 那条用例能引用到 C++ 侧的值，做**两侧**比对。 */
	static constexpr const char* kDaemonDefaultProto = "i2c";
	static constexpr const char* kDaemonDefaultPathI2c = "/dev/i2c-1";
	static constexpr const char* kDaemonDefaultPathSpi = "/dev/spidev0.0";

	HwFactory(HwRegistry& registry,
			DaemonRegistry& daemons,
			MetaRegistry& metas)
		: registry_(registry), daemons_(daemons), metas_(metas) {}

	/* 全部硬变量创建：声明序，Alias/Vars/Lua/Daemon 分派 */
	void createHardVars(const std::deque<mt::MatrixObject>& matrices);

	/* 增量装配：只装配**单个矩阵**的 [fromRow, rows) 行（行 0 为列头）。
	 * 启动期 createHardVars 逐矩阵以 fromRow=1 调用本函数（单一装配路径，
	 * 全量/增量不各写一份）；热插表事务对「批次内新增的矩阵」用 fromRow=1、
	 * 对「既有矩阵的新增行」用 fromRow=旧行数。调用方负责前置的全量静态
	 * 校验（判据/重名/列/模块存在性等，见 RobotStruct::applySql）。 */
	void createHardVarsFrom(const mt::MatrixObject& matrix, std::int64_t fromRow);

	/* 全结构判据入口（单消费者 + 同串口多 fd 告警）——启动期 createHardVars
	 * 内部同样调用这两个。HotSqlPlanner 在提交之前对合并视图复跑同一判据，
	 * 无需 factory 实例；只读矩阵与模块文件，保留既有告警。
	 * 注意：判据看的是整张结构，故调用方传入的必须是合并后的视图。 */
	static void precheckStructure(const std::deque<mt::MatrixObject>& matrices);

	/* 注册 @Alias 别名矩阵 */
	void registerAliasMatrix(const mt::MatrixObject& matrix, std::set<std::string>* session) {
		registerScalarMatrix(matrix, session, ScalarKind::Alias, 1);
	}

	/* 注册 @Vars 命名数值矩阵 */
	void registerVarsMatrix(const mt::MatrixObject& matrix, std::set<std::string>* session) {
		registerScalarMatrix(matrix, session, ScalarKind::Vars, 1);
	}
};

} // namespace bot
