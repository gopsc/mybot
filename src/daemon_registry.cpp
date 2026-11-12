/* daemon_registry.cpp —— 守护域门面：退出屏障实现（2026-10-03 阶段 4 自
 * robot.cpp 的自由函数 daemonStopBarrier 迁入）。

 * 守护退场屏障：deactivate（断电前）与热删除（摘件前）共用的同一套安全序列。
 * 原先在两处各手抄一份，属安全序列的分叉温床（2026-09-25 去重），机械步骤：
 * requestStop 全体 → 全体共享一个 deadline 等待（取各守护 joinTimeout 的最大值；
 * 逐个累加会让最坏退出延迟随守护数量线性增长）→ 超时者给二段宽限（封顶
 * graceCapMs）→ 宽限耗尽仍存活者灭火（quiesce）+ 弃管，如实点名。审计出处与理由：
 *  屏障本体（审计 P2）：原实现把 join 延后到各守护自己的 destroy，于是执行器
 *  可能已经断电、而某个守护正在跑的那一拍又写它一次——最后一次写随机胜出，
 *  进程退出时器件可能重新带电。等过之后 destroy 里的 waitForExit 幂等直返。
 *  二段宽限（审计 P1 修复，2026-09-21）：弃管只是交出槽所有权，detached 线程
 *  并没有停——调用点紧跟着的逆序 destroy 会关闭总线/去初始化器件，与仍在
 *  tick/cleanup 的线程构成硬件竞态。这里在动硬件之前给弃管守护一次真正退场的
 *  机会（宽限 = 共享预算，封顶 graceCapMs：无法在 join 超时内退场的守护多半
 *  卡死在不可中断的调用里，更长的等待只是把停机挂死换掉竞态）。宽限内退场的
 *  线程不再与 destroy 并发；耗尽仍活着的经 finishTeardown 灭火后弃管——此后
 *  其 HAL 传输在进内核前被拒（BQ-1），竞态窗口收敛到灭火时刻的在途单次传输。
 * 调用点契约：屏障返回后才许动硬件。
 * 文案单点（同 agent_subprocess 的 reapGiveUpWarning 先例）：Deactivate 一侧
 * 被 test_robot 的 daemon_grace_ms 用例钉住（"granting 100ms grace"，数字与
 * "ms" 之间无空格），改文案须过那条用例。 */

#include "daemon_registry.hpp"

#include <algorithm>
#include <chrono>
#include <iostream>
#include <vector>

#include "daemonvar.hpp"

namespace bot {

void DaemonRegistry::stopBarrier(const std::vector<std::shared_ptr<DaemonRunner>>& holders,
		std::int64_t graceCapMs, const char* label, const char* stillNote) {
	for (const auto& h : holders) { h->requestStop(); }
	if (holders.empty()) { return; }
	int64_t budgetMs = 0;
	for (const auto& h : holders) {
		budgetMs = std::max(budgetMs, h->joinTimeoutMs());
	}
	const auto waitStart = std::chrono::steady_clock::now();
	const auto deadline = waitStart + std::chrono::milliseconds(budgetMs);
	std::vector<DaemonRunner*> missed;
	for (const auto& h : holders) {
		if (!h->requestStopAndWait(deadline)) { missed.push_back(h.get()); }
	}
	if (missed.empty()) { return; }
	const int64_t graceMs = std::min<int64_t>(budgetMs, graceCapMs);
	std::cerr << label << ": " << missed.size()
		<< " daemon(s) outlived the stop barrier, granting " << graceMs
		<< "ms grace before hardware de-init" << std::endl;
	std::size_t stillRunning = 0;
	for (auto* d : missed) {
		if (!d->finishTeardown(graceMs, waitStart)) { ++stillRunning; }
	}
	if (stillRunning > 0) {
		std::cerr << label << ": " << stillRunning
			<< " daemon(s) STILL running after grace window — " << stillNote
			<< " (their bus access has been quiesced)" << std::endl;
	}
}

} // namespace bot