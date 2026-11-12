#pragma once
/* daemonconf.hpp —— @Daemon 配置校验/装配域的对外判据
 *
 * 2026-10-01 自 daemonvar.hpp 析出（行为保持，随 daemonconf.cpp 的 TU 拆分
 * 对齐声明归属）：interval 列解析与 chunk 路径寻址由 daemonconf.cpp 提供，
 * 消费方（daemonvar 线程机 / hw_factory / hotsql_plan / 表驱动单测）经本头
 * 引用。共享槽布局、线程机与守护运行器仍在 daemonvar.hpp。
 *
 * 2026-10-04 续：MtVars_Daemon 的类声明也迁到这里。它的 Factory/play/build/
 * destroy 四个成员函数实现本就全在 daemonconf.cpp，声明留在 daemonvar.hpp 只是
 * 让「谁实现谁声明」对不上；顺带的好处是只想要守护硬件变量的 TU（hw_factory.cpp）
 * 不必再为自己用不到的槽布局与线程机引一份 daemonvar.hpp。 */

#include <cstdint>
#include <memory>
#include <string>

#include "hardware.hpp"		/* 基类 MatrixVars_Hardware；play 的 Json 形参/返回 */
#include "daemonvar.hpp"	/* 成员 std::shared_ptr<DaemonRunner>（隐式析构需完整类型） */

namespace bot {

/* 守护域门面（daemon_registry.hpp）：Factory 经它登记新守护线程，故此处只需
 * 前向声明（形参为引用，无需完整类型）。 */
class DaemonRegistry;

/* D/C4：解析 Daemon 的 interval 列（毫秒）。非法值（非整数/溢出/负/0/超 1h）
 * 抛 IllegalArgumentException 并点名表名与行号；成功返回毫秒数。 */
int64_t parseInterval(const std::string& iv, const std::string& name,
	const std::string& tabName, int64_t row);

/* ---- chunk 路径寻址（issue #19 多路径；实现 daemonconf.cpp）---- */
std::string firstExistingModule(const std::string& paths, const std::string& rel);
std::string resolveDaemonChunk(const std::string& chunk, const std::string& modulePath);

/* ---- 守护硬件变量（R-3：真实子类，持 runner 的 shared_ptr）----
 * build/destroy 的参数（chunk 路径/配置串/interval）在 Factory 时定型为成员。 */
class MtVars_Daemon : public MatrixVars_Hardware {
	std::shared_ptr<DaemonRunner> runner_;
	std::string name_;
	std::string chunkPath_;
	std::string configStr_;
	int64_t intervalMs_;

	explicit MtVars_Daemon(std::shared_ptr<DaemonRunner> runner, std::string name,
			std::string chunkPath, std::string configStr, int64_t intervalMs)
		: runner_(std::move(runner)), name_(std::move(name)),
		  chunkPath_(std::move(chunkPath)), configStr_(std::move(configStr)),
		  intervalMs_(intervalMs) {}

public:
	Json play(const Json&) override;
	const char* kindName() const override { return "daemon"; }
	void build() override;
	void destroy() override;

	static std::unique_ptr<MtVars_Daemon> Factory(const mt::MatrixObject& defs, std::int64_t i,
			DaemonRegistry& registry);
};

} // namespace bot
