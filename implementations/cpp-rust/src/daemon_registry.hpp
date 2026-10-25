#pragma once
/* daemon_registry.hpp —— 守护域（拆自 RobotStruct 私有容器，2026-10-03 阶段 4）
 *
 * 守护线程登记表此前以 RobotStruct::daemonHolders_ 私有成员存在，装配期
 * （HwFactory → MtVars_Daemon::Factory）登记、断电/热删除期按序退场与摘除，
 * 四个域都在 RobotStruct 内部直接读写它。本类把「守护域」收敛成一个门面。
 *
 * 持有序即声明序（与硬件注册表同序）；退场序列（统一置 stop、屏障等待、逆序
 * 销毁）由调用方按不变式驱动——本类只管所有权与登记/摘除，不碰线程状态。
 * shared_ptr 的用意：守护线程持 self（weak_ptr 提升）保生命周期，登记表与
 * 硬件变量共享同一个 runner。
 */

#include <cstddef>
#include <cstdint>
#include <memory>
#include <set>
#include <vector>

namespace bot {

class DaemonRunner;

class DaemonRegistry {
public:
	/* 登记一个守护线程（装配期唯一入口，形参按值以便调用方保留自用引用） */
	void hold(std::shared_ptr<DaemonRunner> runner) { holders_.push_back(std::move(runner)); }

	std::size_t size() const { return holders_.size(); }

	const std::shared_ptr<DaemonRunner>& at(std::size_t idx) const { return holders_[idx]; }

	/* 声明序只读视图：断电/热删除的退场屏障遍历用 */
	const std::vector<std::shared_ptr<DaemonRunner>>& all() const { return holders_; }

	/* 热插回滚：丢弃本批次新增的守护登记（尾部截断） */
	void truncate(std::size_t n) { holders_.resize(n); }

	/* ---- 守护退场屏障：deactivate（断电前）与热删除（摘件前）共用的同一套
	 * 安全序列（2026-10-03 阶段 4 自 robot.cpp 自由函数迁入）----
	 * 机械步骤：requestStop 全体 → 全体共享一个 deadline 等待（取各守护
	 * joinTimeoutMs 的最大值；逐个累加会让最坏退出延迟随守护数量线性增长）→
	 * 超时者给二段宽限（封顶 graceCapMs）→ 宽限耗尽仍存活者灭火（quiesce）+
	 * 弃管，如实点名。调用点契约：屏障返回后才许动硬件。stillNote 承载两处的
	 * 后果差异（断电后可被重新写亮 vs 采样对象即将被摘除），由调用点描述。
	 * 实现与理由见 daemon_registry.cpp。
	 * 两个入口的分工：整表入口供 deactivate（断电前，全体守护）；清单入口供热
	 * 删除（只停**将被摘件的那批**守护，其采样对象即将被摘除）。 */
	static void stopBarrier(const std::vector<std::shared_ptr<DaemonRunner>>& holders,
		std::int64_t graceCapMs, const char* label, const char* stillNote);
	void stopBarrier(std::int64_t graceCapMs, const char* label, const char* stillNote) const {
		stopBarrier(holders_, graceCapMs, label, stillNote);
	}

	/* 热删除：按「被摘除的守护」集合重建登记表。不做 resize——删中间项会让
	 * 尾部前移，resize 只能表达「砍掉尾巴」；这里按保留项整体重建。 */
	void remove(const std::set<const DaemonRunner*>& doomed) {
		std::vector<std::shared_ptr<DaemonRunner>> kept;
		kept.reserve(holders_.size());
		for (const auto& h : holders_) {
			if (doomed.count(h.get()) == 0) { kept.push_back(h); }
		}
		holders_ = std::move(kept);
	}

private:
	std::vector<std::shared_ptr<DaemonRunner>> holders_;
};

} // namespace bot