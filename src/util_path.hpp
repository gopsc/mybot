#pragma once
/* util_path.hpp —— 路径单点：Lua 驱动模块根目录搜索（BOT4CJ_MODULE_PATH）与相对路径
 * 安全判据（目录穿越/绝对路径/NUL）（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <array>
#include <cstddef>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include <unistd.h>

#include "util_env.hpp"	/* modulePaths 用 getEnvVar */

namespace bot {

/* 安装布局下的模块根：<prefix>/bin/mybot → <prefix>/share/mybot/modules。
 * 只读 /proc/self/exe，不依赖 CWD；找不到时返回空串。 */
inline std::string installedModulePath() {
	std::array<char, 4096> buffer{};
	const ssize_t n = ::readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
	if (n <= 0) { return std::string(); }
	std::string exe(buffer.data(), static_cast<std::size_t>(n));
	const std::size_t slash = exe.rfind('/');
	if (slash == std::string::npos) { return std::string(); }
	const std::string candidate = exe.substr(0, slash) + "/../share/mybot/modules";
	if (::access(candidate.c_str(), F_OK) != 0) { return std::string(); }
	/* 规范化掉 bin/../share 里的 '..'：Lua 沙箱路径校验明确拒绝该分量。 */
	std::array<char, 4096> resolved{};
	if (::realpath(candidate.c_str(), resolved.data()) != nullptr) {
		return std::string(resolved.data());
	}
	return candidate;
}

/* N-19：Lua 驱动模块根目录——BOT4CJ_MODULE_PATH（':' 分段）。
 * 未显式设置时优先当前目录的 ./modules（仓库/开发用法），不存在再回退安装布局
 * 的 share/mybot/modules；两者都没有则保留 ./modules 作为报错路径。 */
inline std::string modulePaths() {
	auto v = getEnvVar("BOT4CJ_MODULE_PATH");
	if (v && !v->empty()) { return *v; }
	if (::access("./modules", F_OK) == 0) { return "./modules"; }
	const std::string installed = installedModulePath();
	return installed.empty() ? "./modules" : installed;
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
