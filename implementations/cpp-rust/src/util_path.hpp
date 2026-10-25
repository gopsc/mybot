#pragma once
/* util_path.hpp —— 路径单点：Lua 驱动模块根目录搜索（BOT4CJ_MODULE_PATH）与相对路径
 * 安全判据（目录穿越/绝对路径/NUL）（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <cstddef>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "util_env.hpp"	/* modulePaths 用 getEnvVar */

namespace bot {

/* N-19：Lua 驱动模块根目录——BOT4CJ_MODULE_PATH（':' 分段），缺省 ./modules。
 * 此前宿主三处各自读取（luaend 白名单 / daemonvar chunk / robot 驱动脚本），
 * 其中 luaend 还是手工 getenv、空串语义与另两处不一致，收敛单点。 */
inline std::string modulePaths() {
	auto v = getEnvVar("BOT4CJ_MODULE_PATH");
	return (v && !v->empty()) ? *v : "./modules";
}

/* ':' 分段切分模块路径：去空段、剥尾斜杠（审计 #7 同源：fail-closed 白名单
 * 里尾斜杠分段会静默失效），单独 "/" 段保留原样。 */
inline std::vector<std::string> splitModulePaths(const std::string& paths) {
	std::vector<std::string> out;
	std::size_t b = 0;
	while (b <= paths.size()) {
		std::size_t e = paths.find(':', b);
		std::string p = (e == std::string::npos) ? paths.substr(b) : paths.substr(b, e - b);
		if (e == std::string::npos) { b = paths.size() + 1; } else { b = e + 1; }
		while (p.size() > 1 && p.back() == '/') { p.pop_back(); }
		if (!p.empty()) { out.push_back(std::move(p)); }
	}
	return out;
}

/* 多模块路径逐段探测（2026-09-20 重构阶段 2）：在 paths（':' 分段）下按序找
 * 第一个存在的 rel，返回规范化后的完整路径；全部不存在返回 nullopt。
 * 与 Lua 侧 modules/lib/mpath.lua 的 mpath.resolve 同语义，是宿主侧的单点
 *（此前 daemonvar 的 firstExistingModule 与 hw_factory 各自实现，Lua 侧更是
 * 59 个驱动各自用 ":match('[^:]+')" 只取首段——多路径承诺因此对驱动不成立）。 */
inline std::optional<std::string> findExistingModule(const std::string& paths,
		const std::string& rel) {
	for (const std::string& p : splitModulePaths(paths)) {
		std::string cand;
		cand.reserve(p.size() + 1 + rel.size());
		cand += p;
		cand += '/';
		cand += rel;
		std::ifstream f(cand, std::ios::binary);
		if (f.good()) { return cand; }
	}
	return std::nullopt;
}

/* ---- 相对路径段判据（M2/B2-1 单点，2026-09-20）----
 * 「对相对路径逐 '/' 段判定」此前散落三处：agenttools::resolveActionScriptPath、
 * mtinclude::validateIncludePath、luasandbox 的 hasDotDotComponent——前两者整段
 * 逐字相似，第三份只判 '..'。判据是安全边界（越出目录遍历/脚本目录穿越），
 * 复制即漂移，收敛到此；各调用方保留自己的报错文案（grep 守门锚定不共享）。
 * 只判不抛：返回枚举，错误文案留给调用方。 */
enum class RelPathCheck {
	OK,          /* 无非法段 */
	ABSOLUTE,    /* 以 '/' 开头（拒绝绝对路径） */
	EMPTY_OR_DOT,/* 空段或 '.' 段（含 "a//b"、"a/./b"） */
	DOTDOT,      /* 含 '..' 段（目录穿越） */
	NUL,         /* 含 '\0' */
};
inline RelPathCheck checkRelPath(const std::string& s) {
	if (s.empty()) { return RelPathCheck::EMPTY_OR_DOT; }
	if (s[0] == '/') { return RelPathCheck::ABSOLUTE; }
	if (s.find('\0') != std::string::npos) { return RelPathCheck::NUL; }
	std::size_t b = 0;
	while (b <= s.size()) {
		std::size_t e = s.find('/', b);
		std::size_t len = (e == std::string::npos) ? s.size() - b : e - b;
		if (len == 0 || (len == 1 && s[b] == '.')) { return RelPathCheck::EMPTY_OR_DOT; }
		if (len == 2 && s[b] == '.' && s[b + 1] == '.') { return RelPathCheck::DOTDOT; }
		if (e == std::string::npos) { break; }
		b = e + 1;
	}
	return RelPathCheck::OK;
}
/* '..' 判定（按 '/'-段精确比较，不误伤含 '..' 子串的合法名，如 foo..bar.lua）。
 * luasandbox 专用：这里的判定**不看**绝对前缀——模块路径白名单本身可能以绝对
 * 路径打头，'..' 穿越才是要挡的，故独立全段扫描，不复用 checkRelPath 的
 * ABSOLUTE 短路（否则绝对路径下的 '..' 会漏网）。 */
inline bool hasDotDotComponent(const std::string& s) {
	std::size_t b = 0;
	while (b <= s.size()) {
		std::size_t e = s.find('/', b);
		std::size_t len = (e == std::string::npos) ? s.size() - b : e - b;
		if (len == 2 && s[b] == '.' && s[b + 1] == '.') { return true; }
		if (e == std::string::npos) { break; }
		b = e + 1;
	}
	return false;
}

} // namespace bot
