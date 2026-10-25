/* test_mcptransport.cpp —— MCP 传输与认证域（帧编解码/凭证/探测/契约钉子）
 *
 * 自 test_mcpbackend.cpp 拆出（2026-10-01，行为保持），镜像 src/mcptransport.cpp
 * 的域边界：帧编码与严格 UTF-8、SO_PEERCRED、socket 路径占用探测（A-1）、
 * 空闲 deadline 合成（A-2）、帧上限/回执 schema 的 Rust 孪生契约钉子、
 * 首帧共享密钥三态（MCP-1）与 AuthFailGate。
 */

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "agentmode.hpp"	/* AgentModeConfig（context.get 用例） */
#include "agenttools.hpp"
#include "jsonparse.hpp"
#include "mcpbackend.hpp"
#include "robot.hpp"
#include "util_except.hpp"
#include "util_str.hpp"
#include "util_utf8.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "mcp_fixtures.hpp"
#include "agenttools_fixtures.hpp"

using namespace bot;
using namespace bot::agent;

using mfx::makeBackend;

/* ---- 帧编码：4 字节 big-endian 长度 + 载荷（与 pymsg/gomsg/libmsg 字节兼容）---- */
TH_TEST(mcpbackend_frame_encode_is_4byte_be_plus_payload) {
	const std::string f = mcpEncodeFrame("abc");
	TH_CHECK(f.size() == 7);
	TH_CHECK(static_cast<unsigned char>(f[0]) == 0u);
	TH_CHECK(static_cast<unsigned char>(f[1]) == 0u);
	TH_CHECK(static_cast<unsigned char>(f[2]) == 0u);
	TH_CHECK(static_cast<unsigned char>(f[3]) == 3u);
	TH_CHECK(f.compare(4, 3, "abc") == 0);

	/* 空载荷合法（libmsg 口径）：只有 4 字节头，长度 0 */
	const std::string e = mcpEncodeFrame("");
	TH_CHECK(e.size() == kMcpHeaderSize);
	TH_CHECK(static_cast<unsigned char>(e[3]) == 0u);

	/* 300 = 0x0000012C：验证多字节 BE 编码正确 */
	const std::string big = mcpEncodeFrame(std::string(300, 'x'));
	TH_CHECK(big.size() == 304);
	TH_CHECK(static_cast<unsigned char>(big[2]) == 0x01u);
	TH_CHECK(static_cast<unsigned char>(big[3]) == 0x2Cu);
}

/* ---- 写侧 deadline（2026-10-01 批次 A / P1-3）----
 * 此前 sendFrame 无 deadline，靠 acceptLoop 的 SO_SNDTIMEO 兜底——而 setsockopt
 * 失败只告警，该路径上慢读端可无限挂住单线程后端。Rust 侧同类修复见 0333f1a。
 * 这里钉：对端不读 + 载荷远超 socket 缓冲 → deadline 内返回 false（不再无限
 * 挂住）；对端正常读 → 发满返回 true 且字节形态正确。 */
TH_TEST(mcpbackend_sendframe_deadline_unblocks_slow_reader) {
	int fds[2] = {-1, -1};
	if (::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
		TH_SKIP("socketpair 不可用");
	}
	/* 对端不读：send 缓冲填满后 send() 阻塞——旧实现在这里永久挂住 */
	const std::string big(kMcpMaxFrameBytes, 'x');
	const auto t0 = std::chrono::steady_clock::now();
	TH_CHECK(!sendFrame(fds[0], big, 1));	/* 1 秒 deadline */
	const long elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();
	TH_CHECK_MSG(elapsed < 5000, "慢读端挂住写侧: " + std::to_string(elapsed) + "ms");
	::close(fds[0]);
	::close(fds[1]);

	/* 对端正常读：小载荷发满，4 字节 BE 长度 + 载荷字节形态正确 */
	int ok[2] = {-1, -1};
	if (::socketpair(AF_UNIX, SOCK_STREAM, 0, ok) != 0) {
		TH_SKIP("socketpair 不可用");
	}
	TH_CHECK(sendFrame(ok[0], "hello", kMcpSendTimeoutSec));
	char buf[16] = {0};
	TH_CHECK(::recv(ok[1], buf, sizeof(buf), 0) == 9);
	TH_CHECK(std::memcmp(buf + 4, "hello", 5) == 0);
	::close(ok[0]);
	::close(ok[1]);
}

/* ---- 严格 UTF-8 校验：拒 overlong / 代理区 / 截断 / 超范围 ---- */
TH_TEST(mcpbackend_valid_utf8_accepts_and_rejects) {
	TH_CHECK(isValidUtf8("hello"));			/* ASCII */
	TH_CHECK(isValidUtf8("\xe4\xb8\xad"));		/* 中（3 字节）*/
	TH_CHECK(isValidUtf8("\xf0\x9f\x98\x80"));	/* 😀（4 字节）*/
	TH_CHECK(isValidUtf8(""));			/* 空串合法 */

	TH_CHECK(!isValidUtf8("\xc0\x80"));		/* overlong 编码的 NUL */
	TH_CHECK(!isValidUtf8("\xed\xa0\x80"));	/* 代理区 D800 */
	TH_CHECK(!isValidUtf8("\xe4\xb8"));		/* 3 字节序列被截断 */
	TH_CHECK(!isValidUtf8("\x80"));		/* 续字节打头 */
	TH_CHECK(!isValidUtf8("\xf5\x80\x80\x80"));	/* > U+10FFFF */
}


/* ---- SO_PEERCRED：同进程 socketpair 匹配；非 socket fd 读取失败即拒 ---- */
TH_TEST(mcpbackend_peercred_matches_self_and_rejects_non_socket) {
	std::ostringstream log;

	int fds[2] = {-1, -1};
	if (::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
		TH_SKIP("socketpair 不可用");
	}
	/* 同进程两端：uid/gid 必然一致 → 放行 */
	TH_CHECK(mcpCheckPeerCred(fds[0], log));
	::close(fds[0]);
	::close(fds[1]);

	/* 非 socket fd：getsockopt(SO_PEERCRED) 失败 → 拒（覆盖失败分支）*/
	const int fd = ::open("/dev/null", O_RDONLY);
	TH_CHECK(fd >= 0);
	TH_CHECK(!mcpCheckPeerCred(fd, log));
	::close(fd);
}

/* ---- A-1（2026-09-25 审计）：socket 路径占用探测四态 ----
 * 原实现无条件 unlink：误配同一路径的后启动者会静默偷走 socket 文件、先启动者
 * 永远不可达。探测必须分清「无人监听（可覆盖）」与「活实例（拒绝启动）」。 */
TH_TEST(mcpbackend_probe_socket_path_free_stale_busy_unusable) {
	fx::TempDir tmp("mcp-probe");
	std::string why;
	const std::string base = (tmp.path() / "probe").string();

	/* ① 路径不存在 → 空闲可绑定 */
	TH_CHECK(mcpProbeSocketPath(base, why) == McpSocketProbe::PathFree);
	TH_CHECK(why.empty());

	/* ② 陈旧 socket（bind 后关闭、无人监听）→ 可安全覆盖 */
	{
		const std::string stale = base + "-stale";
		const int s = ::socket(AF_UNIX, SOCK_STREAM, 0);
		TH_CHECK(s >= 0);
		sockaddr_un addr{};
		addr.sun_family = AF_UNIX;
		std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", stale.c_str());
		TH_CHECK(::bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
		::close(s);	/* 文件留盘、无监听者 → stale */
		TH_CHECK(mcpProbeSocketPath(stale, why) == McpSocketProbe::PathFree);
		TH_CHECK(why.empty());
	}

	/* ③ 活监听（bind + listen）→ 拒绝启动且点名成因 */
	{
		const std::string busy = base + "-busy";
		const int s = ::socket(AF_UNIX, SOCK_STREAM, 0);
		TH_CHECK(s >= 0);
		sockaddr_un addr{};
		addr.sun_family = AF_UNIX;
		std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", busy.c_str());
		TH_CHECK(::bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
		TH_CHECK(::listen(s, 1) == 0);
		const McpSocketProbe r = mcpProbeSocketPath(busy, why);
		TH_CHECK(r == McpSocketProbe::PathBusy);
		TH_CHECK_MSG(why.find("监听") != std::string::npos, "成因点名: " + why);
		::close(s);
	}

	/* ④ 非 socket 文件（普通文件）→ 不替操作者删除 */
	{
		const std::string plain = base + "-plain";
		std::ofstream f(plain, std::ios::binary);
		f << "keep me";
		f.close();
		const McpSocketProbe r = mcpProbeSocketPath(plain, why);
		TH_CHECK(r == McpSocketProbe::PathUnusable);
		TH_CHECK_MSG(why.find("socket") != std::string::npos, "成因点名: " + why);
	}
}

/* ---- A-2（2026-09-25 审计）：空闲 deadline 合成 ----
 * 取「墙钟终点」与「此刻 + 空闲预算」的较早者；都不设 = 不限（max）。 */
TH_TEST(mcpbackend_idle_deadline_composes_wall_clock_and_idle_budget) {
	using Clock = std::chrono::steady_clock;

	/* 都不设：恒 max（空闲不限，长生命周期语义不变） */
	{
		McpBackend b = makeBackend(AgentToolRegistry{});
		TH_CHECK(b.idleDeadline(0) == Clock::time_point::max());
		TH_CHECK(b.idleDeadline(-1) == Clock::time_point::max());
	}
	/* 只设空闲：≈ now + idle（在窗口内） */
	{
		McpBackend b = makeBackend(AgentToolRegistry{});
		const Clock::time_point before = Clock::now();
		const Clock::time_point d = b.idleDeadline(10);
		TH_CHECK(d > before);
		TH_CHECK(d <= Clock::now() + std::chrono::seconds(12));
	}
	/* 只设墙钟（1 小时）：≈ connStart + 1h，远小于 max */
	{
		McpBackend b = makeBackend(AgentToolRegistry{}, /*callBudget=*/0, /*wallClock=*/3600);
		const Clock::time_point d = b.idleDeadline(0);
		TH_CHECK(d != Clock::time_point::max());
		TH_CHECK(d > Clock::now() + std::chrono::seconds(3500));
	}
	/* 都设、空闲更早 → 取空闲那条 */
	{
		McpBackend b = makeBackend(AgentToolRegistry{}, /*callBudget=*/0, /*wallClock=*/3600);
		const Clock::time_point d = b.idleDeadline(5);
		TH_CHECK(d <= Clock::now() + std::chrono::seconds(7));
	}
	/* 都设、墙钟更早（1 秒预算）→ 取墙钟那条（不是 100 秒空闲） */
	{
		McpBackend b = makeBackend(AgentToolRegistry{}, /*callBudget=*/0, /*wallClock=*/1);
		const Clock::time_point d = b.idleDeadline(100);
		TH_CHECK(d < Clock::now() + std::chrono::seconds(2));
		TH_CHECK(d > Clock::now() - std::chrono::seconds(2));
	}
}

/* ==================== 跨语言契约钉子（2026-09-25）====================
 * 帧上限/帧头、ToolResult 七字段与线协议字段名表是 C++ 后端与 Rust agent 各持
 * 一份的「同一契约的孪生」（两侧注释各自声明"改动必须双侧同步"），但同步此前
 * 只靠人记——漂移没有本侧运行期症状（Rust 发一个自认合法的 9 MiB 帧会被后端
 * 拒收；字段改名后 serde 静默取 default），只能像 daemon_defaults_match_lua_source
 * （test_robot.cpp）那样读源比对钉死。三条钉子各管一段：帧常量读 frame.rs 的
 * 声明求值、七字段跑真的回执比字段集、字段名表比对 mcp_protocol.hpp 与
 * protocol.rs 的**名单**（并反过来禁止生产 TU 退回裸字面量）。 */

namespace {

#ifndef MYBOT_SOURCE_DIR
#define MYBOT_SOURCE_DIR "."
#endif

/* 读仓库内源文件（编译期锚定源码根，不依赖运行期 CWD） */
std::string readRepoSource(const std::string& rel) {
	const std::string path = std::string(MYBOT_SOURCE_DIR) + "/" + rel;
	std::ifstream f(path, std::ios::binary);
	if (!f) { throw std::runtime_error("契约钉子读不到源文件: " + path); }
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

/* 求常量表达式的值：只支持非负整数字面量、'*'、'+' 与空白——覆盖
 * "8 * 1024 * 1024" 这类惯用形态足够。解析失败返回 false，用例红并带回原文，
 * 让改常量的人顺手适配本函数，而不是静默放过。 */
bool evalConstExpr(const std::string& expr, long long& out) {
	std::size_t i = 0;
	const auto skipWs = [&] {
		while (i < expr.size() && (expr[i] == ' ' || expr[i] == '\t'
				|| expr[i] == '\n' || expr[i] == '\r')) { ++i; }
	};
	const auto digits = [&](long long& v) {
		v = 0;
		const std::size_t begin = i;
		while (i < expr.size() && expr[i] >= '0' && expr[i] <= '9') {
			v = v * 10 + (expr[i] - '0');
			++i;
		}
		return i > begin;
	};
	long long sum = 0;
	skipWs();
	if (!digits(sum)) { return false; }		/* 首项 */
	for (;;) {
		skipWs();
		if (i < expr.size() && expr[i] == '*') {
			++i;
			long long factor = 0;
			skipWs();
			if (!digits(factor)) { return false; }
			sum *= factor;
			continue;
		}
		if (i < expr.size() && expr[i] == '+') {
			++i;
			long long term = 0;
			skipWs();
			if (!digits(term)) { return false; }
			sum += term;
			continue;
		}
		break;
	}
	skipWs();
	if (i != expr.size()) { return false; }
	out = sum;
	return true;
}

/* 取声明 "pub const NAME: T = RHS;" 的右侧原文（取声明点到下一个 ';'） */
std::string rustConstRhs(const std::string& src, const std::string& decl) {
	const std::size_t at = src.find(decl);
	if (at == std::string::npos) { return {}; }
	const std::size_t eq = src.find('=', at);
	const std::size_t semi = src.find(';', eq);
	if (eq == std::string::npos || semi == std::string::npos) { return {}; }
	return src.substr(eq + 1, semi - eq - 1);
}

/* 抽取 src/mcp_protocol.hpp 的全部线名——形态是
 * `inline constexpr const char* kFoo = "bar";`，取右值字符串。 */
std::set<std::string> cppWireNames(const std::string& src) {
	std::set<std::string> names;
	const std::string decl = "inline constexpr const char* ";
	std::size_t at = 0;
	while ((at = src.find(decl, at)) != std::string::npos) {
		const std::size_t eq = src.find('=', at + decl.size());
		if (eq == std::string::npos) { break; }
		const std::size_t q1 = src.find('"', eq);
		if (q1 == std::string::npos) { break; }
		const std::size_t q2 = src.find('"', q1 + 1);
		if (q2 == std::string::npos) { break; }
		names.insert(src.substr(q1 + 1, q2 - q1 - 1));
		at = q2;
	}
	return names;
}

/* 抽取 agent/src/protocol.rs 的全部线名：`pub const X: &str = "v";` 的字面值，
 * 加上每个 struct 字段的**线上名**——有 `#[serde(rename = "v")]` 取 v，否则取
 * 字段名本身（serde 缺省不改名）。逐行状态机：属性行（`#[`）保留待定 rename，
 * 其它非字段行清空它，故 `#[serde(default)]` 之类不会串味。 */
std::set<std::string> rustWireNames(const std::string& src) {
	std::set<std::string> names;
	const std::string renameAttr = "#[serde(rename = \"";
	std::string pending;
	std::size_t pos = 0;
	while (pos < src.size()) {
		const std::size_t eol = src.find('\n', pos);
		const std::string raw = src.substr(pos,
			(eol == std::string::npos ? src.size() : eol) - pos);
		const std::size_t first = raw.find_first_not_of(" \t");
		const std::string line = (first == std::string::npos) ? std::string() : raw.substr(first);
		const std::size_t rn = line.find(renameAttr);
		if (rn != std::string::npos) {
			const std::size_t q = rn + renameAttr.size();
			const std::size_t close = line.find('"', q);
			if (close != std::string::npos) { pending = line.substr(q, close - q); }
		} else if (line.compare(0, 10, "pub const ") == 0) {
			const std::size_t q1 = line.find('"');
			const std::size_t q2 = (q1 == std::string::npos) ? q1 : line.find('"', q1 + 1);
			if (q1 != std::string::npos && q2 != std::string::npos) {
				names.insert(line.substr(q1 + 1, q2 - q1 - 1));
			}
			pending.clear();
		} else if (line.compare(0, 4, "pub ") == 0) {
			const std::size_t colon = line.find(':', 4);
			if (colon != std::string::npos) {
				names.insert(pending.empty() ? line.substr(4, colon - 4) : pending);
			}
			pending.clear();
		} else if (!line.empty() && line.compare(0, 2, "#[") != 0) {
			pending.clear();
		}
		if (eol == std::string::npos) { break; }
		pos = eol + 1;
	}
	return names;
}

/* joinNames 不再本地手写：直接用生产单点 bot::joinNames（util_str.hpp，
 * 2026-10-01 收敛），测试顺带钉住它的 ", " 缺省分隔符行为。 */

} // namespace

/* ---- 帧上限/帧头三常量：kMcpMaxFrameBytes ↔ kJsonMaxBytes ↔ frame.rs 孪生 ---- */
TH_TEST(mcpbackend_frame_limit_matches_rust_twin) {
	/* 后端帧上限与 JSON 解析器上限同源（mcpbackend.hpp 注释承诺的「对齐」） */
	TH_CHECK_MSG(kMcpMaxFrameBytes == kJsonMaxBytes,
		"kMcpMaxFrameBytes 应与 jsonparse 的 kJsonMaxBytes 相等（8 MiB 对齐承诺）");

	const std::string frameRs = readRepoSource("agent/src/frame.rs");
	const std::string maxRhs = rustConstRhs(frameRs, "pub const MAX_FRAME_BYTES");
	TH_CHECK_MSG(!maxRhs.empty(), "frame.rs 找不到 pub const MAX_FRAME_BYTES 声明");
	long long rustMax = 0;
	TH_CHECK_MSG(evalConstExpr(maxRhs, rustMax) && rustMax == static_cast<long long>(kMcpMaxFrameBytes),
		"frame.rs 的 MAX_FRAME_BYTES（'" + maxRhs + "' → " + std::to_string(rustMax)
		+ "）应与 kMcpMaxFrameBytes（" + std::to_string(kMcpMaxFrameBytes) + "）相等"
		+ "——帧上限是跨进程契约，改一侧必须同步另一侧");

	const std::string hdrRhs = rustConstRhs(frameRs, "pub const HEADER_LEN");
	TH_CHECK_MSG(!hdrRhs.empty(), "frame.rs 找不到 pub const HEADER_LEN 声明");
	long long rustHeader = 0;
	TH_CHECK_MSG(evalConstExpr(hdrRhs, rustHeader) && rustHeader == static_cast<long long>(kMcpHeaderSize),
		"frame.rs 的 HEADER_LEN（'" + hdrRhs + "' → " + std::to_string(rustHeader)
		+ "）应与 kMcpHeaderSize（" + std::to_string(kMcpHeaderSize) + "）相等");
}

/* ---- ToolResult 七字段：C++ 后端与 Rust protocol.rs 的行为契约 ---- */
TH_TEST(mcpbackend_toolresult_schema_matches_rust_outcome) {
	/* 不再读取生产源码猜测序列化实现；直接验证线上响应的字段集合。
	 * Rust protocol.rs 的 serde 测试验证同一组 camelCase wire names。 */
	AgentToolRegistry reg;
	reg.add(mfx::echoTool());
	McpBackend b = mfx::makeBackend(std::move(reg));
	const Json r = parseJson(b.handleFrame(
		R"({"_route":"tool.call","name":"echo","arguments":{}})"));
	TH_CHECK(mfx::respOk(r));
	const Json* data = mfx::respData(r);
	TH_CHECK(data != nullptr);
	const std::set<std::string> expected = {
		"text", "imageDataUrl", "ok", "error", "executed", "paramError", "summary",
	};
	std::set<std::string> actual;
	if (data != nullptr) {
		for (const auto& item : data->items()) { actual.insert(item.first); }
	}
	TH_CHECK_MSG(actual == expected, "tool.call 回执字段集合与跨进程协议不一致");
}

/* ---- 线协议字段名单点：src/mcp_protocol.hpp ↔ agent/src/protocol.rs ----
 * 两侧头注互相指认（"Rust 对应 agent/src/protocol.rs"），但字段名此前各写各的：
 * C++ 侧散着 "success"/"data"/"error"/"tools"/"_route"/"auth"/"token"，Rust 侧散着
 * "token"/"name"/"arguments"/"success"/"error"（2026-10-04 双双收敛进常量表）。
 * 字段名漂移**两侧都不报错**——serde 对多余键静默忽略、缺失键取 default，于是
 * 回执整块退化成空值而全绿。帧上限三常量由上一个用例钉住，这里管字段名。 */
TH_TEST(mcpbackend_protocol_wire_names_match_rust_twin) {
	const std::set<std::string> cpp = cppWireNames(readRepoSource("src/mcp_protocol.hpp"));
	const std::set<std::string> rust = rustWireNames(readRepoSource("agent/src/protocol.rs"));

	/* 抽取自证：形态假设失效（例如改成宏生成）会抽空集合，而「两边都空」照样
	 * 相等——用横跨三组的名字钉住抽取确实在工作。 */
	for (const char* probe : {"tool.call", "imageDataUrl", "robotName"}) {
		TH_CHECK_MSG(cpp.count(probe) == 1,
			std::string("mcp_protocol.hpp 抽不到 ") + probe + "——抽取形态假设已失效");
		TH_CHECK_MSG(rust.count(probe) == 1,
			std::string("protocol.rs 抽不到 ") + probe + "——抽取形态假设已失效");
	}

	/* 唯一合法的单侧名：ping 只有 C++ 后端应答，Rust agent 从不发它——探活走
	 * frame.rs 的连接重试，不进线协议。 */
	static const std::set<std::string> kCppOnly = {"ping"};

	std::vector<std::string> onlyCpp;
	std::vector<std::string> onlyRust;
	for (const std::string& n : cpp) {
		if (rust.count(n) == 0 && kCppOnly.count(n) == 0) { onlyCpp.push_back(n); }
	}
	for (const std::string& n : rust) {
		if (cpp.count(n) == 0) { onlyRust.push_back(n); }
	}
	TH_CHECK_MSG(onlyCpp.empty(), "只在 C++ 常量表、Rust protocol.rs 没有的线名："
		+ bot::joinNames(onlyCpp) + "——改名/删除须两侧同步；新增字段两侧都要声明");
	TH_CHECK_MSG(onlyRust.empty(), "只在 Rust protocol.rs、C++ 常量表没有的线名："
		+ bot::joinNames(onlyRust));

	/* 单点自证：消费 TU 不得再出现这些字段名的裸字面量，否则常量表成了
	 * 第二轨（比对绿而线上仍各写各的）。审计行的 "error" 属 agentaudit.cpp 的
	 * 落盘 schema，不在扫描范围。mcplisten.cpp 2026-10-10 补进名单：认证回帧
	 * 此前在该 TU 手写字面量，正是名单缺口让它存活（转义引号 \\\"success\\\"
	 * 本就躲过子串匹配，名单是纵深防御不是充分防线）。 */
	for (const char* tu : {"src/mcpbackend.cpp", "src/context_service.cpp",
			"src/mcptransport.cpp", "src/mcplisten.cpp"}) {
		const std::string src = readRepoSource(tu);
		std::vector<std::string> bare;
		for (const std::string& n : cpp) {
			if (src.find("\"" + n + "\"") != std::string::npos) { bare.push_back(n); }
		}
		TH_CHECK_MSG(bare.empty(), std::string(tu) + " 仍有裸协议字面量："
			+ bot::joinNames(bare) + "——应改用 mcp_protocol:: 常量");
	}
}

/* ---- 首帧共享密钥（MCP-1，2026-09-29 审计 P2-1）----
 * 纯协议件 mcpCheckAuthFrame 的三态判据：正确密钥 Ok；错误密钥/缺 token 字段/
 * token 非字符串/非法 JSON/顶层非对象 Failed；合法 JSON 对象但 _route 不是 auth
 * （旧客户端直发业务请求）NotAuthFrame——serveConnection 据此区分报错文案。 */
TH_TEST(mcpbackend_auth_frame_accepts_matching_token) {
	using bot::agent::McpAuthOutcome;
	const std::string payload = R"({"_route":"auth","token":"secret-1"})";
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1", payload) == McpAuthOutcome::Ok);
	/* 参数顺序无关：serde_json 按键取值 */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"token":"secret-1","_route":"auth"})") == McpAuthOutcome::Ok);
}

TH_TEST(mcpbackend_auth_frame_rejects_mismatch_and_malformed) {
	using bot::agent::McpAuthOutcome;
	/* 错误密钥：长度相同（防止「比长度短路」的假实现混过）与长度不同两类 */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"auth","token":"secret-2"})") == McpAuthOutcome::Failed);
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"auth","token":"s"})") == McpAuthOutcome::Failed);
	/* 注：expected="" 对 token="" 是合法匹配（Ok），不在本用例——不可达路径：
	 * captureMcpAuthToken 对空值拒绝启动，serveConnection 只在 authToken
	 * 非空时才强制首帧认证；纯函数不重复上游不变式。 */
	/* token 字段缺失 / 非字符串 */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"auth"})") == McpAuthOutcome::Failed);
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"auth","token":123})") == McpAuthOutcome::Failed);
	/* 非法 JSON / 顶层非对象（与 handleFrame 的固定串口径一致：不回显输入） */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1", "not json")
		== McpAuthOutcome::Failed);
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1", "[1,2]")
		== McpAuthOutcome::Failed);
}

TH_TEST(mcpbackend_auth_frame_distinguishes_non_auth_first_frame) {
	using bot::agent::McpAuthOutcome;
	/* 旧客户端形态：首帧直接是业务请求（合法 JSON 对象、_route 非 auth） */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"tool.list"})") == McpAuthOutcome::NotAuthFrame);
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1",
			R"({"_route":"ping"})") == McpAuthOutcome::NotAuthFrame);
	/* _route 缺失或非字符串同样落 NotAuthFrame（有 _route 判据才有区分意义） */
	TH_CHECK(bot::agent::mcpCheckAuthFrame("secret-1", "{}")
		== McpAuthOutcome::NotAuthFrame);
}

/* ---- 首帧认证回帧的字节锚定（2026-10-10 收敛：mcplisten 手写字面量 →
 * mcpAuthOkFrame/mcpAuthRejectFrame 单点）----
 * 回帧是 Rust 侧 authenticate 的判据（success 布尔 / error 文案），serde 按键
 * 取值、键序与空白无关——但字节形态仍逐字钉住：改动（哪怕语义等价）应显式
 * 过这道测试，而不是静默发生。期望值即收敛前的原始字面量。 */
TH_TEST(mcpbackend_auth_reply_frames_byte_stable) {
	TH_CHECK(bot::agent::mcpAuthOkFrame()
		== R"({"success":true,"data":{"auth":true}})");
	TH_CHECK(bot::agent::mcpAuthRejectFrame()
		== R"({"success":false,"error":"auth required: first frame must be {\"_route\":\"auth\",\"token\":...}"})");
	/* 与判据同族：回执经 parseJson 可再解析（合法 JSON 的最小自证） */
	const Json back = parseJson(bot::agent::mcpAuthRejectFrame());
	TH_CHECK(back.get("success") != std::nullopt
		&& back.get("success")->isBool() && !back.get("success")->getBool());
}

/* ---- 首帧认证失败门（2026-09-30 审计 P1：与 TCP 口令 authMaxFails=5 同口径）----
 * serveConnection/acceptLoop 是匿名命名空间静态函数，单测触不到；判据本体
 * AuthFailGate 是纯结构（2026-10-01 收敛到 util_cli.hpp 与 TCP 侧共用），
 * 这里钉住语义：只数认证失败、通过才归零、第 5 次到顶触发停止。哑对端不动
 * 计数由 ConnAuth::Neutral 保证（类型层面已区分，不在此重复）。 */
TH_TEST(mcpbackend_auth_fail_gate_counts_consecutive_rejections) {
	bot::AuthFailGate g;
	TH_CHECK(g.fails == 0);
	/* 前 4 次失败：仍在窗口内，不触发 */
	for (int i = 1; i < g.max; ++i) {
		TH_CHECK(!g.recordRejected());
		TH_CHECK(g.fails == i);
	}
	/* 第 5 次到顶：返回 true（acceptLoop 据此停止服务） */
	TH_CHECK(g.recordRejected());
	TH_CHECK(g.fails == g.max);

	/* 通过归零：爆破计数是「连续」语义，一次成功认证重新开窗 */
	g.recordPassed();
	TH_CHECK(g.fails == 0);
	TH_CHECK(!g.recordRejected());
	TH_CHECK(g.fails == 1);

	/* 交错失败与通过永远到不了顶：合法 agent 的偶发手滑不会锁死后端 */
	bot::AuthFailGate interleave;
	for (int i = 0; i < 100; ++i) {
		(void)interleave.recordRejected();
		interleave.recordPassed();
	}
	TH_CHECK(interleave.fails == 0);
}
