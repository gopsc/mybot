/* test_robot_lifecycle.cpp —— 生命周期与硬件独占域
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）：析构兜底断电（审计 P7）、
 * 断电屏障顺序（审计 P2）、single_consumer 硬件独占（含守护行旁路）三段。
 * 析构兜底的可观测证据由 test/cpp/LifetimeProbe.lua 落成文件痕迹提供。
 */
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>	/* std::cerr 重定向：此前靠 util_env.hpp 传导 */
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "daemonvar.hpp"
#include "hw_factory.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "robot_fixtures.hpp"

namespace fs = std::filesystem;
using fx::TempDir;

using fx::ModulePathGuard;
using rfx::markerOf;
using rfx::probeSql;
/* ==================== 析构兜底断电（审计 P7 / 阶段 1.4）====================
 * 断电此前只是 main.cpp:203 的一个调用点义务：任何漏掉它的新退出路径（早退
 * return、catch 之外的意外）都会把执行器留在最后指令位置、I2C 从设备滞留中间态。
 * 现在它是生命周期不变式——~RobotStruct 补一次，且幂等。
 * 可观测证据由 test/cpp/LifetimeProbe.lua 提供：destroy 每被调用一次就往
 * data.path 追加 1 字节 'x'，于是「调用次数 == 文件长度」，两条性质都能直接断言。 */


/* build 期的停止响应（2026-09-21 第七轮审计）：信号处理器只置标志
 * （async-signal-safe），真正的响应点在各处循环里——而 active() 的逐件 build
 * 循环此前**不查标志**。后果是：多驱动上电（每个 build 内含真机延时）期间
 * 第一次 Ctrl-C 毫无可见效果，运维必然再按一次，而第二次是 `SIG_DFL + raise`
 * 强杀 ⇒ 已 build 成功的器件原地带电、deactivate 一行不执行。 */
TH_TEST(robot_lifecycle_state_tracks_load_active_and_inactive) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifecycle-state");
	bot::MemoryReader sr(probeSql(tmp.path() / "destroyed"));
	bot::RobotStruct robot(sr);
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Loaded);
	robot.active();
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Active);
	robot.deactivate();
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Inactive);
	robot.deactivate();
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Inactive);
}

/* run() 的生命周期判据（阶段 3）：
 *   Loaded 放行——此时注册表为空，run() 只做解析与派发前校验，任何真机派发
 *   都报到「not defined in your hardware declaration section」（离线预演，非缺陷）；
 *   Active 放行——探针已注册，p0.probe 派发真实走完（不抛）；
 *   Inactive 拒绝——器件对象已 destroy，派发会落到死亡句柄。 */
TH_TEST(robot_run_allowed_before_activation_but_rejected_after_teardown) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifecycle-run");
	bot::MemoryReader sr(probeSql(tmp.path() / "destroyed"));
	bot::RobotStruct robot(sr);

	bot::MemoryReader before("@Action\np0.probe;\n  1;\n@\n");
	TH_CHECK_THROWS_MSG(std::exception, "not defined in your hardware declaration section",
		robot.run(before));

	robot.active();
	bot::MemoryReader during("@Action\np0.probe;\n  1;\n@\n");
	robot.run(during);	/* Active：探针已注册，派发成功则此处不抛 */

	robot.deactivate();
	bot::MemoryReader after("@Action\np0.probe;\n  1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "已断电", robot.run(after));
}

TH_TEST(robot_active_aborts_when_stop_requested_before_build) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("stop-build");
	const fs::path marker = tmp.path() / "destroyed";

	/* 标志必须复位，否则污染后续所有用例（含 agent 侧那些查 stopRequested 的） */
	struct StopGuard {
		StopGuard() { bot::stopRequested().store(true); }
		~StopGuard() { bot::stopRequested().store(false); }
	} stopGuard;

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	TH_CHECK_THROWS_MSG(std::runtime_error, "上电被中断", robot.active());

	/* 中止后清理链照常可走：deactivate 不得抛出，且幂等（第二次直接返回）。
	 * 未 build 的器件 destroy 只计入告警，这是本仓既有口径（见 active() 注释）。 */
	robot.deactivate();
	robot.deactivate();
}

TH_TEST(destructor_deactivates_when_caller_forgot) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifetime-forgot");
	const fs::path marker = tmp.path() / "destroyed";
	{
		bot::MemoryReader sr(probeSql(marker));
		bot::RobotStruct robot(sr);
		robot.active();
		/* 故意不调用 deactivate：作用域结束即析构，兜底必须把 destroy 跑到 */
	}
	TH_CHECK(markerOf(marker) == "D");
}

TH_TEST(destructor_does_not_destroy_twice_after_explicit_deactivate) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifetime-idempotent");
	const fs::path marker = tmp.path() / "destroyed";
	{
		bot::MemoryReader sr(probeSql(marker));
		bot::RobotStruct robot(sr);
		robot.active();
		robot.deactivate();	/* main 的正常路径 */
	}
	/* 仍是 1 字节：析构认得「已断电」，没有重复 destroy（重复去初始化对
	 * 真器件不是无害的——已关断的器件再写寄存器可能落在无效状态机上） */
	TH_CHECK(markerOf(marker) == "D");
}

TH_TEST(destructor_is_a_noop_when_never_activated) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifetime-inactive");
	const fs::path marker = tmp.path() / "destroyed";
	{
		bot::MemoryReader sr(probeSql(marker));
		bot::RobotStruct robot(sr);
		/* 只解析结构、从未上电（如 --agent 的配置校验失败早退）：无事可做 */
	}
	TH_CHECK(markerOf(marker).empty());
}

/* ---- 断电屏障的顺序回归（审计 P2 / 阶段 1.1）----
 * Daemon 表**声明在探针之前**，于是 build 序 = 守护、探针，逆序 destroy =
 * 探针先、守护后——正是「执行器已去初始化、守护还在拍」的那个形状。
 * 守护每拍追加 'T'（LifetimeTick.lua），探针 destroy 追加 'D'（LifetimeProbe.lua），
 * 两者写同一文件，于是末字节就是顺序判据：
 *   屏障在位 → 守护先退场，之后才 destroy → 末字节 'D'
 *   屏障缺失 → destroy 之后守护继续拍（join 延后到它自己的 destroy）→ 末字节 'T'
 * 另断言 trace 里确实有 'T'：守护根本没跑起来的话，末字节 'D' 是假绿。 */
TH_TEST(deactivate_joins_daemons_before_hardware_deinit) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("lifetime-barrier");
	const fs::path marker = tmp.path() / "order";
	TH_CHECK(fs::exists(tmp.path()));
	::setenv("BOT4CJ_LIFETIME_MARK", marker.c_str(), 1);
	{
		bot::MemoryReader sr(
			"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
			"INSERT INTO Daemon (name, chunk, interval) VALUES ('d0', 'LifetimeTick.lua', '10');\n"
			+ probeSql(marker));
		bot::RobotStruct robot(sr);
		robot.active();
		/* 时序（chunk 每拍 = 睡 150ms 后写 'T'，interval=10ms）：
		 * t≈150ms 第一拍写 T；t≈160ms 第二拍开始睡；t=220ms 这里发停机请求，
		 * 第二拍仍在途，它的 'T' 要到 t≈310ms 才落地。
		 * 有屏障 → 先等到 t≈310ms（T）、join 成功，再 destroy 写 'D' → 末字节 D；
		 * 无屏障 → destroy 立刻写 'D'，t≈310ms 又来一个 'T' → 末字节 T。 */
		std::this_thread::sleep_for(std::chrono::milliseconds(220));
		robot.deactivate();
	}
	::unsetenv("BOT4CJ_LIFETIME_MARK");

	const std::string trace = markerOf(marker);
	TH_CHECK(trace.find('T') != std::string::npos);
	TH_CHECK(!trace.empty() && trace.back() == 'D');
}

/* ==================== F-2（2026-09-22，原 TD-2 剩余部分）：daemon-grace-ms 参数化 ====================
 * 借用 test_daemon.cpp 的慢拍夹具（3s/拍 > joinTimeout=2s → 必走弃管路径）。
 * daemon 弃管后的二段宽限由 RobotStruct::deactivateGraceMs_ 控制（原写死
 * kMaxGraceMs=30000），本用例钉住：(1) setter 语义正确传递到 deactivate()；
 * (2) 用小宽限值（100ms）快速走完二段等待而不卡死测试；(3) stderr 可观测。 */

TH_TEST(robot_daemon_grace_ms_setter_affects_deactivate_barrier) {
	/* EnvVar 守卫：析构自动恢复——BOT4CJ_MODULE_PATH 会影响后续用例的沙箱
	 * dofile 白名单（见 test_luaend.cpp），必须离开作用域即还原，不能像
	 * test_daemon.cpp 那样裸 setenv（那是既有技术债，此处不重复）。 */
	fx::EnvVar modPath("BOT4CJ_MODULE_PATH", ".tmp");
	/* 从 test_daemon.cpp::writeSlowTickChunk 复制慢拍夹具
	 * （3s/拍，interval=10ms，joinTimeout=max(10*5,2000)=2000ms） */
	std::ofstream out(".tmp/test_daemon_grace_slow_tick.lua", std::ios::binary | std::ios::trunc);
	out << "local ffi = require(\"ffi\")\n"
	    << "ffi.cdef(\"int usleep(unsigned int usec);\")\n"
	    << "function daemon_tick()\n"
	    << "  ffi.C.usleep(3000000)\n"
	    << "  return 1\n"
	    << "end\n";
	out.close();

	const char* sql =
		"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
		"INSERT INTO Daemon (name, chunk, interval) "
		"VALUES ('d1', 'test_daemon_grace_slow_tick.lua', '10');\n";

	bot::MemoryReader sr(sql);
	bot::RobotStruct robot(sr);

	/* F-2：在 active() 之前设置宽限——100ms 足够短，测试秒级完成；
	 * 若未生效，deactivate() 仍用 30000ms 缺省值，整个用例会卡 30s */
	robot.setDeactivateGraceMs(100);

	robot.active();
	/* 让守护进慢拍（200ms < 3s），保证 destroy 必走 abandoned 路径 */
	std::this_thread::sleep_for(std::chrono::milliseconds(200));

	/* 捕获 stderr：二段日志应点名宽限 100ms（不是 30000），且很快完成 */
	std::ostringstream buf;
	std::streambuf* old = std::cerr.rdbuf(buf.rdbuf());
	auto start = std::chrono::steady_clock::now();

	robot.deactivate();

	auto elapsed = std::chrono::steady_clock::now() - start;
	std::cerr.rdbuf(old);

	/* 断言 (1)：耗时远小于 30s，证明新值接管了（容差 5s，覆盖 CI 抖动） */
	TH_CHECK(elapsed < std::chrono::seconds(5));
	/* 断言 (2)：stderr 点名宽限 100（不是 30000），证明值传递到了 deactivate()。
	 * 文案格式见 robot.cpp："granting " << graceMs << "ms grace"（数字与
	 * "ms" 之间无空格）。 */
	std::string log = buf.str();
	TH_CHECK(log.find("granting 100ms grace") != std::string::npos);
	TH_CHECK(log.find("30000") == std::string::npos);
}

/* ==================== 单消费者判据（审计 1.3）====================
 * 只跑到**装配期**（ScriptLoader::readSQL + HwFactory::createHardVars），不调
 * build()——判据本就在任何资源申请之前，故这三条用例与主机有没有 /dev/i2c-1
 * 完全无关，连真机夹具（as7262.sql，守门的 E2E 段不执行它）也能确定性守门。
 * 三类形态各钉一条，重点是第三条：防止判据被顺手放宽成「一律单消费者」
 * ——那会打中 robots/test/ 下 20 个刻意写成「直连 + 守护同址」的夹具。 */
namespace {

std::string readFileAll(const std::string& path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) { throw std::runtime_error("夹具不可读: " + path); }
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

/* 装配（不 build）：返回空串表示成功，否则返回异常文本 */
std::string assembleSql(const std::string& sql) {
	try {
		std::deque<mt::MatrixObject> matrices;
		bot::MemoryReader sr(sql);
		bot::ScriptLoader::readSQL(sr, matrices);
		bot::HwRegistry registry;
		bot::DaemonRegistry daemons;
		bot::MetaRegistry metas;
		bot::HwFactory factory(registry, daemons, metas);
		factory.createHardVars(matrices);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

std::string assembleFile(const std::string& path) { return assembleSql(readFileAll(path)); }

} // namespace

TH_TEST(single_consumer_rejects_two_consumers_of_a_declaring_driver) {
	ModulePathGuard guard("modules:test/cpp");
	const std::string err = assembleFile("robots/test/single_consumer.sql");
	TH_CHECK(err.find("two concurrent consumers") != std::string::npos);
	/* 报错必须点名双方，否则用户不知道该删哪一个 */
	TH_CHECK(err.find("spec0") != std::string::npos);
	TH_CHECK(err.find("spec-d0") != std::string::npos);
}

TH_TEST(single_consumer_accepts_the_five_real_hardware_fixtures) {
	ModulePathGuard guard("modules:test/cpp");
	/* 五个声明者驱动的真机夹具：直连变量走真器件、守护走 proto=virt（内存仿真
	 * 不算真器件消费者），故各自只有一个真消费者，装配必须通过。
	 * 这几条同时钉住"改回 proto=i2c 就该报错"的正向侧——夹具被改回去时，
	 * 这里会立刻红，而不是等到有人在真机上读到错数据。 */
	for (const char* f : {"as7262", "ms5611", "as3935", "vl53l0x", "vl53l4cd"}) {
		const std::string path = std::string("robots/test/") + f + ".sql";
		const std::string err = assembleFile(path);
		TH_CHECK_MSG(err.empty(), path + " 装配失败: " + err);
	}
}

TH_TEST(single_consumer_rejects_two_direct_vars_on_same_address) {
	ModulePathGuard guard("modules:test/cpp");
	/* 直连 vs 直连（不涉及守护）：同一声明者驱动、同总线同地址的两行 */
	const std::string err = assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE MS5611 (name String, I2C String, address String);\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro0', '$i2c-1', '0x77');\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro1', '$i2c-1', '0x77');\n");
	TH_CHECK(err.find("two concurrent consumers") != std::string::npos);
	TH_CHECK(err.find("baro0") != std::string::npos);
	TH_CHECK(err.find("baro1") != std::string::npos);
}

TH_TEST(single_consumer_allows_same_driver_on_different_addresses) {
	ModulePathGuard guard("modules:test/cpp");
	/* 判据键里必须含地址：同型号两颗器件（0x76 / 0x77）是两个独立消费者，
	 * 不该被一刀切拦下——否则"按驱动名判重"这种错实现也能通过前面几条用例。 */
	TH_CHECK(assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE MS5611 (name String, I2C String, address String);\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro0', '$i2c-1', '0x76');\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro1', '$i2c-1', '0x77');\n").empty());
	/* 地址写法不同（十六进制 / 十进制）但指向同一颗器件，仍须判重 */
	TH_CHECK(!assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE MS5611 (name String, I2C String, address String);\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro0', '$i2c-1', '0x77');\n"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro1', '$i2c-1', '119');\n").empty());
}

TH_TEST(single_consumer_allows_dual_consumers_of_ordinary_drivers) {
	ModulePathGuard guard("modules:test/cpp");
	/* ADS1115 未声明 SINGLE_CONSUMER：HAL 的每次访问是单次 I2C_RDWR 原子事务
	 * （指针写 + 数据读合并），直连变量 adc0 与守护 adc-d0 同为
	 * /dev/i2c-1 @ 0x48 也安全。这条钉住「判据只针对声明者」。 */
	TH_CHECK(assembleFile("robots/test/ads1115.sql").empty());
}

/* ---- 守护行的三条静默旁路（2026-09-21 第七轮审计）----
 * 旧实现把「缺列」当成「不参与判据」直接 continue，而守护侧对 proto/path 都有缺省、
 * 多器件守护的器件清单在 devices 列里 ⇒ 三种被 docs/daemon.md 认可的写法都绕过了
 * 判据，运行期却真的在总线上开了 fd。漏标 = 双消费者静默数据错乱，**无运行期症状**。 */

TH_TEST(single_consumer_rejects_daemon_row_that_omits_proto_and_path) {
	ModulePathGuard guard("modules:test/cpp");
	/* Daemon 行省略 proto 与 path —— 正是 docs/daemon.md 的最小写法
	 * （守护侧缺省 proto=i2c、path=/dev/i2c-1）。直连变量 spec0 在
	 * $i2c-1(/dev/i2c-1) @ 0x49，两者必须被判为同一颗器件。 */
	const std::string err = assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE AS7262 (name String, I2C String, address String);\n"
		"INSERT INTO AS7262 (name, I2C, address) VALUES ('spec0', '$i2c-1', '0x49');\n"
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Daemon (name String, chunk String, driver String, addr String,\n"
		"                     interval String, fields String);\n"
		"INSERT INTO Daemon (name, chunk, driver, addr, interval, fields)\n"
		"  VALUES ('spec-d0', 'lib/sensor_daemon.lua', 'AS7262', '0x49', '300', 'V|B');\n");
	TH_CHECK_MSG(err.find("two concurrent consumers") != std::string::npos,
		"省略 proto/path 的守护行仍须参与判重，实际: " + err);
	TH_CHECK(err.find("spec0") != std::string::npos);
	TH_CHECK(err.find("spec-d0") != std::string::npos);

	/* 对照：显式 proto=virt 仍须放行（内存仿真不碰真器件；五个真机夹具正是这么写的） */
	TH_CHECK_MSG(assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE AS7262 (name String, I2C String, address String);\n"
		"INSERT INTO AS7262 (name, I2C, address) VALUES ('spec0', '$i2c-1', '0x49');\n"
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Daemon (name String, chunk String, driver String, proto String,\n"
		"                     addr String, interval String, fields String);\n"
		"INSERT INTO Daemon (name, chunk, driver, proto, addr, interval, fields)\n"
		"  VALUES ('spec-d0', 'lib/sensor_daemon.lua', 'AS7262', 'virt', '0x49', '300', 'V|B');\n"
		).empty(), "proto=virt 的守护不该参与判据（否则无硬件夹具全线误报）");
}

TH_TEST(single_consumer_parses_multi_device_daemon_devices_column) {
	ModulePathGuard guard("modules:test/cpp");
	/* 多器件守护（chunk = lib/sensor_daemon_multi.lua）没有 driver/addr 列，
	 * 器件清单在 devices 列：`driver@addr@fields[@k=v...]`，以 '|' 分隔。 */
	const std::string err = assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE AS7262 (name String, I2C String, address String);\n"
		"INSERT INTO AS7262 (name, I2C, address) VALUES ('spec0', '$i2c-1', '0x49');\n"
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Daemon (name String, chunk String, proto String, path String,\n"
		"                     interval String, devices String);\n"
		"INSERT INTO Daemon (name, chunk, proto, path, interval, devices)\n"
		"  VALUES ('multi-d0', 'lib/sensor_daemon_multi.lua', 'i2c', '/dev/i2c-1', '300',\n"
		"          'BME280@0x76@t,h,p|AS7262@0x49@V,B');\n");
	TH_CHECK_MSG(err.find("two concurrent consumers") != std::string::npos,
		"devices 列里的声明者驱动（第 2 个 spec）必须被登记，实际: " + err);
	/* 定位串要点名到是哪一个 spec，否则用户不知道清单里哪一颗撞了 */
	TH_CHECK_MSG(err.find("devices[2]") != std::string::npos, "应点名 spec 下标，实际: " + err);
	TH_CHECK(err.find("AS7262") != std::string::npos);
	TH_CHECK(err.find("multi-d0") != std::string::npos);

	/* 对照：devices 里全是未声明者驱动 ⇒ 直连 + 守护双消费者照常放行 */
	TH_CHECK_MSG(assembleSql(
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');\n"
		"CREATE TABLE ADS1115 (name String, I2C String, address String);\n"
		"INSERT INTO ADS1115 (name, I2C, address) VALUES ('adc0', '$i2c-1', '0x48');\n"
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Daemon (name String, chunk String, proto String, path String,\n"
		"                     interval String, devices String);\n"
		"INSERT INTO Daemon (name, chunk, proto, path, interval, devices)\n"
		"  VALUES ('multi-d0', 'lib/sensor_daemon_multi.lua', 'i2c', '/dev/i2c-1', '300',\n"
		"          'ADS1115@0x48@v');\n").empty(),
		"未声明者驱动的双消费者不该被拦（判据只针对声明者）");
}

TH_TEST(daemon_defaults_match_lua_source) {
	/* 两侧钉住：C++ 判据用的守护缺省值必须逐字出现在 sensor_daemon.lua 的缺省
	 * 表达式里。任一侧漂移都会红——这类漂移**没有运行期症状**，只会让判据静默
	 * 漏判，所以只能靠读源比对（不是在两处各手抄一遍就算数）。 */
	const std::string lua = readFileAll("modules/lib/sensor_daemon.lua");
	TH_CHECK_MSG(!lua.empty(), "读不到 modules/lib/sensor_daemon.lua");
	const std::string protoExpr =
		std::string("cfg.proto or \"") + bot::HwFactory::kDaemonDefaultProto + "\"";
	TH_CHECK_MSG(lua.find(protoExpr) != std::string::npos,
		"Lua 侧 proto 缺省应与 C++ 常量一致（找 '" + protoExpr + "'）");
	const std::string pathExpr = std::string("proto == \"spi\" and \"")
		+ bot::HwFactory::kDaemonDefaultPathSpi + "\" or \""
		+ bot::HwFactory::kDaemonDefaultPathI2c + "\"";
	TH_CHECK_MSG(lua.find(pathExpr) != std::string::npos,
		"Lua 侧 path 缺省应与 C++ 常量一致（找 '" + pathExpr + "'）");
}
