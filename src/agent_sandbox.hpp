#pragma once
/* agent_sandbox.hpp —— 通用「根目录白名单」路径解析（Phase 1，2026-10-07）
 *
 * 缺口（调研结论，见 .zcode/plans 同日计划文件）：本仓已有两套路径沙箱，但都不是
 * 通用的「canonical 根目录包含性」判据：
 *   - `resolveActionScriptPath`（agentview.cpp）只做**词法**校验（`checkRelPath` +
 *     `.mt` 后缀白名单），不查符号链接是否把访问点引出 scriptsDir——真正的防线是
 *     打开时的 `O_NOFOLLOW`（只挡最后一段，中间目录软链仍可穿过，残余与既有声明
 *     一致，见 util_file.hpp 头注）。
 *   - `capture_image` 的 `camera_src_dir` 白名单其实在 **Lua** 侧
 *     （`modules/Camera.lua` 的 `path_within` + `realpath` 前缀比较），C++ 侧只是
 *     传参，不做判定。
 * 两者形态不同、各自独立实现，不构成「新增一个 host 文件工具」可以直接复用的通用
 * 单点。本文件补上这一个：`resolveUnderRoot`——给定一个 canonical 的 root 与一个
 * 声称的相对路径 requested，判定 requested 是否（词法 + 语义）落在 root 之下，
 * 供未来的 `read_file`/`write_file`/`list_dir` 等通用工具复用，不再各自发明一套。
 *
 * 判据分两层：
 *   1) 词法层：复用 `checkRelPath`（绝对路径 / NUL / 空段 / `.` / `..` 一律拒绝，
 *      发生在任何文件系统访问之前，与 `resolveActionScriptPath` 同一判据来源）。
 *   2) 语义层：root 必须是一个真实存在的目录（否则是**配置**错误，不是**请求**
 *      错误——「配置错误不碰真机」的既有口径，这里是其文件系统版）；requested
 *      拼接到 root 之后，沿路径逐级回退找到**已存在的最长前缀**做 `canonical`
 *      （写文件场景：目标文件可能还不存在，但其所有已存在的祖先目录必须真的在
 *      root 之下——这样即使 root/evil -> /etc 这类符号链接目录下的文件尚未创建，
 *      仍能在父目录这一级被拦下，不必等到 open() 才发现逃逸）。
 *
 * 本函数只管「路径本身是否在 root 之下」，不替调用方做存在性/类型/权限判断，也不
 * 取代 open() 时的 `O_NOFOLLOW`——两层防线职责不同（这里挡的是「目录级」逃逸，
 * `O_NOFOLLOW` 挡的是「目标文件本身是符号链接」），同时具备才完整，见
 * `readFdNoFollowLimited`（util_file.hpp）。 */

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <system_error>
#include <unistd.h>

#include "util_file.hpp"	/* retryEintr（write 循环的 EINTR 重试单点） */
#include "util_path.hpp"	/* checkRelPath / RelPathCheck */

namespace bot {
namespace agent {

enum class SandboxCheck {
	OK,
	ABSOLUTE,     /* requested 以 '/' 开头 */
	NUL,          /* requested 含 '\0' */
	EMPTY_OR_DOT, /* requested 为空，或含空段 / '.' 段 */
	DOTDOT,       /* requested 含 '..' 段 */
	ROOT_MISSING, /* root 本身不是一个真实存在的目录（配置错误） */
	ESCAPES_ROOT, /* requested 的已存在前缀 canonical 后不在 root 之下（符号链接逃逸等） */
};

struct SandboxResult {
	SandboxCheck check = SandboxCheck::OK;
	/* check==OK 时：root 下的完整路径（lexically_normal，未对目标本身 canonical——
	 * 目标是否存在、是否是符号链接，留给调用方按自己的读/写语义决定，通常是
	 * open() 时再加 O_NOFOLLOW）。check!=OK 时为空。 */
	std::string resolved;
};

inline SandboxResult resolveUnderRoot(const std::string& root, const std::string& requested) {
	SandboxResult r;

	switch (checkRelPath(requested)) {
	case RelPathCheck::ABSOLUTE:     r.check = SandboxCheck::ABSOLUTE;     return r;
	case RelPathCheck::NUL:          r.check = SandboxCheck::NUL;          return r;
	case RelPathCheck::EMPTY_OR_DOT: r.check = SandboxCheck::EMPTY_OR_DOT; return r;
	case RelPathCheck::DOTDOT:       r.check = SandboxCheck::DOTDOT;       return r;
	case RelPathCheck::OK: break;
	}

	namespace fs = std::filesystem;
	std::error_code ec;
	fs::path canonicalRoot = fs::canonical(root, ec);
	if (ec || !fs::is_directory(canonicalRoot, ec) || ec) {
		r.check = SandboxCheck::ROOT_MISSING;
		return r;
	}

	fs::path full = canonicalRoot / requested;
	/* 回退到「已存在的最长前缀」：写文件场景目标还没创建，但它所有已存在的
	 * 祖先目录都必须真的在 root 之下——root 本身总是存在，循环必然终止。 */
	fs::path probe = full;
	while (!probe.empty() && !fs::exists(probe, ec)) {
		fs::path parent = probe.parent_path();
		if (parent == probe) { break; }	/* 到达根 "/"，防死循环 */
		probe = parent;
	}
	fs::path canonicalProbe = fs::canonical(probe, ec);
	if (ec) {
		r.check = SandboxCheck::ESCAPES_ROOT;
		return r;
	}

	const std::string rootStr = canonicalRoot.string();
	const std::string probeStr = canonicalProbe.string();
	const bool within = probeStr == rootStr
		|| (probeStr.size() > rootStr.size()
			&& probeStr.compare(0, rootStr.size(), rootStr) == 0
			&& probeStr[rootStr.size()] == fs::path::preferred_separator);
	if (!within) {
		r.check = SandboxCheck::ESCAPES_ROOT;
		return r;
	}

	r.check = SandboxCheck::OK;
	r.resolved = full.lexically_normal().string();
	return r;
}

/* ---- 原子写入（Phase 5，2026-10-08）：write_file 的唯一写原语 ----
 * fullPath 必须已经过 resolveUnderRoot 校验（本函数不重复判沙箱，只管"怎么
 * 把内容安全地落到这一个已核准的路径上"）。
 *
 * 语义（对外承诺见 docs/agent.md 安全说明第 14 条；落地时比原计划更严的一处修正
 * 见实现要点 5）：
 *   - 目标不存在 → 创建；目标存在且 overwrite=false → 拒绝（不静默覆盖）；
 *     目标存在且 overwrite=true → 覆盖，但走"临时文件 + rename"而不是
 *     O_TRUNC 原地改写——半写失败时不留半截文件。
 *   - 目标本身是符号链接 → 无论 overwrite 为何一律拒绝（不跟随写入）。
 *     理由：跟随写入等于让根目录里的一条软链把写操作重定向到根外——这比
 *     读更危险的逃逸（读只是泄露，写可以覆盖任意可写文件），resolveUnderRoot
 *     只挡"目录级"逃逸，这里补上"目标文件本身是软链"这最后一级。
 *
 * 实现要点：
 *   1) lstat 判目标存在性/是否软链——这只是前置判断，不是 check-then-use 的
 *      唯一防线：真正的防线是临时文件 open() 的 O_NOFOLLOW（若目标不是软链、
 *      而是在 lstat 之后被换成了软链，最终 link/rename 替换的是"那个名字"而
 *      不是"跟随软链写入"，不会逃逸，只是用户观感上"覆盖"变成了"换掉那个
 *      软链本身"——而这恰是上面"目标是软链一律拒绝"要提前挡掉的情形，故这里
 *      的判断仍是必要的第一道拒绝点，不是摆设）。
 *   2) 临时文件名 = fullPath + ".mybot-tmp-" + 随机后缀，与目标同目录（保证
 *      `rename`/`link` 在同一文件系统内，这是其原子性的前提）。
 *   3) `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`：O_EXCL 防临时文件名
 *      刚好撞车（概率极低，EEXIST 时换后缀重试几次）。
 *   4) 循环 write（EINTR 经 retryEintr 单点）写完全部内容；任何失败路径都
 *      unlink 临时文件（最大努力，不因清理失败掩盖原始错误）。
 *   5) 落地（对计划③的修正）：overwrite=true 用 `rename`（POSIX 原子替换，
 *      不需要先 unlink 目标）；**overwrite=false 用 `link` 而不是 rename**——
 *      rename 对已存在目标是**无条件原子替换**，若在①的 lstat 之后、rename
 *      之前有另一个写者抢先创建了 fullPath，rename 会静默覆盖它（TOCTOU），
 *      彻底违反"不覆盖"的承诺；link 的 POSIX 语义是"目标已存在则失败并置
 *      EEXIST，否则原子创建"，正是"不存在才创建"的原子判据。两种路径下
 *      fullPath 若被换成符号链接，link/rename 替换的都是那个链接名本身（不
 *      跟随），与要点①②一致。
 *   不做 fsync（已知限制，见 phase5 计划"已知限制"节）：断电场景下落地
 *   之前的内容可能未落盘，但落地本身的原子性仍成立（不会出现"目标内容
 *   新旧混合"的半写状态），与审计日志等既有文件 I/O 的持久性承诺一致。 */
struct AtomicWriteResult {
	bool ok = false;
	std::string error;	/* ok=false 时的人话原因 */
};

inline std::string mybotTempSuffixForWrite() {
	/* pid + 纳秒时间戳 + 进程内计数器：三者组合足够避免同进程内撞车；
	 * 跨进程的极小概率残余由 O_EXCL + 重试兜底，不依赖这里绝对唯一。 */
	static std::atomic<unsigned long> counter{0};
	const unsigned long c = ++counter;
	struct timespec ts{};
	::clock_gettime(CLOCK_REALTIME, &ts);
	char buf[64];
	std::snprintf(buf, sizeof buf, "%d-%lx-%lx",
		static_cast<int>(::getpid()),
		static_cast<unsigned long>(ts.tv_nsec), c);
	return buf;
}

inline AtomicWriteResult writeFileAtomic(const std::string& fullPath,
		const std::string& content, bool overwrite) {
	AtomicWriteResult r;

	struct stat st{};
	const bool exists = (::lstat(fullPath.c_str(), &st) == 0);
	if (exists) {
		if (S_ISLNK(st.st_mode)) {
			r.error = "目标是符号链接，拒绝写入（不跟随软链，避免被定向到根目录之外）";
			return r;
		}
		if (!overwrite) {
			r.error = "目标已存在，如需覆盖请传 overwrite=true（覆盖是不可逆操作）";
			return r;
		}
	}

	std::string tmp;
	int fd = -1;
	for (int attempt = 0; attempt < 8 && fd < 0; ++attempt) {
		tmp = fullPath + ".mybot-tmp-" + mybotTempSuffixForWrite();
		fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
		if (fd < 0 && errno != EEXIST) {
			r.error = std::string("创建临时文件失败: ") + std::strerror(errno);
			return r;
		}
	}
	if (fd < 0) {
		r.error = "创建临时文件失败：多次重试后仍与既有文件撞名";
		return r;
	}

	const char* data = content.data();
	std::size_t written = 0;
	const std::size_t total = content.size();
	while (written < total) {
		const char* p = data + written;
		const std::size_t want = total - written;
		ssize_t n = retryEintr([fd, p, want]{ return ::write(fd, p, want); });
		if (n < 0) {
			const std::string werr = std::string("写入失败: ") + std::strerror(errno);
			::close(fd);
			::unlink(tmp.c_str());
			r.error = werr;
			return r;
		}
		if (n == 0) { break; }	/* 不应发生于普通文件，防御性退出避免死循环 */
		written += static_cast<std::size_t>(n);
	}
	if (::close(fd) != 0) {
		const std::string cerr = std::string("关闭临时文件失败: ") + std::strerror(errno);
		::unlink(tmp.c_str());
		r.error = cerr;
		return r;
	}
	if (overwrite) {
		/* rename 对已存在目标是原子替换（POSIX 保证），天然实现"覆盖"语义；
		 * 不需要先 unlink 目标。 */
		if (::rename(tmp.c_str(), fullPath.c_str()) != 0) {
			const std::string rerr = std::string("原子替换失败: ") + std::strerror(errno);
			::unlink(tmp.c_str());
			r.error = rerr;
			return r;
		}
	} else {
		/* overwrite=false 的真正原子性在这里：上面①的 lstat 只是前置判断，
		 * 之后到现在这段时间窗口里，另一个写者完全可能抢先创建了 fullPath
		 * （TOCTOU）——若这里用 rename()，POSIX 语义是"原子替换"，会**无条件
		 * 覆盖**那个刚出现的文件，彻底违反"不覆盖"的承诺（rename 不检查
		 * "目标是否已存在"这件事本身，它的原子性只保证"替换瞬间不会看到半个
		 * 文件"，不保证"目标之前没有被别人创建过"）。
		 * 改用 link()：POSIX 保证"若 fullPath 已存在则失败并置 EEXIST，否则
		 * 原子创建一个指向 tmp 内容的新目录项"——这正是"不存在才创建"的原子
		 * 判据，而 rename 没有对应的"仅当不存在才替换"变体。link 成功后 tmp
		 * 这个名字就只是多余的硬链接，unlink 掉（内容仍在，因为 fullPath
		 * 那个硬链接还指着同一个 inode）。 */
		if (::link(tmp.c_str(), fullPath.c_str()) != 0) {
			const std::string lerr = (errno == EEXIST)
				? std::string("目标已存在，如需覆盖请传 overwrite=true（覆盖是不可逆操作）")
				: std::string("创建失败: ") + std::strerror(errno);
			::unlink(tmp.c_str());
			r.error = lerr;
			return r;
		}
		::unlink(tmp.c_str());	/* 内容已在 fullPath（硬链接），这个临时名字可以丢了 */
	}
	r.ok = true;
	return r;
}

} // namespace agent
} // namespace bot
