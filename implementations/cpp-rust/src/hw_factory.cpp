/* hw_factory.cpp —— 硬件装配（拆自 robot.cpp 阶段 R-1；ScriptLoader 的结构
 * SQL 事件语义 2026-09-25 起独立在 structure.cpp，本 TU 只剩 HwFactory：
 * 矩阵表 → 硬件变量（Alias/Vars/Lua/Daemon 分派 + controller/trigger 流引用
 * 装配校验）+ 单消费者/共享串口判据）。 */

#include "daemonconf.hpp"
#include "hw_factory.hpp"

/* 装配 Lua/标量变量，显式引入对应实现头（Daemon 的 MtVars_Daemon 声明已在
 * daemonconf.hpp，本 TU 不再直接点名 daemonvar.hpp 里的任何东西） */
#include "luavar.hpp"

#include "flowcolumn.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <map>
#include <set>
#include <utility>

#include "util_file.hpp"
#include "util_path.hpp"

namespace bot {

/* ==================== HwFactory：矩阵表 → 硬件变量 ==================== */

/* ---- 注册标量文本矩阵（@Alias / @Vars）：启动期(session=nullptr)与动作脚本期(session)两路 ----
 * 两者共用一条注册路径：结构期重名即抛；动作脚本内重名报错、@Alias 同名覆盖结构定义，
 * @Vars 则拒绝覆盖（见 session 分支内的防线注释）。 */
void HwFactory::registerScalarMatrix(const mt::MatrixObject& matrix, std::set<std::string>* session,
		ScalarKind kind, std::int64_t fromRow) {
	const char* label = (kind == ScalarKind::Alias) ? "Alias" : "Vars";
	/* 重复报错沿用「Duplicate alias name」既有措辞（有负值回归守门），Vars 用自身名 */
	const char* dupLabel = (kind == ScalarKind::Alias) ? "alias" : "Vars";
	std::int64_t idxName = matrix.requireCol(0, "name", std::string(label) + " matrix");
	for (std::int64_t i = fromRow; i < static_cast<std::int64_t>(matrix.rows()); ++i) {
		const std::string& name = matrix(i, idxName);
		std::unique_ptr<MatrixVars_Hardware> var;
		if (kind == ScalarKind::Alias) {
			var = MtVars_Alias::Factory(matrix, i);
		} else {
			/* Vars 表达式惰性求值：标识符经注册表解析（环由 Vars 深度计数兜底；
			 * registry_ 的生命周期长于 factory_，解析器捕获其地址安全） */
			var = MtVars_Vars::Factory(matrix, i, registry_.makeVarsResolver());
		}
		if (session) {
			if (session->count(name)) {
				throw IllegalArgumentException(concatMsg(
					"Duplicate ", std::string(dupLabel), " name '", name, "' within the action script"));
			}
			session->insert(name);
			if (kind == ScalarKind::Vars && registry_.contains(name)) {
				/* 审计 H-1/P0-2 防线：@Vars 的数值会经 $/$(...) 元数据引用列进入
				 * 硬件参数（max/min/fd/channel…），动作脚本同名覆盖等价于远程改写
				 * 结构定义（--tcp 模式下即安全边界失守，PoC 实证 note 50→4995）。
				 * @Alias 覆盖仅做键名替换、替换后仍过 rejectReservedKeys 元数据
				 * 防线，保留覆盖语义；@Vars 一律拒绝覆盖，参数化请使用新名字
				 * （引用结构 Vars 读取不受影响）。 */
				throw IllegalArgumentException(concatMsg(
					"action script @Vars must not override the "
					"structure-defined variable '", name, "' (use a fresh name)"));
			}
			if (registry_.contains(name)) {
				std::cerr << label << " '" << name
					<< "' defined in action script overrides the structure definition" << std::endl;
			}
			registry_.override(name, std::move(var));	/* 会话期覆盖式注册（结构定义被动作脚本别名覆盖） */
		} else {
			registry_.add(name, std::move(var), std::string(" (in @") + label + " matrix)");
		}
	}
}

/* ==================== 单消费者判据（审计 1.3）====================
 * HAL 的每次 I2C 访问都是**单次 I2C_RDWR ioctl**（寄存器指针写 + 数据读合并成
 * 一个内核事务，见 modules/lib/hal/i2c.lua 的 i2c_read_reg / i2c_read_multi_bytes），内核在
 * adapter 层串行化，两个 fd 也插不进对方的指针相位。所以「主线程驱动 + 守护
 * 同址采样」对绝大多数器件是安全的——robots/test/ 下 20 个夹具正是刻意这么写的
 * （.mt 里同时点名设备与守护，注释写明"给守护留采样窗口"）。
 *
 * 真正不安全的只有一类：**器件侧状态跨多个事务**的驱动。典型是握手式间接访问
 * （AS7262：poll HW_STATUS → 写 HW_WRITE=vaddr → poll → 读 HW_READ）——地址相位
 * 存在器件里，另一个消费者插进来就会读到对方的寄存器，且双方都看不出被踩。
 *
 * 判据不放在 C++ 的表里（会与驱动漂移），而是由**驱动自己声明**：模块源里出现
 * 行首 SINGLE_CONSUMER 标记即视为声明。纯文本扫描、不执行 Lua（与
 * test/gen_const_check.cmake 从 Lua 源抽常量同一手法）。
 * 冲突键 = (总线设备路径, 归一化地址)；SPI/UART 无地址概念，键退化为 (路径, "")。
 * 以 $ 引用消费别人的变量（Monitor/Ema/Kalman）没有 I2C/address 列，天然不登记。 */
namespace {

/* 行首标记扫描：允许前导空白；注释里的偶提（"-- SINGLE_CONSUMER"）不算声明 */
bool declaresSingleConsumer(const std::string& path) {
	static const std::string kMarker = "SINGLE_CONSUMER";
	std::string text;
	std::string err;
	if (!readWholeFileLimited(path, 1u << 20, text, err, "驱动")) { return false; }
	std::size_t pos = 0;
	while (pos < text.size()) {
		const std::size_t nl = text.find('\n', pos);
		const std::string line = text.substr(pos, nl == std::string::npos ? nl : nl - pos);
		const std::size_t first = line.find_first_not_of(" \t");
		if (first != std::string::npos
			&& line.compare(first, kMarker.size(), kMarker) == 0) { return true; }
		if (nl == std::string::npos) { break; }
		pos = nl + 1;
	}
	return false;
}

/* 地址归一化：'0x48' 与 '72' 必须落到同一个键。解析不出来就按原串（去空白）用，
 * 宁可多一个键（漏判一次）也不要把两个不同地址并成一个（误报）。 */
std::string normalizeAddress(const std::string& raw) {
	std::string s = raw;
	s.erase(0, s.find_first_not_of(" \t"));
	s.erase(s.find_last_not_of(" \t") + 1);
	if (s.empty() || s == "-") { return std::string(); }
	const char* begin = s.c_str();
	char* end = nullptr;
	const int base = (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? 16 : 10;
	const long long v = std::strtoll(begin, &end, base);
	if (end == begin || *end != '\0') { return s; }
	return std::to_string(static_cast<long long>(v));	/* 十进制规范形 */
}

/* 结构脚本里的总线引用带 $ 前缀（'$i2c-1'），映射键用裸名 */
std::string stripRef(const std::string& v) {
	return (!v.empty() && v[0] == '$') ? v.substr(1) : v;
}

/* 可选列取值：列不存在或值为占位符 '-' 时返回空串 */
std::string optCol(const mt::MatrixObject& m, std::int64_t row, const char* col) {
	const std::int64_t idx = m.indexOfCol(0, col);
	if (idx < 0) { return std::string(); }
	const std::string& v = m.inherited(row, idx);
	return (v == "-") ? std::string() : v;
}

/* 守护侧的缺省值以 HwFactory::kDaemonDefault* 为**单点**（声明处有完整理由：
 * 缺列不等于"不参与判据"，必须按 sensor_daemon.lua 的缺省补全；两侧漂移由
 * test/cpp/test_robot.cpp 的 daemon_defaults_match_lua_source 读 Lua 源钉住）。 */

/* checkSingleConsumer 的跨表共享状态 + claim/singleConsumer 判据 + 每类表的登记
 * （拆自 checkSingleConsumer，2026-09-26 批次 5）。原函数 127 行把「建总线路径表 /
 * 两个捕获状态的 lambda / Daemon 分支（含多器件 devices 解析）/ 常规硬件分支」全
 * 内联在一处；收进本结构后 checkSingleConsumer 只留「建状态 → 扫总线表 → 逐表分派」
 * 的编排。成员名与原局部量/lambda 逐字相同，故各分支体原样搬入、行为不变。
 * 2026-10-04 评估后判不再拆独立 TU：再搬就得把 declaresSingleConsumer 与 scCache 的
 * 批内作用域策略一并导出，把单函数私有状态升级成跨 TU 契约（记录见提交 fc1c66f）。 */
struct SingleConsumerCheck {
	std::map<std::string, std::string> busPath;	/* 总线名 → 设备路径（I2C/SPI/UART 表） */
	std::map<std::string, std::string> owner;	/* 键 -> 首个消费者的定位串 */
	/* SINGLE_CONSUMER 判读的批内缓存：判定要重读整个驱动模块文件（上限 1 MiB），
	 * Daemon 表逐行/逐 devices-spec 调用会让同一模块被反复读盘（spider1 这类
	 * 「PCA9685 + 14 路 Servo + 守护」结构是 O(行数) 次同名文件）。键用调用点的
	 * 模块名形态（含 .lua）：firstExistingModule 只依赖 modulePath，本函数内
	 * 不变形，批内同名判据必然一致。跨批不缓存——热插表逐批调用，保守起见
	 * 允许模块文件在两批之间被替换后的新判定生效。 */
	std::map<std::string, bool> scCache;
	std::string modulePath;			/* N-19：模块根目录单点 */

	void claim(const std::string& key, const std::string& who) {
		if (key.empty()) { return; }
		const auto it = owner.find(key);
		if (it != owner.end()) {
			throw IllegalArgumentException(concatMsg(
				"Device '", key, "' would have two concurrent consumers: ", it->second, " and ", who,
				". This driver declares SINGLE_CONSUMER"
				" (its register access spans multiple bus transactions, so a second"
				" consumer corrupts the device-side address phase). Drop one of them,"
				" or sample it from the daemon only and consume via '$' reference."));
		}
		owner.emplace(key, who);
	}

	bool singleConsumer(const std::string& moduleName) {
		const auto it = scCache.find(moduleName);
		if (it != scCache.end()) { return it->second; }
		const bool v = declaresSingleConsumer(firstExistingModule(modulePath, moduleName));
		scCache.emplace(moduleName, v);
		return v;
	}

	/* ---- 1) 总线名 → 设备路径（I2C/SPI/UART 表的 name/path 列）---- */
	void scanBusTables(const std::deque<mt::MatrixObject>& matrices) {
		for (const auto& m : matrices) {
			const std::string& t = m.getName();
			if (t != "I2C" && t != "SPI" && t != "UART") { continue; }
			const std::int64_t idxName = m.indexOfCol(0, "name");
			const std::int64_t idxPath = m.indexOfCol(0, "path");
			if (idxName < 0 || idxPath < 0) { continue; }
			for (std::int64_t i = 1; i < static_cast<std::int64_t>(m.rows()); ++i) {
				busPath[m.inherited(i, idxName)] = m.inherited(i, idxPath);
			}
		}
	}

	/* ② 多器件守护：`driver@addr@fields[@k=v...]`，以 '|' 分隔。
	 * 宿主此前从不解析这一列 ⇒ 整类守护不在判据内（漏标）。
	 * spec 语法错（缺 @、字段空）由守护侧 fail(-2) 在运行期报，
	 * 这里只跳过解析不出来的片段，不重复造一套语法校验。 */
	void claimDevicesSpec(const std::string& devices, const std::string& path,
			const std::string& whoBase) {
		std::size_t pos = 0;
		std::size_t specIdx = 0;
		while (pos < devices.size()) {
			const std::size_t bar = devices.find('|', pos);
			const std::string spec = devices.substr(pos,
				bar == std::string::npos ? std::string::npos : bar - pos);
			pos = (bar == std::string::npos) ? devices.size() : bar + 1;
			++specIdx;
			const std::size_t at1 = spec.find('@');
			if (spec.empty() || at1 == std::string::npos) { continue; }
			const std::string specDrv = trim(spec.substr(0, at1));
			const std::size_t at2 = spec.find('@', at1 + 1);
			const std::string specAddr = trim(spec.substr(at1 + 1,
				(at2 == std::string::npos ? spec.size() : at2) - at1 - 1));
			if (specDrv.empty() || !singleConsumer(specDrv + ".lua")) { continue; }
			claim(path + " " + normalizeAddress(specAddr),
				concatMsg(whoBase, " devices[", std::to_string(specIdx), "]='",
					specDrv, "'"));
		}
	}

	/* 守护采样的是 driver 列指名的那颗器件；多器件守护
	 * （chunk = lib/sensor_daemon_multi.lua）的清单在 devices 列。
	 * proto=virt 是内存仿真，不碰真器件，不参与判据（否则无硬件夹具
	 * 会全线误报）；**缺列不等于 virt**——守护侧缺省就是 i2c，
	 * 见 kDaemonDefaultProto 的注释。 */
	void claimDaemonRow(const mt::MatrixObject& m, std::int64_t i, std::int64_t idxName) {
		const std::string protoRaw = optCol(m, i, "proto");
		const std::string proto = protoRaw.empty()
			? std::string(HwFactory::kDaemonDefaultProto) : protoRaw;
		if (proto == "virt") { return; }
		const std::string pathRaw = optCol(m, i, "path");
		const std::string path = pathRaw.empty()
			? std::string(proto == "spi" ? HwFactory::kDaemonDefaultPathSpi
						     : HwFactory::kDaemonDefaultPathI2c)
			: pathRaw;
		const std::string whoBase = "daemon '" + m.inherited(i, idxName)
			+ "' (in table '" + m.getName() + "', row " + std::to_string(i) + ")";

		const std::string drv = optCol(m, i, "driver");
		const std::string devices = optCol(m, i, "devices");
		if (!drv.empty()) {
			/* ① 单器件守护：driver + addr 列 */
			if (singleConsumer(drv + ".lua")) {
				claim(path + " " + normalizeAddress(optCol(m, i, "addr")), whoBase);
			}
		} else if (!devices.empty()) {
			/* driver 列与 devices 列互斥（多器件守护不用 driver/addr/fields
			 * 列，见 sensor_daemon_multi.lua 文件头），故用 else if —— 否则
			 * 同一行会被 claim 两次，自己和自己冲突（误报）。 */
			claimDevicesSpec(devices, path, whoBase);
		}
	}

	/* 常规硬件表：表名即驱动模块名（modules/<表名>.lua）。只登记**直接持总线
	 * 句柄**的行：有 I2C/SPI/UART 引用列才算消费者。经 controller 转发的行
	 * （如挂在 PCA9685 上的 14 路 Servo）不自己开总线，也就不是本判据意义上的
	 * 消费者。 */
	void claimHardwareTable(const mt::MatrixObject& m, std::int64_t idxName) {
		const std::string& t = m.getName();
		if (!singleConsumer(t + ".lua")) { return; }
		for (std::int64_t i = 1; i < static_cast<std::int64_t>(m.rows()); ++i) {
			std::string path;
			for (const char* busCol : {"I2C", "SPI", "UART"}) {
				const std::string ref = stripRef(optCol(m, i, busCol));
				if (ref.empty()) { continue; }
				const auto it = busPath.find(ref);
				path = (it != busPath.end()) ? it->second : ref;
				break;
			}
			if (path.empty()) { continue; }
			const std::string who = "hardware variable '" + m.inherited(i, idxName)
				+ "' (in table '" + t + "', row " + std::to_string(i) + ")";
			claim(path + " " + normalizeAddress(optCol(m, i, "address")), who);
		}
	}
};

} // namespace

void HwFactory::checkSingleConsumer(const std::deque<mt::MatrixObject>& matrices) {
	/* 判据与跨表状态都在 SingleConsumerCheck（见其注释）；本函数只负责编排：
	 * 建状态 → 扫总线表（name→path）→ 逐表按种类分派登记消费者，第二个消费者
	 * 即由 claim 抛出。装配前的单消费者判据（审计 1.3）：只对**自己声明**
	 * SINGLE_CONSUMER 的驱动生效（其寄存器访问跨多个总线事务，器件侧地址相位
	 * 会被第二个消费者踩掉）。HAL 的每次访问是单次 I2C_RDWR 原子事务，故绝大多数
	 * 器件允许多消费者，不做一刀切。判据 = (总线设备路径, 归一化地址) 唯一。 */
	SingleConsumerCheck c;
	c.modulePath = modulePaths();	/* N-19：模块根目录单点 */
	c.scanBusTables(matrices);

	for (const auto& m : matrices) {
		const std::string& t = m.getName();
		if (t == "Alias" || t == "Vars" || t == "Action" || m.rows() == 0) { continue; }
		const std::int64_t idxName = m.indexOfCol(0, "name");
		if (idxName < 0) { continue; }
		if (t == "Daemon") {
			for (std::int64_t i = 1; i < static_cast<std::int64_t>(m.rows()); ++i) {
				c.claimDaemonRow(m, i, idxName);
			}
			continue;
		}
		c.claimHardwareTable(m, idxName);
	}
}

/* ---- F5-4：同物理串口多独立 fd 消费者的加载期告警 ----
 * 共享形态只有一种是危险的：两个消费者**各自 open** 同一 path（UART 总线
 * 变量重复声明同一路径、或 UART 变量 + 真机守护各开一个 fd）。此时每个
 * lua_State 独立快照/恢复 termios，后关闭者以自己 open 时的配置为准
 * （modules/lib/hal/uart.lua 自述「不做跨变量引用计数」），混用波特率还会
 * 互相改线速。而多个器件行引用**同一个** UART 总线变量（'$uart-0'）是
 * 安全形态：fd 只有一个、termios 只设一次，器件行不持有句柄——不告警。
 * virt 侧（总线 proto=virt、守护 proto=virt）走内存仿真不碰真串口，跳过
 * （否则无硬件夹具全线误报）。路径按字符串精确比对：/dev/serial0 与
 * /dev/ttyS0 这类符号链接别名无法在结构期归一，宁可漏报（与
 * normalizeAddress「宁漏不误」同取向）。P1-3 起升级为硬拒绝——此前只告警
 * 容易被日志淹没、配置漂移无人感知；强制使用者显式共享一个 UART 总线变量
 * （'$uart-x' 引用）或走守护采样。 */
void HwFactory::rejectSharedUartPaths(const std::deque<mt::MatrixObject>& matrices) {
	std::map<std::string, std::vector<std::string>> users;	/* path -> 消费者定位串 */
	for (const auto& m : matrices) {
		const std::string& t = m.getName();
		if (t == "Alias" || t == "Vars" || t == "Action" || m.rows() == 0) { continue; }
		const std::int64_t idxName = m.indexOfCol(0, "name");
		if (idxName < 0) { continue; }
		for (std::int64_t i = 1; i < static_cast<std::int64_t>(m.rows()); ++i) {
			std::string who;
			std::string path;
			if (t == "UART") {
				/* proto=virt 的总线行是内存仿真（attach_uart），不碰真串口 */
				const std::string proto = optCol(m, i, "proto");
				if (proto == "virt") { continue; }
				const std::int64_t idxPath = m.indexOfCol(0, "path");
				if (idxPath < 0) { continue; }
				path = m.inherited(i, idxPath);
				if (path.empty() || path == "-") { continue; }
				who = "UART bus variable '" + m.inherited(i, idxName) + "'";
			} else if (t == "Daemon") {
				const std::string proto = optCol(m, i, "proto");
				if (proto.empty() || proto == "virt") { continue; }
				path = optCol(m, i, "path");
				if (path.empty()) { continue; }
				who = "daemon '" + m.inherited(i, idxName) + "'";
			} else {
				continue;	/* 器件行经 '$uart-x' 共享总线的 fd，非独立消费者 */
			}
			users[path].push_back(concatMsg(who, " (table '", t, "', row ",
				std::to_string(i), ")"));
		}
	}
	for (const auto& [path, who] : users) {
		if (who.size() < 2) { continue; }
		std::string names;
		for (const auto& w : who) { names += (names.empty() ? "" : ", ") + w; }
		throw IllegalArgumentException(concatMsg(
			"UART path '", path, "' is opened independently by ", std::to_string(who.size()), " consumers: ", names,
			". HAL does not do cross-variable reference counting; the last close",
			" wins and mixing baud rates corrupts the serial line config.",
			" Share one UART bus variable via '$' reference, or sample via daemon only."));
	}
}

/* ---- 全部硬变量创建：声明序，Alias/Lua/Daemon 分派 ---- */
void HwFactory::createHardVars(const std::deque<mt::MatrixObject>& matrices) {
	/* 装配前先做单消费者判据：此时还没申请任何资源（Lua 状态/共享槽/总线句柄），
	 * 报错即干净退出，不会留下半装配的机器人。 */
	checkSingleConsumer(matrices);
	rejectSharedUartPaths(matrices);	/* F5-4/P1-3：同物理串口多独立 fd 硬拒绝 */
	for (const auto& matrix : matrices) { createHardVarsFrom(matrix, 1); }
}

/* 全结构判据入口：与 createHardVars 内部调用的两个判据同一实现（单一事实源）。
 * 热插表事务在提交前对「提交之后的结构视图」调用它——见头文件契约。 */
void HwFactory::precheckStructure(const std::deque<mt::MatrixObject>& matrices) {
	checkSingleConsumer(matrices);
	rejectSharedUartPaths(matrices);
}

/* 单矩阵增量装配：全量装配的唯一下沉点（见头文件契约）。 */
void HwFactory::createHardVarsFrom(const mt::MatrixObject& matrix, std::int64_t fromRow) {
	const std::string& mtName = matrix.getName();
	if (mtName == "Alias") { registerScalarMatrix(matrix, nullptr, ScalarKind::Alias, fromRow); }
	else if (mtName == "Vars") { registerScalarMatrix(matrix, nullptr, ScalarKind::Vars, fromRow); }
	else if (mtName == "Action") { /* 结构期 Action 由 MR 动作脚本提供 */ }
	else if (mtName == "Daemon") { createDaemonVars(matrix, mtName, fromRow); }
	else if (matrix.rows() > 0) { createLuaVars(matrix, mtName, fromRow); }
}

void HwFactory::createDaemonVars(const mt::MatrixObject& matrix, const std::string& mtName,
		std::int64_t fromRow) {
	std::int64_t idxName = matrix.requireCol(0, "name", "Table");
	for (std::int64_t i = fromRow; i < static_cast<std::int64_t>(matrix.rows()); ++i) {
		const std::string& name = matrix(i, idxName);
		precheckDuplicate(name, mtName);
		registry_.add(name, MtVars_Daemon::Factory(matrix, i, daemons_),
			" (in table '" + mtName + "')");
	}
}

/* ---- 流引用列解析结果（阶段 3 拆分：createLuaVars 的引用列内核）---- */
struct FlowRowRefs {
	std::vector<std::string> ctrlNames;
	std::vector<std::string> trigNames;
};

/* 解析一行内的流引用列（controller/trigger 基名或基名+数字）并完成装配期
 * 校验，命中即登记 flowRef。逐列规则：
 * - 多列 = 扇出（controller 各收同一份转发 payload，trigger 依序前置调用），
 *   不是同行接力；同列族重复指向装配期拒绝；
 * - 「先声明」约束对每个目标独立生效——两条引用边都只指向更早声明的变量
 *   ⇒ 引用图按构造是 DAG，派发期无需环检测（前向引用是 $ 数据列的专属能力）；
 * - trigger（入边）另拒 $ 引用与框架保留键（调用边不是数据线）、触发器名
 *   与本行元数据列同名冲突（触发器结果按名并入会易主该键）。 */
FlowRowRefs parseFlowRow(const mt::MatrixObject& matrix, std::int64_t i, const std::string& name,
		const std::string& mtName, HwRegistry& registry) {
	FlowRowRefs out;
	for (std::int64_t j = 0; j < static_cast<std::int64_t>(matrix.cols()); ++j) {
		const std::string& colName = matrix(0, j);
		const bool isCtrl = flowColumnMatches(colName, "controller");
		if (!isCtrl && !flowColumnMatches(colName, "trigger")) { continue; }
		const std::string& raw = matrix.inherited(i, j);
		if (raw == "-") { continue; }
		std::vector<std::string>& names = isCtrl ? out.ctrlNames : out.trigNames;
		const char* kind = isCtrl ? "controller" : "trigger";
		/* 同列族重复指向：扇出语义下只会对同一目标双调用，装配期拒绝 */
		if (std::find(names.begin(), names.end(), raw) != names.end()) {
			throw IllegalArgumentException(concatMsg("Hardware variable '", name, "' declares ",
				kind, " '", raw, "' more than once in table '", mtName,
				"' (a flow column target must be unique per row)."));
		}
		if (!isCtrl) {
			if (raw.rfind('$', 0) == 0) {
				throw IllegalArgumentException(concatMsg("Hardware variable '", name,
					"' declares trigger '", raw, "' in table '", mtName,
					"': the trigger column takes a plain",
					" variable name and does not support '$' references (a trigger is an",
					" invocation edge, not a data wire; use a '$' metadata column for snapshots)."));
			}
			if (raw == "result" || raw == "message" || raw == "mode") {
				throw IllegalArgumentException(concatMsg("Hardware variable '", name,
					"' declares trigger '", raw, "' in table '", mtName, "': '", raw,
					"' is a framework-reserved key and cannot name a trigger."));
			}
		}
		MatrixVars_Hardware* target = registry.find(raw);
		if (target == nullptr) {
			throw IllegalArgumentException(concatMsg("Hardware variable '", name, "' declares ",
				kind, " '", raw, "' in table '", mtName,
				"', but it is not defined yet. The ", kind,
				" must be defined before the matrix that references it."));
		}
		if (target->isScalarText()) {
			throw IllegalArgumentException(concatMsg("Hardware variable '", name, "' declares ",
				kind, " '", raw, "' in table '", mtName,
				"': '@Alias'/'@Vars' scalars cannot be ",
				kind, " targets (both are invoked via play and must return a result table)."));
		}
		if (!isCtrl) {
			/* 触发器结果以触发器名字为键并入调用参数——与本行元数据列同名会让
			 * 该键易主，装配期拒绝（排除集 = name + 全部流引用列；列集合此刻已
			 * 定型）；.mt 参数键同名由 MtVars_Lua::rejectReservedKeys 在派发期
			 * 拒绝（.mt 此刻还没加载）。 */
				for (std::int64_t c = 0; c < static_cast<std::int64_t>(matrix.cols()); ++c) {
					const std::string& other = matrix(0, c);
					if (other == "name" || isFlowColumn(other)) { continue; }
					if (other == raw) {
						throw IllegalArgumentException(concatMsg("Hardware variable '", name,
							"' declares trigger '", raw, "' in table '", mtName,
							"': the trigger result is merged",
							" under the trigger name, which collides with metadata column '",
							other, "'. Rename one of them."));
					}
				}
		}
		/* N-6：登记流引用，会话期覆盖将拒绝触碰该名字 */
		registry.addFlowRef(raw);
		names.push_back(raw);
	}
	return out;
}

void HwFactory::createLuaVars(const mt::MatrixObject& matrix, const std::string& mtName,
		std::int64_t fromRow) {
	std::int64_t idxName = matrix.requireCol(0, "name", "Table");
	std::string modulePath = modulePaths();	/* N-19：模块根目录单点 */
	std::string scriptPath = firstExistingModule(modulePath, mtName + ".lua");
	for (std::int64_t i = fromRow; i < static_cast<std::int64_t>(matrix.rows()); ++i) {
		const std::string& name = matrix(i, idxName);
		precheckDuplicate(name, mtName);
		FlowRowRefs flow = parseFlowRow(matrix, i, name, mtName, registry_);
		auto metaProv = std::make_shared<MetaProvider>(matrix, i, &registry_);
		metas_.add(metaProv);	/* F-05：供 active() 在 build 前统一校验 $ 引用 */
		registry_.add(name, MtVars_Lua::Factory(scriptPath, name,
			[metaProv](bool forDestroy) {
				return forDestroy ? metaProv->collectForDestroy() : metaProv->collect();
			}, flow.ctrlNames, flow.trigNames, &registry_),
			" (in table '" + mtName + "')");
	}
}

} // namespace bot
