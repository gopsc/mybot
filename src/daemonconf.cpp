/* daemonconf.cpp —— @Daemon 表的配置校验与装配（拆自 daemonvar.cpp，2026-10-01）
 * 内容：chunk 路径寻址（issue #19 多路径）、interval 解析、DAEMON_CONFIG 的
 * 加载期 schema 校验（proto/fields/sign，E2/N-27）、配置串组装、共享槽分配、
 * MtVars_Daemon::Factory 与 play/build/destroy 直通。线程机（DaemonRunner 的
 * 逐拍循环与生命周期）留在 daemonvar.cpp；跨 TU 接缝（mutexOf/releaseSlot）
 * 见 daemonvar.hpp。 */

#include "daemonconf.hpp"
#include "daemon_registry.hpp"
#include "daemonvar.hpp"

#include <cstdlib>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "debug_log.hpp"	/* logD */
#include "util_num.hpp"		/* parseLongStrict / IntParse */
#include "util_path.hpp"	/* modulePaths / findExistingModule / splitModulePaths */
#include "util_str.hpp"		/* concatMsg */

namespace bot {

/* ---- issue #19：多模块路径按序查找第一个存在的文件 ----
 * 全部不存在返回最后一个路径拼接（保持原有"文件不存在"加载报错语义）。
 * N-19：':' 分段/去空/剥尾斜杠统一走 util 的 splitModulePaths。
 * 阶段 2：逐段探测本身上收到 util::findExistingModule（与 hw_factory、
 * Lua 侧 mpath.resolve 共用一条规则）。 */
std::string firstExistingModule(const std::string& paths, const std::string& rel) {
	if (auto found = findExistingModule(paths, rel)) { return *found; }
	const std::vector<std::string> ps = splitModulePaths(paths);
	return (ps.empty() ? paths : ps.back()) + "/" + rel;
}

std::string resolveDaemonChunk(const std::string& chunk, const std::string& modulePath) {
	if (chunk.rfind('/', 0) == 0) { return chunk; }
	if (chunk.rfind(modulePath + "/", 0) == 0) { return chunk; }
	/* 阶段 5：旧写法（"modules/..."，不带 "./"）兼容分支经全仓 robots/、
	 * docs/ 核查无依赖，已删除——这类 chunk 现走 firstExistingModule，
	 * 按普通相对 chunk 在模块路径下解析。 */
	return firstExistingModule(modulePath, chunk);
}

/* ---- interval 解析与校验（≤0 会空转占满 CPU，显式报错）----
 * C9：解析经 util 的 parseLongStrict（NOT_INT/OVERFLOW 分型），并钳制合理上限——
 * join 超时按 interval*5 计算，钳制后乘法不溢出。 */
int64_t parseInterval(const std::string& iv, const std::string& name,
		const std::string& tabName, int64_t row) {
	auto parsed_ = parseLongStrict(iv);
	if (parsed_.first == IntParse::NOT_INT) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'interval' value '" + iv +
			"' is not a valid integer (in table '" + tabName + "', row " + std::to_string(row) + ").");
	}
	if (parsed_.first == IntParse::OVERFLOW || parsed_.second < 0) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'interval' value '" + iv +
			"' is out of range (in table '" + tabName + "', row " + std::to_string(row) + ").");
	}
	long long parsed = parsed_.second;
	if (parsed == 0) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'interval' must be > 0 ms, got " + std::to_string(parsed) +
			" (in table '" + tabName + "', row " + std::to_string(row) +
			"). interval <= 0 causes a busy-loop that pins a CPU core.");
	}
	constexpr int64_t kMaxIntervalMs = 3600000;	/* 1 小时：合理上限，保证 joinTimeout=interval*5 不溢出 */
	if (parsed > kMaxIntervalMs) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'interval' " + std::to_string(parsed) +
			"ms exceeds the maximum " + std::to_string(kMaxIntervalMs) +
			"ms (in table '" + tabName + "', row " + std::to_string(row) + ").");
	}
	return parsed;
}

/* ---- DAEMON_CONFIG schema 校验（E2 / N-27 尾）----
 * DAEMON_CONFIG 最终由 chunk 解释，但**非法值必须在结构脚本加载期就报错**：
 * 等到守护线程 setup 才失败，调用方只拿得到「守护启动失败 + status 码」，
 * 不知道是哪张表、哪一行、哪个键；而拼错的 proto 此前会静默按 i2c 走、
 * 非法的 fields 模式会静默当浮点透传——都是「跑起来了但结果不对」的隐蔽故障。
 * 只校验框架列（proto/fields/sign，语义见 docs/daemon.md）；其余任意键是驱动
 * 的 build 参数（channel/pga/rshunt/osr…），框架不得拦截。
 * 语法以 modules/lib/sensor_daemon.lua 的解析为准，两处规则改动须同步。
 * 矩阵空占位符 "-" 在 assembleDaemonConfig 里**拼串之前**就被跳过（既不进
 * DAEMON_CONFIG、也不进这里的校验）——否则 Lua 侧会拿到字面值 "-"（truthy），
 * `or 缺省` 分支不生效，校验通过而语义走样。空串不在此列：它照旧进校验，
 * interval 为空串仍按「需要整数」报错，不静默落回缺省。 */
/* proto 白名单：i2c（缺省）/ spi / uart / virt（virt=无硬件仿真）。
 * 未知值旧实现静默落进 i2c 分支——拼错 "i2" 会真去开 I2C 总线。 */
static void checkDaemonProto(const std::string& v, const std::string& name,
		const std::string& tabName, int64_t row) {
	if (v == "i2c" || v == "spi" || v == "uart" || v == "virt") { return; }
	throw IllegalArgumentException(
		"Daemon '" + name + "': column 'proto' value '" + v +
		"' is not a supported bus (expected i2c|spi|uart|virt) (in table '" + tabName +
		"', row " + std::to_string(row) + ").");
}

/* sign：符号扩展位宽（16 = 16 位补码）。非数值此前被 tonumber 折成 nil，
 * 于是 sign=16x 这类拼错会让符号扩展静默失效（读数全是无符号大数）。 */
/* maxvals：本守护槽容量（ABI v2，1..SLOT_CAPACITY_LIMIT，缺省 SLOT_MAXVALS=64）。
 * 非法值在加载期响亮拒绝——容量是槽分配的输入，静默回落缺省会让「以为配了
 * 128 字段」的行在 fields 校验上误报，两处判据必须看到同一个数。 */
static int32_t checkDaemonMaxvals(const std::string& v, const std::string& name,
		const std::string& tabName, int64_t row) {
	auto parsed_ = parseLongStrict(v);
	if (parsed_.first != IntParse::OK || parsed_.second < 1
			|| parsed_.second > SLOT_CAPACITY_LIMIT) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'maxvals' value '" + v +
			"' is out of range (expected an integer between 1 and " +
			std::to_string(SLOT_CAPACITY_LIMIT) + ") (in table '" + tabName +
			"', row " + std::to_string(row) + ").");
	}
	return static_cast<int32_t>(parsed_.second);
}

/* kind：sim_sensor_daemon 的采样种类白名单（imu|odom，2026-10-16）。加载期
 * 校验——拼错（如 "immu"）落进 chunk 的 setup 失败码要等守护线程起拍才看到，
 * 且报错只有 status -2 一个间接症状，与 proto/fields 的加载期校验同一动机。 */
static void checkDaemonKind(const std::string& v, const std::string& name,
		const std::string& tabName, int64_t row) {
	if (v == "imu" || v == "odom") { return; }
	throw IllegalArgumentException(
		"Daemon '" + name + "': column 'kind' value '" + v +
		"' is not supported (expected imu|odom) (in table '" + tabName +
		"', row " + std::to_string(row) + ").");
}

static void checkDaemonSign(const std::string& v, const std::string& name,
		const std::string& tabName, int64_t row) {
	if (parseLongStrict(v).first == IntParse::OK) { return; }
	throw IllegalArgumentException(
		"Daemon '" + name + "': column 'sign' value '" + v +
		"' is not a valid integer (expected a bit width such as 16) (in table '" + tabName +
		"', row " + std::to_string(row) + ").");
}

static bool daemonFieldModeChar(char c) {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/* fields 语法：<名>[:<模式>]，分隔符 ',' 或 '|'，模式 ∈ 缺省（跟随全局 sign）/
 * f / float / s16。空项（重复或首尾分隔符）与未知模式都在此报错——旧实现把
 * 空项 print 后丢弃、把未知模式当浮点透传（语义被悄悄改写，且只落在守护日志里）。
 *
 * 审计 2026-09-20（中）：字段数必须 ≤ 本行槽容量。槽的采样数组按 maxvals 列
 * 分配（ABI v2，缺省 64），Lua 侧 P.publish 超出即**静默钳制**（pthread.lua），
 * C++ 侧 readSample 也按槽容量截断——于是超容量字段的 @Daemon 能通过全部
 * 加载期校验、正常启动、count 照常自增，而多余字段**永远拿不到值**，事后只
 * 表现为下游「某字段缺失」（Monitor 只会说 no daemon value (v0 missing)）这类
 * 间接症状。既然字段数在加载期就已知，就在这里响亮拒绝，而不是让它跑起来再
 * 静默丢数据。cap 是本行生效容量（maxvals 列解析结果，见 assembleDaemonConfig
 * 的两遍扫描）。 */
static void checkDaemonFields(const std::string& v, const std::string& name,
		const std::string& tabName, int64_t row, int32_t cap) {
	auto bad = [&](const std::string& why, const std::string& tok) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'fields' " + why + ": '" + tok + "' (in table '" +
			tabName + "', row " + std::to_string(row) + ").");
	};
	std::size_t pos = 0;
	int fieldCount = 0;
	while (pos <= v.size()) {
		std::size_t sep = v.find_first_of(",|", pos);
		std::string tok = v.substr(pos, (sep == std::string::npos ? v.size() : sep) - pos);
		if (tok.empty()) {
			bad("has an empty field name (check for doubled or leading/trailing separators)", v);
		}
		std::size_t colon = tok.find(':');
		std::string fname = (colon == std::string::npos) ? tok : tok.substr(0, colon);
		std::string mode = (colon == std::string::npos) ? std::string() : tok.substr(colon + 1);
		if (fname.empty()) { bad("has an empty field name", tok); }
		for (char c : mode) {
			if (!daemonFieldModeChar(c)) { bad("has a malformed field mode", tok); }
		}
		if (!(mode.empty() || mode == "f" || mode == "float" || mode == "s16")) {
			bad("has an unknown field mode ':" + mode + "' (expected :f, :float or :s16)", tok);
		}
		if (++fieldCount > cap) {
			throw IllegalArgumentException(
				concatMsg("Daemon '", name, "': column 'fields' declares ",
				std::to_string(fieldCount),
				" fields, which exceeds the shared-slot capacity of ",
				std::to_string(cap),
				(cap == SLOT_MAXVALS)
					? " (the default; raise this daemon's 'maxvals' column, hard limit "
					: " (this daemon's 'maxvals' column; raise it, hard limit ",
				std::to_string(SLOT_CAPACITY_LIMIT),
				") (in table '", tabName, "', row ", std::to_string(row),
				"). Extra fields would never be published —",
				" split the daemon or expose fewer fields."));
		}
		if (sep == std::string::npos) { break; }
		pos = sep + 1;
	}
}

/* ---- 配置串字符校验（审计 P4）----
 * DAEMON_CONFIG 是 "k=v;k=v" 串：Lua 侧按 gmatch("([^;=]+)=([^;]*)") 解析
 * （modules/lib/sensor_daemon.lua），注入用 lua_pushstring（C 字符串语义）。
 * 两种字符会让「加载期校验看到的」与「Lua 实际拿到的」不一致，必须拒：
 *   '\0'  pushstring 在此截断，其后**所有列**（含 proto/sign）静默消失，
 *         而 checkDaemonProto/Fields/Sign 跑在逐列原始串上，全部通过。
 *         NUL 能进到列值里：sqlparse 的引号态一律字面追加（'\0' 只在
 *         token 之外被当空白，见 src/sqlparse.cpp 的 blank 判据）。
 *   ';'   该值被提前截断；更糟的是若其后片段形如 `key=`，就会**注入/覆盖**
 *         守护真正理解的键（proto/path/addr/fields/sign…），而 schema 校验
 *         看的是原始列值，看不到这次注入。
 * '=' 不拒：键的模式是 [^;=]+（不含 '='）、值的模式是 [^;]*（可含 '='），
 * 故 "extra=a=b" 能原样往返，拒它会白伤合法驱动参数。
 * .sql 属可信域（会话期只允许 @Alias/@Vars），故定性为**静默误配置**而非
 * 远程边界失守；但必须早报——放过之后运行期的症状只有 "no daemon value"
 * 这类间接报错，看不出是配置串被截断了。
 * 注：robots/test/sqlquote.sql 是词法器契约夹具（引号值内的 ; 是字面数据），
 * 它的 ';' 字面值放在普通硬件表里而非 @Daemon 列——词法路径与表名无关，
 * 覆盖不减，而这里的语义约束得以保持严格。 */
static void checkDaemonValueChars(const std::string& colName, const std::string& v,
		const std::string& name, const std::string& tabName, int64_t row) {
	for (char c : v) {
		if (c != '\0' && c != ';') { continue; }
		throw IllegalArgumentException(
			concatMsg("Daemon '", name, "': column '", colName, "' value contains '",
			(c == '\0' ? std::string("\\0") : std::string(1, c)),
			"' which would corrupt the DAEMON_CONFIG (k=v;k=v) string",
			" (in table '", tabName, "', row ", std::to_string(row), ")."));
	}
}

/* ---- Factory 拆分（阶段 3）：配置串组装 + 加载期 schema 校验 ----
 * 两遍扫描：maxvals 决定本行槽容量，而 fields 的数量校验要用它——列序任意
 * （fields 可能先于 maxvals 出现），故先扫一遍取生效 maxvals（重复列后者胜，
 * 与 DAEMON_CONFIG 的 Lua 侧 gmatch 语义一致），再组装并逐列校验。 */
struct DaemonConfigParts {
	std::string configStr;
	int64_t intervalMs;
	int32_t capacity;
	std::string sources;	/* 非空 = 聚合守护（peer 清单原始串） */
};

static DaemonConfigParts assembleDaemonConfig(const mt::MatrixObject& defs, int64_t i,
		const std::string& name) {
	/* 第一遍：maxvals / sources 生效值（'-' 占位与 name/chunk 跳过，口径与主循环一致） */
	int32_t capAcc = SLOT_MAXVALS;
	std::string sourcesAcc;
	for (int64_t j = 0; j < static_cast<int64_t>(defs.cols()); ++j) {
		const std::string& colName = defs(0, j);
		const std::string& v = defs.inherited(i, j);
		if (colName == "maxvals") {
			if (v == "-") { continue; }
			capAcc = checkDaemonMaxvals(v, name, defs.getName(), i);
		} else if (colName == "sources") {
			if (v == "-") { continue; }
			sourcesAcc = v;
		}
	}
	/* 第二遍：组装配置串 + 框架列校验 */
	std::string cfgAcc;
	int64_t ivAcc = 5;
	for (int64_t j = 0; j < static_cast<int64_t>(defs.cols()); ++j) {
		const std::string& colName = defs(0, j);
		if (colName == "name" || colName == "chunk") { continue; }
		const std::string& v = defs.inherited(i, j);
		/* 先校验字符再拼串：配置串一旦拼好，NUL 之后的内容在 Lua 侧就不存在了，
		 * 那时再校验也看不出被截断（审计 P4）。 */
		checkDaemonValueChars(colName, v, name, defs.getName(), i);
		/* 空占位符 '-' **不下发**（2026-09-21 第七轮审计）：'-' 在本仓语义里就是
		 * "未提供"（docs/daemon.md 与下面几条 daemonConfigMissing 判据同一口径），
		 * 而原样拼进配置串会让 Lua 侧拿到字面值 "-"——它是 truthy，于是
		 * `cfg.sign or 缺省` 的 or 分支**不生效**：sign='-' 让符号扩展静默失效，
		 * 驱动 build 参数（pga/range 之类）'-' 经 tonumber 得 nil 后静默改用驱动
		 * 自身缺省。校验看到的与守护拿到的必须是同一份配置，否则"加载期校验通过"
		 * 这句话对 '-' 那一列根本不成立。 */
		if (v == "-") { continue; }
		cfgAcc += colName;
		cfgAcc += '=';
		cfgAcc += v;
		cfgAcc += ';';
		if (colName == "interval") {
			ivAcc = parseInterval(v, name, defs.getName(), i);
		} else if (colName == "proto") {
			checkDaemonProto(v, name, defs.getName(), i);
		} else if (colName == "fields") {
			checkDaemonFields(v, name, defs.getName(), i, capAcc);
		} else if (colName == "sign") {
			checkDaemonSign(v, name, defs.getName(), i);
		} else if (colName == "kind") {
			checkDaemonKind(v, name, defs.getName(), i);
		} else if (colName == "maxvals" || colName == "sources") {
			/* 第一遍已校验 / 收集；此处不重复（同一值二次校验只会复制报错） */
		}
	}
	return {cfgAcc, ivAcc, capAcc, sourcesAcc};
}

/* ---- Factory 拆分（阶段 3）：槽分配 ----
 * 分配并清零共享槽（ABI v2：96B 头 + capacity × 8B 的独立采样数组），初始化
 * mutex（任一 malloc 失败立即抛错拒绝空指针解引用，已分配的部分先释放）。
 * 2.4：槽所有权入 shared_ptr，删除器 = releaseSlot（mutex_destroy → free
 * values → free slot）——最后一个持有者（主线程 / 守护线程）退场时释放。 */
static std::shared_ptr<DaemonSlot> allocateSlot(const std::string& name, int32_t capacity) {
	DaemonSlot* raw = static_cast<DaemonSlot*>(std::calloc(1, SLOT_SIZE));
	double* vals = static_cast<double*>(std::calloc(static_cast<size_t>(capacity), sizeof(double)));
	if (raw == nullptr || vals == nullptr) {
		std::free(raw);
		std::free(vals);
		throw std::runtime_error("Daemon '" + name + "' failed to allocate shared slot ("
			+ std::to_string(SLOT_SIZE) + "B header + " + std::to_string(capacity)
			+ " doubles)");
	}
	raw->values = vals;
	raw->capacity = capacity;
	if (pthread_mutex_init(mutexOf(raw), nullptr) != 0) {
		std::free(raw->values);
		std::free(raw);
		throw std::runtime_error("Daemon '" + name + "' failed to initialize slot mutex");
	}
	return std::shared_ptr<DaemonSlot>(raw, releaseSlot);
}

/* ---- 多守护聚合：sources 列解析（2026-10-16，路线图阶段 2）----
 * sources = peer 守护名清单（'|' 或 ',' 分隔），宿主按名在登记表里解析出
 * 各 peer 的槽并以 DAEMON_PEER_SLOTS 注入聚合守护的 Lua 状态（消费方：
 * lib/sensor_aggregate.lua）。约束在**加载期**响亮拒绝，不留给运行期间接症状：
 *   - 名单为空 / 空令牌（重复或首尾分隔符）→ 拼写错误的配置不该静默聚合零路
 *   - 引用自己 → 一元环
 *   - 重名 → 拼接序歧义（v 下标映射不稳定）
 *   - 未知名（含「声明在自己之后」的守护）→ peer 必须已装配；「先声明后引用」
 *     与 $ 引用/controller 的既有顺序契约同族，且使环在结构上不可能
 *     （链式聚合 agg1(agg0(x)) 合法：agg0 在前）。 */
static std::vector<std::pair<std::string, std::shared_ptr<DaemonSlot>>>
resolveDaemonSources(DaemonRegistry& registry, const std::string& sources,
		const std::string& name, const std::string& tabName, int64_t row) {
	std::vector<std::pair<std::string, std::shared_ptr<DaemonSlot>>> peers;
	std::set<std::string> seen;
	std::size_t pos = 0;
	int count = 0;
	while (pos <= sources.size()) {
		std::size_t sep = sources.find_first_of(",|", pos);
		std::string tok = sources.substr(pos, (sep == std::string::npos ? sources.size() : sep) - pos);
		auto bad = [&](const std::string& why) {
			throw IllegalArgumentException(
				"Daemon '" + name + "': column 'sources' " + why + " (in table '" + tabName +
				"', row " + std::to_string(row) + ").");
		};
		if (tok.empty()) { bad("has an empty daemon name (check for doubled or leading/trailing separators)"); }
		if (tok == name) { bad("references itself '" + tok + "' (aggregation cycles are not allowed)"); }
		if (!seen.insert(tok).second) { bad("lists daemon '" + tok + "' more than once"); }
		std::shared_ptr<DaemonSlot> peerSlot;
		for (const auto& runner : registry.all()) {
			if (runner->name() == tok) { peerSlot = runner->slotShare(); break; }
		}
		if (peerSlot == nullptr) {
			bad("references unknown daemon '" + tok +
				"' (peers must be declared in earlier rows; forward references are not supported)");
		}
		peers.emplace_back(tok, std::move(peerSlot));
		++count;
		if (sep == std::string::npos) { break; }
		pos = sep + 1;
	}
	if (count == 0) {
		throw IllegalArgumentException(
			"Daemon '" + name + "': column 'sources' must list at least one daemon (in table '" +
			tabName + "', row " + std::to_string(row) + ").");
	}
	return peers;
}

/* ---- 守护硬件变量工厂 ---- */
std::unique_ptr<MtVars_Daemon> MtVars_Daemon::Factory(const mt::MatrixObject& defs, int64_t i,
		DaemonRegistry& registry) {
	int64_t idxName = defs.requireCol(0, "name", "Table");
	int64_t idxChunk = defs.requireCol(0, "chunk", "Table");
	std::string name = defs(i, idxName);
	const std::string& chunkRaw = defs.inherited(i, idxChunk);

	/* N-19：模块根目录统一走 util::modulePaths（空串也归一为缺省） */
	std::string modulePath = modulePaths();
	std::string chunkPath = resolveDaemonChunk(chunkRaw, modulePath);
	/* N-12：装配期进度走 logD（spawn/join 是运行期生命周期事件，保留 stderr） */
	logD([&] { return "Create a Daemon hard-Var: " + name + ", chunk: " + chunkPath; });

	auto parts = assembleDaemonConfig(defs, i, name);

	/* join 超时：interval 5 倍并保底 2000ms */
	int64_t joinTimeoutMs = (parts.intervalMs * 5 > 2000) ? parts.intervalMs * 5 : 2000;

	/* sources 列（聚合守护）：peer 必须已装配（先声明后引用），加载期解析 + 校验 */
	auto peers = parts.sources.empty()
		? std::vector<std::pair<std::string, std::shared_ptr<DaemonSlot>>>{}
		: resolveDaemonSources(registry, parts.sources, name, defs.getName(), i);

	auto runner = std::make_shared<DaemonRunner>(allocateSlot(name, parts.capacity),
		joinTimeoutMs, name);
	runner->setPeers(std::move(peers));
	runner->bindSelf(runner);	/* 线程捕获 self 保生命周期 */
	registry.hold(runner);

	return std::unique_ptr<MtVars_Daemon>(new MtVars_Daemon(
		std::move(runner), name, chunkPath, parts.configStr, parts.intervalMs));
}

/* ---- 守护硬件变量：play/build/destroy 直通守护事件（R-3）---- */
Json MtVars_Daemon::play(const Json&) {
	return runner_->readSample();
}

void MtVars_Daemon::build() {
	runner_->start(chunkPath_, configStr_, intervalMs_);
}

void MtVars_Daemon::destroy() {
	runner_->waitForExit();	/* 幂等：断电屏障已等到/已弃管则直接返回 */
}

} // namespace bot
