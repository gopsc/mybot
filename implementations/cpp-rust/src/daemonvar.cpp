#include "daemonvar.hpp"
#include "luaend.hpp"	/* 线程体直接调 Lua C API（hpp 已摘传导） */
#include "daemonconf.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <pthread.h>
#include <stdexcept>
#include <thread>

#include "debug_log.hpp"	/* logD */
#include "util_except.hpp"
#include "util_file.hpp"
#include "util_num.hpp"
#include "util_path.hpp"
#include "util_str.hpp"

namespace bot {

/* N-7：abandoned 守护线程进程级计数——join 超时弃管的线程在进程退出时
 * 被 detach 硬杀，其私有 lua_State 泄漏在 exit 路径上无法观察（「宁漏不崩」
 * 已声明，但缺运行时可见性）。计数供 main 退出前统一告警。 */
static std::atomic<int> g_abandonedDaemons{0};

int abandonedDaemonCount() { return g_abandonedDaemons.load(); }

/* L4：共享槽布局硬编码 mutex 预留 64 字节（daemonvar.hpp），超出即越界写 count——
 * glibc aarch64=48B / x86_64=40B 远小于 64，但异种 libc 应在编译期就失败。 */
static_assert(sizeof(pthread_mutex_t) <= 64,
	"DaemonSlot reserves 64 bytes for pthread_mutex_t; this libc's pthread_mutex_t is larger");

pthread_mutex_t* mutexOf(DaemonSlot* slot) {
	return reinterpret_cast<pthread_mutex_t*>(slot->mutex);
}

void daemon_request_stop(DaemonSlot* slot) {
	pthread_mutex_lock(mutexOf(slot));
	slot->stop = 1;
	pthread_mutex_unlock(mutexOf(slot));
}

bool daemon_stop_requested(DaemonSlot* slot) {
	pthread_mutex_lock(mutexOf(slot));
	std::uint8_t s = slot->stop;
	pthread_mutex_unlock(mutexOf(slot));
	return s != 0;
}

/* BQ-1：总线灭火位（置位后该守护 lua_State 的 HAL 传输一律拒绝）。
 * 只置不清（见头文件布局注）；持锁写与 HAL.lua 的 bus_quiesced 持锁读同规。 */
void daemon_quiesce(DaemonSlot* slot) {
	pthread_mutex_lock(mutexOf(slot));
	slot->quiesce = 1;
	pthread_mutex_unlock(mutexOf(slot));
}

bool daemon_quiesced(DaemonSlot* slot) {
	pthread_mutex_lock(mutexOf(slot));
	std::int32_t q = slot->quiesce;
	pthread_mutex_unlock(mutexOf(slot));
	return q != 0;
}

/* ---- 共享槽释放（2.4）：作为 shared_ptr 删除器，由「最后一个持有者」
 * 调用——引用计数保证此刻无任何线程仍在临界区内。
 * ABI v2：values 是随槽分配的独立堆数组，先于槽本体释放。 ---- */
void releaseSlot(DaemonSlot* slot) {
	pthread_mutex_destroy(mutexOf(slot));
	std::free(slot->values);
	std::free(slot);
}

/* ---- DaemonRunner RAII 兜底（见头文件注释）：只原子交出自己的引用，
 * 不触碰槽本身——未 spawn 时本成员是唯一所有者，交出即释放；已 spawn 时
 * 线程副本兜底到最后，既不悬垂也不泄漏。 ---- */
DaemonRunner::~DaemonRunner() {
	std::atomic_store(&slot_, std::shared_ptr<DaemonSlot>());
}

/* ---- 注入守护线程 Lua 全局（单点，body 与 setup 共用）----
 * 槽地址经 lua_pushlightuserdata 注入：lightuserdata 在 Lua 域无算术、无
 * tonumber，「地址被 double 化后 >=2^53 静默丢位」这一风险类别在语言层面
 * 消除（旧 lua_pushinteger 注入靠「禁止对地址做算术」的契约注释兜底，
 * 见 pthread.lua slot_attach）。
 * 配置串 + 布局表：布局常量单一事实源 = daemonvar.hpp 的 struct + 静态断言
 * （2.7），pthread.lua 手抄常量降为无宿主注入环境兜底。 */
static void injectDaemonGlobals(lua_State* L, DaemonSlot* slot, const std::string& config,
		const std::vector<std::pair<std::string, std::shared_ptr<DaemonSlot>>>& peers) {
	/* LUA_GLOBALSINDEX 是 Lua 5.1/LuaJIT 的伪索引宏（Lua 5.2+ 已移除，改用
	 * lua_pushglobaltable）。本工程锁 LuaJIT 5.1 ABI，故直接可用；若将来换宿主
	 * Lua 版本，这里是必须同步改动的点（pthread.lua 侧的槽协议另需同步）。 */
	lua_pushlightuserdata(L, slot);
	lua_setfield(L, LUA_GLOBALSINDEX, "DAEMON_SLOT_ADDR");
	lua_pushstring(L, config.c_str());
	lua_setfield(L, LUA_GLOBALSINDEX, "DAEMON_CONFIG");

	lua_createtable(L, 0, 9);
	auto setOff = [&L](const char* k, int32_t v) {
		lua_pushinteger(L, v);
		lua_setfield(L, -2, k);
	};
	setOff("count", SLOT_COUNT_OFF);
	setOff("nvals", SLOT_NVALS_OFF);
	setOff("values", SLOT_VALUES_OFF);
	setOff("capacity", SLOT_CAPACITY_OFF);
	setOff("stop", SLOT_STOP_OFF);
	setOff("status", SLOT_STATUS_OFF);
	setOff("quiesce", SLOT_QUIESCE_OFF);
	setOff("size", SLOT_SIZE);
	/* ABI v2：maxvals 语义从「全局编译期常量」变为「本槽容量」——消费方
	 * （sensor_daemon_multi 的字段预算）据此自动按行感知容量，无需改代码。
	 * 无宿主注入时 pthread.lua 回落 64（slot_new 的缺省容量）。 */
	setOff("maxvals", slot->capacity);
	lua_setfield(L, LUA_GLOBALSINDEX, "DAEMON_SLOT_LAYOUT");

	/* 多守护聚合（sources 列）：peer 槽以 lightuserdata 注入（与 DAEMON_SLOT_ADDR
	 * 同一风险类别消除口径：Lua 域无算术、无 tonumber）。裸指针的生命期由
	 * runner 的 peers_ 强引用覆盖（见 daemonvar.hpp 成员注释）。非聚合守护
	 * （peers_ 空）不注入该全局——chunk 侧据此区分「无 peer 配置」与「配置了
	 * 但 peer 丢失」（后者是装配期错误，宿主已在加载期拒绝）。 */
	if (!peers.empty()) {
		lua_createtable(L, 0, static_cast<int>(peers.size()));
		for (const auto& [peerName, peerSlot] : peers) {
			lua_pushlightuserdata(L, peerSlot.get());
			lua_setfield(L, -2, peerName.c_str());
		}
		lua_setfield(L, LUA_GLOBALSINDEX, "DAEMON_PEER_SLOTS");
	}
}

/* ---- setup：跑 chunk 一次定义 daemon_tick ----
 * 失败按 load/setup 两段打印分段错误（run_all.sh 守门按两种短语匹配）。 */
static bool setupDaemonChunk(lua_State* L, const std::string& chunk) {
	/* BQ-2：守护 chunk 与主线程驱动同一信任前提（ffi 全能力），体检同规 */
	auditTrustedFilePath(chunk, "守护 chunk");
	int st = luaL_loadfile(L, chunk.c_str());
	if (st != LUA_OK) {
		std::cerr << "[daemon] chunk load error: " << luaErrorString(L) << std::endl;
		return false;
	}
	int setupStatus = lua_pcall(L, 0, LUA_MULTRET, 0);
	if (setupStatus != LUA_OK) {
		std::cerr << "[daemon] chunk setup error: " << luaErrorString(L) << std::endl;
		return false;
	}
	return true;
}

/* ---- 分段可打断睡眠：把总时长切成小片逐片睡，每片醒来查一次停止标志 ----
 * C-L2 尾：错误退避上限 ×256（interval 上限 1h → 最长数天），一次性
 * sleep_for 会让 requestStop/waitForExit 的停止语义在整个退避睡眠期间被
 * 架空——join 超时只有 interval×5，必然走弃管路径。分段后退避总时长不变，
 * stop 响应延迟收敛到单片时长。取 100ms：远小于任何现实 join 超时
 * （保底 2000ms），轮询成本可忽略（一次 mutex 加锁 / 100ms）。 */
static void sleepSliced(DaemonSlot* slot, int64_t totalMs) {
	constexpr int64_t kSliceMs = 100;
	int64_t waited = 0;
	while (waited < totalMs && !daemon_stop_requested(slot)) {
		int64_t slice = std::min(kSliceMs, totalMs - waited);
		std::this_thread::sleep_for(std::chrono::milliseconds(slice));
		waited += slice;
	}
}

/* ---- 逐拍循环：每拍 getglobal(daemon_tick)+pcall 采样一次；拍间 sleep ----
 * C-L2：错误限频 + 指数退避——tick 持续抛错（如 daemon_tick 未定义/加载
 * 失败）原实现按拍频刷 stderr（缺省 5ms ≈ 200 行/秒）且永不退避。前 3 次
 * 逐条打印定位问题，之后每 100 次一条摘要；拍间 sleep 按 2^n 退避
 * （上限 ×256，避免长 interval 停机阻塞被进一步放大），成功一拍即清零。
 * 退避睡眠走 sleepSliced 分段查 stop，不再吞掉停止请求。 */
static void runTickLoop(lua_State* L, DaemonSlot* slot, int64_t intervalMs) {
	int64_t tickErrors = 0;
	while (!daemon_stop_requested(slot)) {
		lua_getglobal(L, "daemon_tick");
		int st2 = lua_pcall(L, 0, LUA_MULTRET, 0);
		if (st2 != LUA_OK) {
			++tickErrors;
			if (tickErrors <= 3 || tickErrors % 100 == 0) {
				std::cerr << "[daemon] tick error #" << tickErrors << ": "
					<< luaErrorString(L) << std::endl;
			}
		} else {
			tickErrors = 0;
		}
		lua_settop(L, 0);
		int64_t sleepMs = intervalMs;
		if (tickErrors > 0) {
			sleepMs = intervalMs * (int64_t(1) << std::min<int64_t>(tickErrors, 8));
		}
		sleepSliced(slot, sleepMs);
	}
}

/* ---- 守护线程体：建私有 lua_State，注入槽地址 + 配置，setup 一次 + 逐拍 tick ----
 * 线程持 runner 的 shared_ptr 保生命周期；入口另取槽的强引用副本——
 * 整个 tick 循环期间槽由副本保证存活，弃管（主线程交出引用）后本副本
 * 就是最后所有者，返回时触发删除器。2.4：旧协议的退出检查点 + exchange
 * 唯一胜者仲裁（D2/审计 #2）在引用计数模型下不需要。 */
int64_t DaemonRunner::body(const std::string& chunk, const std::string& config, int64_t intervalMs) {
	std::shared_ptr<DaemonSlot> slot = std::atomic_load(&slot_);
	if (slot == nullptr) { return -1; }	/* 弃管早于本线程首次取槽的交错：槽已移交，无事可做 */
	lua_State* L = openSandboxedState();
	if (L == nullptr) { return -1; }

	/* 第五个「异常不得穿出」边界（2026-10-01 审计 P2，判据锚点见 util_except.hpp）：
	 * 本线程是 detached，异常穿出线程函数即 std::terminate，主线程的停机清理链
	 * （deactivate 断电）整条被跳过——执行器带电滞留，正是本项目自评最严重的
	 * 失效形态。主线程同型风险此前已由 luabridge 的 F5-2（pcall 包裹 getglobal）
	 * 修复，daemon 线程是被漏掉的边界。裸露点：body 内多处 Lua C API 调用不经
	 * pcall——injectDaemonGlobals 的 push 系列（OOM 即 luaD_throw）、tick 循环与
	 * cleanup 段的 getglobal（chunk 可给 _G 装带报错 __index 的元表）。异常折成
	 * -1（中途计数不可信）+ 响亮日志；promise 照常 set，join 路径正常走完。 */
	int64_t n = -1;
	try {
		/* 注入共享槽地址（lightuserdata）+ 配置串 + 布局表（+ 聚合 peer 槽）为 Lua 全局 */
		injectDaemonGlobals(L, slot.get(), config, peers_);

		if (setupDaemonChunk(L, chunk)) {
			lua_settop(L, 0);

			runTickLoop(L, slot.get(), intervalMs);

			/* H-07：stop 后、lua_close 前调用 chunk 定义的 daemon_cleanup()（若存在） */
			lua_getglobal(L, "daemon_cleanup");
			if (lua_type(L, -1) == LUA_TFUNCTION) {
				int st3 = lua_pcall(L, 0, LUA_MULTRET, 0);
				if (st3 != LUA_OK) {
					std::cerr << "[daemon] cleanup error: " << luaErrorString(L) << std::endl;
				}
			}
			lua_settop(L, 0);

			/* F-01：count 与 stop 同规——都在槽内 mutex 临界区读取（此前锁外裸读，
			 * 与 daemonvar.hpp 的 stop 纪律不对称） */
			pthread_mutex_lock(mutexOf(slot.get()));
			n = slot->count;
			pthread_mutex_unlock(mutexOf(slot.get()));
		}
	} catch (const std::exception& e) {
		std::cerr << "[daemon] body aborted by exception: " << e.what()
			<< " — closing state, publish count unreliable, returning -1" << std::endl;
		n = -1;
	} catch (...) {
		std::cerr << "[daemon] body aborted by " << kNonStdExceptionNote
			<< " — closing state, publish count unreliable, returning -1" << std::endl;
		n = -1;
	}
	try {
		lua_close(L);
	} catch (...) {
		/* lua_close 跑 ffi __gc 收尾同样可能抛（判据同上）。吞掉但留痕：此刻
		 * 状态机已半释放，进程续命让停机断电链可达，比 terminate 重要。 */
		std::cerr << "[daemon] lua_close threw (" << kNonStdExceptionNote
			<< ") — state partially freed, continuing" << std::endl;
	}
	/* 2.4：返回即交还本线程的引用副本。弃管路径下这里是最后所有者，
	 * 删除器（mutex_destroy + free）在本线程执行——与旧协议「线程自行
	 * 释放」语义一致，仲裁交给引用计数。 */
	return n;
}

/* ---- start：spawn 守护线程 ---- */
void DaemonRunner::start(const std::string& chunk,
		const std::string& config, int64_t intervalMs) {
	if (std::atomic_load(&slot_) == nullptr) {
		throw std::runtime_error("Daemon '" + name_ + "' slot already released, cannot spawn");
	}
	/* self_ 是 weak_ptr（打破自引用环防泄漏）：此处取回强引用交给线程保生命周期。
	 * build 期 registry 必持有强引用，lock() 不会失败；万一取空则显式报错，
	 * 不把空 shared_ptr 交给线程去解引用。 */
	std::shared_ptr<DaemonRunner> keep = self_.lock();
	if (!keep) {
		throw std::runtime_error("Daemon '" + name_ + "' runner was released before spawn");
	}
	/* D1 + 审计：spawned_ 必须在守护线程可能开始执行**之前**置位。
	 * std::thread 构造即已启动线程，故不能只把 store 挪到 detach() 之前——
	 * 那仍留着「线程已进入 body（读写槽）而 spawned_ 仍为 false」的窗口：
	 * 此刻并发的 waitForExit 读到 false，会走「从未 spawn」分支直接
	 * releaseSlot，线程随后触碰已释放内存（use-after-free）。
	 * 置位前移到线程构造之前；构造抛异常则回滚，保持「未 spawn →
	 * promise 永不 set → 停机直接释放槽」的既有 D1 语义。 */
	spawned_.store(true, std::memory_order_release);
	try {
		std::thread([chunk, config, intervalMs, keep]() {
			int64_t r = keep->body(chunk, config, intervalMs);
			try { keep->result_->set_value(r); } catch (...) { /* future 已被消费/进程退出 */ }
		}).detach();
	} catch (...) {
		spawned_.store(false, std::memory_order_release);
		throw;
	}
	std::cerr << "Daemon '" << name_ << "' spawned, config: " << config << std::endl;
}

/* ---- requestStop：置停止标志（槽已交出/已释放则无事可做）----
 * 审计 H-3 防线在 2.4 模型下的形态：弃管即成员置空，本地强引用副本
 * 保证检查与上锁之间槽不可能被释放。 */
void DaemonRunner::requestStop() {
	std::shared_ptr<DaemonSlot> slot = std::atomic_load(&slot_);
	if (slot == nullptr) { return; }
	daemon_request_stop(slot.get());
}

/* ---- waitUntil 辅助函数（阶段 1 拆分）---- */

/* 处理未 spawn 的守护线程：直接释放槽 */
static bool handleNotSpawned(const std::string& name,
		std::shared_ptr<DaemonSlot>& slot) {
	std::cerr << "Daemon '" << name << "' was never spawned, releasing slot directly" << std::endl;
	slot.reset();
	return true;	/* 线程从未存在，本地副本是唯一剩余所有者，出作用域即释放 */
}

/* 等待守护线程退出并回收 */
static bool joinUntilDeadline(const std::string& name, std::future<int64_t>& fut,
		const std::chrono::steady_clock::time_point& deadline,
		std::shared_ptr<DaemonSlot>& slot) {
	std::future_status st = fut.wait_until(deadline);
	if (st == std::future_status::ready) {
		int64_t n = fut.get();
		std::cerr << "Daemon '" << name << "' joined, total publishes=" << n << std::endl;
		slot.reset();
		return true;	/* 线程已退场并交出副本，本地副本是最后所有者 */
	}
	return false;
}

/* 处理弃管：灭火 + 交出槽引用（BQ-2 重排后由 finishTeardown 的宽限耗尽路径
 * 调用，调用时槽仍在手）。先置 quiesce 再 reset——顺序即保证：此后该守护
 * 的 HAL 传输在进内核前被拒，与主线程即将开始的硬件销毁不再并发。 */
static void handleAbandon(const std::string& name,
		const std::chrono::steady_clock::time_point& waitStart,
		std::shared_ptr<DaemonSlot>& slot) {
	g_abandonedDaemons.fetch_add(1);	/* N-7：进程退出前统一告警 */
	daemon_quiesce(slot.get());
	/* 等待时长按实际耗时打印（从停机序列起点算，含 join 超时与宽限两段） */
	const int64_t waitedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - waitStart).count();
	std::cerr << "Daemon '" << name << "' not exited within " << waitedMs
		<< "ms, abandoning slot and quiescing its bus access"
		<< " (HAL will refuse further transfers; an in-flight call may"
		<< " still touch the bus once)" << std::endl;
	slot.reset();
}

/* ---- requestStopAndWait：置停止 + 等到 deadline（不弃管）----
 * D1：未 spawn（build 中途失败）的守护 promise 永不 set——跳过等待直接释放槽。
 * 2.4 的弃管语义挪到 finishTeardown：deadline 内未退场只返回 false，槽保持在
 * 手——灭火位必须在弃管前置上，而弃管后主线程再无槽引用可写。
 * 幂等：槽已交出即返回 true。 */
bool DaemonRunner::requestStopAndWait(
		const std::chrono::steady_clock::time_point& deadline) {
	std::shared_ptr<DaemonSlot> slot = std::atomic_load(&slot_);
	/* 已释放（重复销毁）或已弃管（重复等待）——无事可做 */
	if (slot == nullptr) { return true; }
	daemon_request_stop(slot.get());

	if (!spawned_.load()) {
		bool result = handleNotSpawned(name_, slot);
		std::atomic_store(&slot_, slot);
		return result;
	}

	if (fut_.valid()) {
		bool joined = joinUntilDeadline(name_, fut_, deadline, slot);
		std::atomic_store(&slot_, slot);
		return joined;
	}

	std::atomic_store(&slot_, std::shared_ptr<DaemonSlot>());
	return true;
}

/* ---- finishTeardown：宽限 →（仍未退场）灭火 + 弃管（BQ-2）----
 * 只等 future、按需持锁灭火后弃管；graceMs<=0 = 不给宽限（单守护 destroy
 * 路径）。宽限内退场则消费 future（线程侧 set_value 的 try/catch 容忍
 * 「已消费」，两条路径都安全），其 daemon_cleanup 已在退场前照常执行。
 * 幂等：槽已交出（此前已收尾/弃管）直接返回 true。 */
bool DaemonRunner::finishTeardown(int64_t graceMs,
		const std::chrono::steady_clock::time_point& waitStart) {
	std::shared_ptr<DaemonSlot> slot = std::atomic_load(&slot_);
	if (slot == nullptr) { return true; }	/* 已退场收尾或已弃管 */

	if (spawned_.load() && fut_.valid() && graceMs > 0) {
		std::future_status st = fut_.wait_until(
			std::chrono::steady_clock::now() + std::chrono::milliseconds(graceMs));
		if (st == std::future_status::ready) {
			int64_t n = fut_.get();
			std::cerr << "Daemon '" << name_ << "' exited within teardown grace"
				<< ", total publishes=" << n << std::endl;
			slot.reset();	/* 本地副本即最后所有者（线程已退场），出作用域释放 */
			std::atomic_store(&slot_, slot);
			return true;
		}
	}
	if (spawned_.load() && fut_.valid()) {
		handleAbandon(name_, waitStart, slot);
		quiesced_.store(true, std::memory_order_release);
		std::atomic_store(&slot_, slot);
		return false;
	}
	/* 未 spawn 的防御分支：requestStopAndWait 已处理过，重复调用到此只收尾 */
	handleNotSpawned(name_, slot);
	std::atomic_store(&slot_, slot);
	return true;
}

void DaemonRunner::waitForExit() {
	const auto waitStart = std::chrono::steady_clock::now();
	/* 单守护路径：joinTimeout 等待，不给宽限（宽限是断电屏障的全局预算） */
	requestStopAndWait(waitStart + std::chrono::milliseconds(joinTimeoutMs_));
	finishTeardown(0, waitStart);
}

/* ---- readSample：主线程加锁读采样值 → JSON（v0..vN 标量键 + values 数组）---- */
Json DaemonRunner::readSample() {
	/* 2.4：加载本地强引用副本——本次读取期间槽由副本保证存活。原「play/
	 * readSample 与 destroy 同线程顺序」契约（审计中-2）下的 TOCTOU 缺口
	 * （load 到槽之后 destroy 才置空）升格为代码保证：即便 destroy 并发
	 * 置空成员，本副本仍持引用，不存在悬垂解引用。 */
	std::shared_ptr<DaemonSlot> slot = std::atomic_load(&slot_);
	if (slot == nullptr) {
		return makeErrResult("daemon slot already released");
	}
	Json ret = JsonObject();
	Json arr = JsonArray();
	pthread_mutex_lock(mutexOf(slot.get()));
	int32_t nvals = slot->nvals;
	int32_t count = slot->count;
	int32_t slotStatus = slot->status;
	int32_t nv = nvals;
	if (nv > slot->capacity) { nv = slot->capacity; }	/* ABI v2：按本槽容量截断 */
	for (int32_t k = 0; k < nv; ++k) {
		double v = slot->values[k];
		arr.add(JsonFloat(v));
		ret.put("v" + std::to_string(k), JsonFloat(v));
	}
	pthread_mutex_unlock(mutexOf(slot.get()));
	/* N-27：守护 setup 失败绝不伪装成采样值。旧实现把失败码（-2/-8/-9…）发进
	 * v0，下游 $ 引用无从甄别——配置错误会被当作温度做闭环，只有 count 停滞
	 * 这种间接迹象。现在 status ≠ 0 直接抛错：这是**永久性**失败（守护不会
	 * 自愈），必须在动作链上响亮中止，而不是让消费方报告「某字段缺失」这类
	 * 间接症状（Monitor 只会说 no daemon value (v0 missing)）。
	 * 与「尚未出首帧」区分：那是瞬时状态，由消费方（Monitor/Ema/Kalman）
	 * 自己按 ERR 契约表达，不在此抛。 */
	if (slotStatus != 0) {
		throw std::runtime_error("daemon setup failed (slot status "
			+ std::to_string(slotStatus) + "); no samples are published"
			+ " — the failure code and reason are in the daemon log");
	}
	ret.put("status", JsonString("OK"));
	ret.put("count", JsonInt(count));
	ret.put("nvals", JsonInt(nvals));
	ret.put("values", std::move(arr));
	logD([count, nvals] { return "Daemon play: count=" + std::to_string(count) + " nvals=" + std::to_string(nvals); });
	return ret;
}

/* ---- 配置校验与装配（parseInterval / resolveDaemonChunk / firstExistingModule /
 * checkDaemon* / assembleDaemonConfig / allocateSlot / MtVars_Daemon::Factory 及
 * play/build/destroy）已整体迁至 daemonconf.cpp（2026-10-01 TU 拆分）：
 * 本 TU 只剩共享槽原语与 DaemonRunner 线程机。 */

} // namespace bot
