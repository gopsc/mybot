#pragma once
/* harness.hpp —— 零第三方依赖的极简单元测试骨架
 *
 * 为什么不用 Catch2/googletest：本项目 README 明示「零第三方 C++ 依赖」，
 * 且被测面只是解析器与值语义工具，几十行断言足够；引入外部框架要么下载
 * 要么 vendored，都会让「clone 完直接 cmake --build」这条路断掉。
 *
 * 输出约定与 test/run_all.sh 的守门契约一致：
 *   [PASS] <case>   单条通过
 *   [FAIL] <case>   单条失败（附表达式与行号）
 *   [SKIP] <case>   环境不满足，显式跳过（**必须带原因**，见 TH_SKIP）
 *   [DONE]          全部跑完的完成标记（缺标记 = 早退/崩溃，判失败，不假绿）
 *
 * 零断言即失败（2026-09-21 审计 AG-5）：只用「有没有断言失败」判定通过，会让
 * 「环境不满足就早退」的用例整条静默通过——它一条断言都没跑，却占了 [PASS]。
 * 现存实例曾包括「RLIMIT_NOFILE 太低就不构造高编号 fd」这类守卫。现在 harness
 * 记录每用例的断言数，0 断言既不算通过也不算失败，而是**判失败**，除非用例显式
 * 调用 TH_SKIP(reason)（那样记 [SKIP] 并计入跳过数）。理由是：静默通过比失败更
 * 危险——失败会被看见，静默通过不会。
 */

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace th {

struct Case {
	std::string name;
	std::function<void()> fn;
};

inline std::vector<Case>& cases() {
	static std::vector<Case> v;
	return v;
}

/* 一次 runAll 的统计。**必须是「当前运行」的指针而不是全局计数器**：
 * harness_selftest 会在用例内部**嵌套**调用 runAll 来检验判定是否成立，若计数
 * 用全局单例，嵌套调用一清零就把外层运行记的账抹掉——实测症状是外层 8 条用例
 * 只汇总出 1 条，且 [PASS]/[FAIL] 行与汇总行交错。改为「外层持有 stats，嵌套时
 * 内层用自己的 stats，结束后再回填到访问器」。
 * （这也正是自证用例的价值：它把骨架的这类内部状态问题逼了出来。） */
struct RunStats {
	int passed = 0;
	int failed = 0;
	int skipped = 0;
};

inline RunStats*& activeStats() {
	static RunStats* p = nullptr;
	return p;
}

/* 最近一次 runAll（含嵌套调用）的结果快照。为什么需要它：自证用例必须读到
 * **它自己那一次** runAll 的计数——返回值只表达失败数/无命中(-1)，区分不了
 * 「全跳过」与「全通过」（两者都是 0 失败）。 */
inline RunStats& lastStats() {
	static RunStats s;
	return s;
}

inline int& failureCount() { return lastStats().failed; }
inline int& passedCount() { return lastStats().passed; }
inline int& skippedCount() { return lastStats().skipped; }

/* 输出开关 + 唯一输出口：quiet 模式（自证用例嵌套调用 runAll）靠它静音，
 * 而不是重定向文件描述符。harness 自身的所有打印都必须走 out()。 */
inline bool& outputEnabled() {
	static bool b = true;
	return b;
}

template <typename... Args>
inline void out(const char* fmt, Args... args) {
	if (!outputEnabled()) { return; }
	if constexpr (sizeof...(Args) == 0) {
		/* 无参调用按纯文本走 fputs：fmt 非 string literal（-Wformat-security），
		 * 且 fmt 含 % 时被当格式符解析本就是隐患 */
		std::fputs(fmt, stdout);
	} else {
		std::printf(fmt, args...);
	}
}

inline bool& currentFailed() {
	static bool b = false;
	return b;
}

/* 当前用例已执行的断言数（runAll 每例清零，check/TH_CHECK_THROWS* 递增） */
inline int& currentChecks() {
	static int n = 0;
	return n;
}

/* TH_SKIP 的落地：置位并抛出一个内部异常，确保用例**立即**结束——
 * 不用 return 是因为 TH_SKIP 可能出现在嵌套块里，return 语义会因所在函数而异
 * （在 lambda 里 return 只是退出 lambda）。抛异常还能顺带禁止「skip 之后继续
 * 跑断言」这种自相矛盾的写法。 */
struct SkipSignal {};

inline void markSkipped(const char* reason, const char* file, int line) {
	th::out("       [SKIP] 原因: %s\n", reason);
	th::out("       位置:   %s:%d\n", file, line);
	/* 只在「跳过之前没跑过断言」时清失败位。修复前这里无条件
	 * `currentFailed() = false`，会把**已经发生的真实失败抹掉**——自证用例
	 * harness_rejects_assert_then_skip 抓到的就是这个：一条断言失败后再 TH_SKIP，
	 * 整条用例被洗成 [SKIP]。 */
	if (currentChecks() == 0) { currentFailed() = false; }
	throw SkipSignal{};
}

struct Registrar {
	Registrar(const std::string& name, std::function<void()> fn) {
		cases().push_back(Case{name, std::move(fn)});
	}
};

inline void reportFailure(const char* expr, const char* file, int line, const std::string& extra) {
	currentFailed() = true;
	if (activeStats() != nullptr) { ++activeStats()->failed; }
	th::out("       表达式: %s\n", expr);
	th::out("       位置:   %s:%d\n", file, line);
	if (!extra.empty()) { th::out("       说明:   %s\n", extra.c_str()); }
}

inline void check(bool ok, const char* expr, const char* file, int line) {
	++currentChecks();
	if (!ok) { reportFailure(expr, file, line, std::string()); }
}

/* 一次 runAll 的结果。rc 沿用历史约定：0 全通过 / 1 有失败 / -1 无匹配。 */
struct RunOutcome {
	int rc = 0;
	int passed = 0;
	int failed = 0;
	int skipped = 0;
};

/* 过滤器的作用域前缀（2026-09-21 审计 AG-11）。
 *
 * 起因：docs/agent.md 推荐的 `./build/mybot_tests agent` 依赖**子串**匹配，只命中
 * 用例名里含 "agent" 的那部分——`promptpack_*` / `llmconfig_*` / `cliargs_*` 这些
 * 同属 agent 配置面的用例全都不命中（实测 86/436，注释里却写着「proto / driver /
 * tools / loop / config」）。用例名里含不含 "agent" 是历史偶然，不是判据。
 *
 * 这里给出显式的名字→作用域映射：要么它在表里，要么不属于该作用域。表是单点，
 * 新增测试文件时补一行即可；scope 是显式清单而不是模糊匹配，所以不会像子串那样
 * 悄悄漏掉或误纳。
 * 用法：`./build/mybot_tests agent:xxx`（作用域内再按子串过滤）
 *       `./build/mybot_tests agent:`（整个作用域）
 */
struct ScopeEntry {
	const char* scope;
	const char* name;
};

inline const ScopeEntry* scopeTable(std::size_t& n) {
	static const ScopeEntry kTable[] = {
		/* agent 模式全表面：协议、工具、配置、CLI 选项面。
		 * （agentdriver_ 已随 C++ 传输层迁 Rust 删除；promptpack_ 已随提示词
		 * 拼装迁 Rust（agent/src/prompt.rs）删除，2026-10-01 批次 A。）
		 * 增删成员后必须让 test_util.cpp 的 roster 用例继续绿——它按**用例名前缀**
		 * 反查表的完备性：漏登记一整族用例（第三轮审计 AG-22 实测漏了 15 条
		 * agentconfig_/agentmode_）会立刻红，而不是静默少跑。 */
		{"agent", "agentproto_"}, {"agent", "agenttools_"},
		{"agent", "agentconfig_"},
		{"agent", "agentmode_"}, {"agent", "agentaudit_"}, {"agent", "agentpolicy_"},
		{"agent", "llmconfig_"}, {"agent", "cliargs_"},
		/* PL-2（2026-09-22）：动作脚本执行预算（luaexec 的 arm/disarm 与 JIT 复原）。
		 * 归 agent 面：这套机制只服务 run_action_script 一个调用点，
		 * 改坏了 agent-all 必须能红。 */
		{"agent", "luaexec_"},
		/* 批次 D（2026-09-25）后：会话持久化（sessionfile_ 系列）随 C++ 语义参考
		 * 一并清退——Rust 侧 agent/src/session.rs 是唯一实现，不再有 C++ 孪生
		 * 用例占这个作用域的名额（历史沿革见 git log -- src/agenthistory.*）。 */
		/* MCP 后端（--mcp-backend，方案 F / 拓扑 F3）：把工具层经 AF_UNIX 帧链路
		 * 暴露给 sidecar。归 agent 面：它复用 agent 的工具注册表与派发漏斗。 */
		{"agent", "mcpbackend_"},
	};
	n = sizeof(kTable) / sizeof(kTable[0]);
	return kTable;
}

/* 该用例是否属于 scope；scope 为空表示不过滤 */
inline bool caseInScope(const std::string& caseName, const std::string& scope) {
	if (scope.empty()) { return true; }
	std::size_t n = 0;
	const ScopeEntry* table = scopeTable(n);
	for (std::size_t i = 0; i < n; ++i) {
		if (scope == table[i].scope && caseName.rfind(table[i].name, 0) == 0) {
			return true;
		}
	}
	return false;
}

/* 运行全部用例。quiet=true 时不打印任何东西（自证用例内部嵌套调用 runAll 时用：
 * 子用例的输出若混进父用例的 [PASS]/[FAIL] 流，守门日志会看不出哪条是父用例的
 * 结论）。
 * 返回 RunOutcome 而不是裸 int：自证用例需要拿**这一次**运行的完整计数，而全局
 * 快照在多级嵌套下无法归属（见 harness_selftest）。 */
inline RunOutcome runAllOutcome(const std::string& filter, bool quiet = false) {
	/* 每次运行持有自己的 stats：嵌套调用（自证用例）不得抹掉外层的账。
	 * 上一版用「最外层才写 lastStats」的判据，结果内层运行读不到自己的计数
	 * ——自证用例因此全部读到 0。现在每次运行都更新快照，返回结构再
	 * 提供「这一次」的精确计数（调用方优先用返回值）。 */
	const bool outermost = (activeStats() == nullptr);
	RunStats mine;
	RunStats* const prevStats = activeStats();
	activeStats() = &mine;
	/* currentFailed/currentChecks 是「当前用例」的游标，**嵌套运行时必须
	 * 保存并恢复**：自证用例在自身用例体内调用 runAll，内层会把这些游标按内层
	 * 用例重置——不恢复就会把外层正在跑的那条用例的失败位与断言数抹掉，症状是
	 * 外层用例莫名被判零断言/通过（自证用例第一版全部读到错值，根因在此）。 */
	const bool savedFailed = currentFailed();
	const int savedChecks = currentChecks();
	/* quiet：临时关掉输出开关。**不用 freopen 重定向 stdout**——那会关掉原
	 * fd，恢复只能重开 /dev/tty，在无 tty 的守门环境里必然失败。开关方式可精确
	 * 恢复，且所有输出都走 out() 这一处（见上）。 */
	const bool savedOut = outputEnabled();
	outputEnabled() = !quiet;
	/* 过滤器语法：`scope:子串` 或裸子串（后者保持历史语义，向后兼容）。
	 * scope 走显式映射表（见 caseInScope），子串沿用 find。 */
	std::string scope, needle = filter;
	if (const std::size_t colon = filter.find(':'); colon != std::string::npos) {
		scope = filter.substr(0, colon);
		needle = filter.substr(colon + 1);
	}
	for (const Case& c : cases()) {
		if (!caseInScope(c.name, scope)) { continue; }
		if (!needle.empty() && c.name.find(needle) == std::string::npos) { continue; }
		currentFailed() = false;
		currentChecks() = 0;
		bool skippedCase = false;
		try {
			c.fn();
		} catch (const SkipSignal&) {
			skippedCase = true;
		} catch (const std::exception& e) {
			reportFailure("(未捕获异常)", __FILE__, 0,
				std::string("用例抛出异常: ") + e.what());
		} catch (...) {
			reportFailure("(未捕获异常)", __FILE__, 0, "用例抛出非 std 异常");
		}
		if (skippedCase) {
			if (currentChecks() == 0 && !currentFailed()) {
				th::out("[SKIP] %s\n", c.name.c_str());
				++mine.skipped;
				continue;
			}
			/* 半跑半跳过（或跳过前已失败）：语义矛盾，**记失败**而不是洗成跳过。
			 * 修复前这里只 reportFailure 一句就 continue，失败数不增——自证用例
			 * 因此抓到「断言后 TH_SKIP」被判成 0 失败 1 跳过。 */
			if (currentChecks() > 0) {
				reportFailure("TH_SKIP 之前已执行断言",
					__FILE__, 0,
					"该用例跑了 " + std::to_string(currentChecks())
						+ " 条断言后又声明跳过；要么让它跑完，要么把断言挪到"
						  "环境判据之后");
			}
			th::out("[FAIL] %s\n", c.name.c_str());
			continue;	/* failed 已由 reportFailure 记入 stats */
		}
		if (!currentFailed() && currentChecks() == 0) {
			/* 零断言：既没失败也没验证任何东西——静默通过最危险，判失败并要求
			 * 显式表态（补断言，或按环境换成 TH_SKIP("原因")）。 */
			reportFailure("(零断言)",
				__FILE__, 0,
				"该用例一条断言都没执行就结束了。若确实依赖环境，请在环境判据处"
				"调用 TH_SKIP(\"原因\")（会记 [SKIP]），不要静默 return");
		}
		if (currentFailed()) {
			th::out("[FAIL] %s\n", c.name.c_str());
		} else {
			th::out("[PASS] %s\n", c.name.c_str());
			++mine.passed;
		}
	}
	activeStats() = prevStats;
	currentFailed() = savedFailed;
	currentChecks() = savedChecks;
	/* 全局快照只由**最外层**运行更新，代表「这个二进制这次跑出来的结果」；
	 * 嵌套运行（自证用例）要拿自己那一次的计数请直接用 runAllOutcome 的返回值，
	 * 不要去读全局——两者语义不同，混用会出现「读数归属错误」那类难查问题。 */
	if (outermost) { lastStats() = mine; }
	/* 注意顺序：汇总与 [DONE] 必须在**恢复输出开关之前**。第一版把恢复放在
	 * 这里（汇总之前），于是 quiet 模式下 [PASS]/[FAIL] 被吞掉、汇总行却照样
	 * 打出来——自证用例的输出里混进一串「C++ 单测: ...」摘要。静音必须整段
	 * 静音；这个疏漏自证用例抓不到（它只断言返回码与计数），是看输出发现的。 */
	if (mine.skipped > 0) {
		th::out("C++ 单测: %d 通过, %d 失败, %d 跳过\n", mine.passed, mine.failed, mine.skipped);
	} else {
		th::out("C++ 单测: %d 通过, %d 失败\n", mine.passed, mine.failed);
	}
	/* 只有「一条用例都没命中」才是无匹配。跳过**算命中**——全部跳过（例如整段
	 * 依赖真机设备）不该被报成「过滤器拼错」，否则 run_all 的空匹配防线会
	 * 对 skip 产生误报。修复前此处只看 passed+failure，全跳过的过滤会返回 -1
	 * （自证用例 harness_skip_is_not_a_failure 抓到的就是这个）。 */
	if (mine.passed + mine.failed + mine.skipped == 0) {
		th::out("       无匹配用例（过滤器 '%s' 未命中，请检查拼写）\n", filter.c_str());
		outputEnabled() = savedOut;
		return RunOutcome{-1, mine.passed, mine.failed, mine.skipped};
	}
	th::out("[DONE]\n");
	outputEnabled() = savedOut;	/* 汇总打完才恢复（见上） */
	/* C10（2026-09-20 审计）：退出码只能是 0/1，**不能**是失败用例数——进程
	 * 退出状态被 OS 截断到 8 位，256 个失败会恰好回绕成 0（实测 256 用例全红
	 * 时 `ctest -R cpp_unit` 报 "100% tests passed"）。run_all.sh 有 [FAIL]
	 * grep 兜底不受影响，但文档推荐的逐用例入口 ctest 会假绿。
	 * 约定：0 = 全通过；1 = 有失败（或过滤器无命中）。 */
	outputEnabled() = savedOut;	/* 汇总打完才恢复（见上） */
	return RunOutcome{mine.failed == 0 ? 0 : 1, mine.passed, mine.failed, mine.skipped};
}

/* 薄封装：main 里只关心退出码的老用法保持不变 */
inline int runAll(const std::string& filter, bool quiet = false) {
	return runAllOutcome(filter, quiet).rc;
}

} // namespace th

#define TH_TEST(name) \
	static void name(); \
	static ::th::Registrar th_reg_##name(#name, &name); \
	static void name()

#define TH_CHECK(expr) ::th::check(static_cast<bool>(expr), #expr, __FILE__, __LINE__)

/* 断言 expr，失败时附自定义说明——用于「遍历集合并点名具体违例项」的断言，
 * 否则失败信息只有表达式文本，看不出是哪一个元素越界/缺失。 */
#define TH_CHECK_MSG(expr, msg)                                            \
	do {                                                                \
		++::th::currentChecks();                                        \
		if (!static_cast<bool>(expr)) {                                 \
			::th::reportFailure(#expr, __FILE__, __LINE__, (msg));      \
		}                                                               \
	} while (false)

/* 断言 expr 抛出 Exc 类型异常（负路径契约的主力） */
#define TH_CHECK_THROWS(Exc, expr)                                        \
	do {                                                                \
		++::th::currentChecks();                                        \
		bool th_threw_ = false;                                         \
		try { (void)(expr); }                                           \
		catch (const Exc&) { th_threw_ = true; }                        \
		catch (const std::exception& th_e_) {                           \
			::th::reportFailure(#expr, __FILE__, __LINE__,              \
				std::string("抛出了错误类型，期望 ") + #Exc + "，实际 std::exception: " + th_e_.what()); \
			th_threw_ = true;                                           \
		}                                                               \
		if (!th_threw_) {                                               \
			::th::reportFailure(#expr, __FILE__, __LINE__,              \
				std::string("未抛出任何异常，期望 ") + #Exc);           \
		}                                                               \
	} while (false)

/* 断言 expr 抛 Exc 且 what() 含 sub（校验「清晰报错」而非裸崩） */
#define TH_CHECK_THROWS_MSG(Exc, sub, expr)                               \
	do {                                                                \
		++::th::currentChecks();                                        \
		bool th_threw_ = false;                                         \
		try { (void)(expr); }                                           \
		catch (const Exc& th_e_) {                                      \
			th_threw_ = true;                                           \
			if (std::string(th_e_.what()).find(sub) == std::string::npos) { \
				::th::reportFailure(#expr, __FILE__, __LINE__,          \
					std::string("报错文本不含 \"") + sub + "\"，实际: " + th_e_.what()); \
			}                                                           \
		}                                                               \
		if (!th_threw_) {                                               \
			::th::reportFailure(#expr, __FILE__, __LINE__,              \
				std::string("未抛出任何异常，期望 ") + #Exc);           \
		}                                                               \
	} while (false)

/* 显式跳过：环境不满足时用它代替静默 return。必须给原因（会打进输出，
 * 让守门日志能回答「为什么这条没跑」）。用法：
 *     if (::getrlimit(...) != 0) { TH_SKIP("无法读取 RLIMIT_NOFILE"); }
 * 注意：TH_SKIP 之前的断言数必须为 0（否则判失败——半跑半跳过语义矛盾）。 */
#define TH_SKIP(reason) ::th::markSkipped((reason), __FILE__, __LINE__)
