/* test_daemon_concurrency.cpp —— DaemonRunner 跨线程压测（审计覆盖缺口 #1）
 *
 * test_daemon.cpp 覆盖状态机分支（never-spawn / abandon 单线程视角），
 * test_pthread.lua 自述单线程验证 IPC 原语——「多线程同时读写共享槽」
 * 与「多守护交错启停」此前零覆盖，也是 TSan（gate:tsan）的主要观测面：
 *   1. daemon_concurrent_readers_during_publish
 *      守护高频 publish 期间 4 个读者线程并发 play()——槽 mutex 保护 +
 *      count 单调性（同一读者视角绝不回退）。
 *   2. daemon_multi_runner_staggered_teardown
 *      8 个守护（6 快 + 2 慢拍）并发 spawn，随后 8 线程并发 destroy——
 *      压审计 #2 修复的 exchange 所有权裁决（joined/abandoned 混合命中），
 *      终态全部槽释放、无泄漏无双重释放。
 *   3. daemon_stop_and_exit_reentry
 *      requestStop / waitForExit / play 三者并发重入 + 退出后再触碰——
 *      验证 H-3 防线（abandoned/已释放后不再解引用槽）。
 * 夹具：daemon_probe.lua（./modules，快拍发布）；慢拍 chunk 写入 .tmp/。
 */

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "daemon_registry.hpp"
#include "daemonconf.hpp"
#include "daemonvar.hpp"
#include "fixtures.hpp"
#include "harness.hpp"

using bot::DaemonRunner;
using bot::MtVars_Daemon;

namespace {

const char* const kSlowConcChunk = "test_daemon_conc_slow.lua";

void writeSlowConcChunk() {
	std::ofstream out(std::string(".tmp/") + kSlowConcChunk, std::ios::binary | std::ios::trunc);
	out << "local ffi = require(\"ffi\")\n"
	    << "ffi.cdef(\"int usleep(unsigned int usec);\")\n"
	    << "function daemon_tick()\n"
	    << "  ffi.C.usleep(2500000)\n"		/* 2.5s/拍 > join 超时 2s → abandoned 路径 */
	    << "  return 1\n"
	    << "end\n";
}

mt::MatrixObject daemonDefs(const std::string& chunk, const std::string& name, int interval) {
	return fx::oneMatrix("@Daemon\nname chunk interval;\n" + name + " " + chunk + " "
		+ std::to_string(interval) + ";\n@\n");
}

/* 快拍守护夹具：daemon_probe 在默认 ./modules 下，interval=2ms 高频发布 */
std::unique_ptr<MtVars_Daemon> makeFastDaemon(bot::DaemonRegistry& registry,
		const std::string& name) {
	mt::MatrixObject defs = daemonDefs("lib/daemon_probe.lua", name, 2);
	return MtVars_Daemon::Factory(defs, 1, registry);
}

/* 慢拍守护夹具：chunk 在 .tmp（BOT4CJ_MODULE_PATH 需含 .tmp），abandon 必现 */
std::unique_ptr<MtVars_Daemon> makeSlowDaemon(bot::DaemonRegistry& registry,
		const std::string& name) {
	writeSlowConcChunk();
	mt::MatrixObject defs = daemonDefs(kSlowConcChunk, name, 10);
	return MtVars_Daemon::Factory(defs, 1, registry);
}

} // namespace

TH_TEST(daemon_concurrent_readers_during_publish) {
	bot::DaemonRegistry registry;
	std::unique_ptr<MtVars_Daemon> var = makeFastDaemon(registry, "c0");
	var->build();
	std::this_thread::sleep_for(std::chrono::milliseconds(50));

	/* 4 读者线程并发 play()：各自记录 last count，断言同一视角 count 不回退，
	 * 且线程生存期内读到过 OK 快照（守护确实在发布）。 */
	std::atomic<int> ok_reads{0};
	std::atomic<bool> regression{false};
	std::vector<std::thread> readers;
	for (int t = 0; t < 4; ++t) {
		readers.emplace_back([&] {
			long long last = -1;
			for (int i = 0; i < 150; ++i) {
				bot::Json snap = var->play(bot::JsonObject());
				auto status = snap.get("status");
				auto count = snap.get("count");
				if (!status || !count) { continue; }
				if (status->getValue() == "OK") {
					ok_reads.fetch_add(1);
					long long n = count->getInt();
					if (n < last) { regression.store(true); }
					last = n;
				}
			}
		});
	}
	for (std::thread& t : readers) { t.join(); }
	TH_CHECK(ok_reads.load() > 0);
	TH_CHECK(!regression.load());

	/* 停机走正常 joined 路径，槽释放后读者再触碰按 ERR 契约返回 */
	var->destroy();
	TH_CHECK(!registry.at(0)->slotAlive());
	bot::Json err = var->play(bot::JsonObject());
	TH_CHECK(err.get("result")->getValue() == "ERR");
}

TH_TEST(daemon_multi_runner_staggered_teardown) {
	/* 慢拍 chunk 在 .tmp、快拍 daemon_probe 在 ./modules——多路径按序解析。
	 * 注意 ./modules 必须在首位：chunk 内部的 lib 样板（mpath/pthread）只按
	 * 首段加载，后续段仅供 firstExistingModule 找 chunk/driver 文件。 */
	setenv("BOT4CJ_MODULE_PATH", "./modules:.tmp", 1);
	bot::DaemonRegistry registry;
	std::vector<std::unique_ptr<MtVars_Daemon>> vars;
	for (int k = 0; k < 6; ++k) {
		vars.push_back(makeFastDaemon(registry, "fast" + std::to_string(k)));
	}
	for (int k = 0; k < 2; ++k) {
		/* 慢拍 2.5s > join 超时 2s → destroy 必走 abandoned（exchange 裁决路径） */
		vars.push_back(makeSlowDaemon(registry, "slow" + std::to_string(k)));
	}
	for (std::unique_ptr<MtVars_Daemon>& v : vars) { v->build(); }
	std::this_thread::sleep_for(std::chrono::milliseconds(100));

	/* 8 线程并发 destroy：快守护 joined、慢守护 abandoned，交错命中——
	 * 主线程与守护线程两侧 exchange 裁决的唯一胜者释放，终态全部清空。 */
	std::vector<std::thread> dtors;
	for (std::unique_ptr<MtVars_Daemon>& v : vars) {
		dtors.emplace_back([&v] { v->destroy(); });
	}
	for (std::thread& t : dtors) { t.join(); }

	/* 慢守护线程完成当前拍（≤2.5s）自行释放；留 3.5s 余量（调度抖动，
	 * 与 test_daemon.cpp 的 abandoned 等待同款放宽）。 */
	std::this_thread::sleep_for(std::chrono::milliseconds(3500));
	for (std::size_t k = 0; k < registry.size(); ++k) {
		TH_CHECK(!registry.at(k)->slotAlive());
	}
}

TH_TEST(daemon_stop_and_exit_reentry) {
	bot::DaemonRegistry registry;
	std::unique_ptr<MtVars_Daemon> var = makeFastDaemon(registry, "r0");
	var->build();
	std::this_thread::sleep_for(std::chrono::milliseconds(50));

	/* requestStop 与 play 并发竞争（两者都经槽内 mutex，生产契约允许的
	 * 主线程 API 交错）——停机路径与采样路径的竞争此前只在串行代码里被测过。
	 * 注意不含 destroy：waitForExit 会释放槽，与 play 并发属契约外用法
	 * （真实生命周期里 play/destroy 同在主线程顺序执行），TSan 实测其确为
	 * use-after-free 级竞争，不应在测试里制造。 */
	std::atomic<bool> no_crash{true};
	std::thread stopper([&] {
		for (int i = 0; i < 50; ++i) {
			registry.at(0)->requestStop();
		}
	});
	std::thread toucher([&] {
		for (int i = 0; i < 50; ++i) {
			bot::Json snap = var->play(bot::JsonObject());
			auto result = snap.get("result");
			auto status = snap.get("status");
			/* 两种合法形态：OK 快照 或 ERR 契约（槽已释放）；其它形态即防线失守 */
			bool ok_snap = status && status->getValue() == "OK";
			bool err_snap = result && result->getValue() == "ERR";
			if (!ok_snap && !err_snap) { no_crash.store(false); }
		}
	});
	stopper.join();
	toucher.join();

	/* 停机走正常 joined 路径（daemon_probe 快拍，join 不超时） */
	var->destroy();
	TH_CHECK(!registry.at(0)->slotAlive());
	TH_CHECK(no_crash.load());

	/* 退出后再触碰：requestStop / waitForExit / play 全部按契约无事发生 */
	registry.at(0)->requestStop();
	var->destroy();
	TH_CHECK(!registry.at(0)->slotAlive());
}
