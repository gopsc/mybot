#pragma once
/* util_file.hpp —— 文件/_fd I/O 单点：fd RAII 守卫、受限读取（Reject/Truncate 两策略
 * + O_NOFOLLOW 防线）、EINTR 重试（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <fcntl.h>
#include <mutex>
#include <set>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace bot {

/* ---- fd RAII 守卫（F-25 同族：持 fd 者禁止拷贝）----
 * 此前 actionsource.cpp 与 mcpbackend.cpp 各持一份文件私有同名类
 * （mcpbackend 的注释自认「独立一份，避免抽公共头」）——两份守卫语义
 * 已经分叉出一处方法差异，继续复制只会更散。持 fd 的任何出口
 * （throw/return/分配失败）都靠它自动收口。 */
class FdGuard {
	int fd_;

public:
	explicit FdGuard(int fd = -1) : fd_(fd) {}
	~FdGuard() { close(); }
	FdGuard(const FdGuard&) = delete;
	FdGuard& operator=(const FdGuard&) = delete;
	/* 移动：交出所有权（源置空，析构不再关闭）——RAII 守卫得以从辅助
	 * 函数按值返回（拆分 openTcpActionSource 的前提） */
	FdGuard(FdGuard&& other) noexcept : fd_(other.fd_) { other.fd_ = -1; }
	FdGuard& operator=(FdGuard&& other) noexcept {
		if (this != &other) { close(); fd_ = other.fd_; other.fd_ = -1; }
		return *this;
	}

	int get() const { return fd_; }

	/* 关闭当前持有的 fd（空则无操作） */
	void close() {
		if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
	}

	/* 接管新 fd：先关闭旧的（accept 重试轮之间用） */
	void reset(int fd) { close(); fd_ = fd; }

	/* 交还所有权：仅在接管方已确定持有该 fd 后调用，此后守卫不再负责关闭 */
	int release() { int f = fd_; fd_ = -1; return f; }
};

/* ---- 受限读取：策略 + 单点实现（B2-3 余部，2026-09-21）----
 * 收敛前「带上限地读一个文件」有 4 份实现，超限语义分叉：提示词包响亮拒绝，
 * 而配置与密钥文件**静默截断**后交给下游——用户看到的是「不是合法 JSON」
 * 「密钥错误」，真实成因（文件过大）完全丢失，是排障里最难查的一类。
 * 2026-09-20 先把整文件读取统一为 Reject；2026-09-21 把最后一处独立实现
 * （agentmode 的 readHead：提示词预算，截断是刻意的）也并进来，超限语义改由
 * CapPolicy 显式声明，实现只剩这一份。
 *   Reject  —— 读满 cap 后再探测 1 字节，超限即失败（配置/密钥/提示词包）
 *   Truncate—— 读满 cap 即停，正常返回（结构脚本头摘录等提示词预算）
 * 错误文案留在各调用方（grep 守门锚定各处原文），本函数只回状态。
 * followSymlinks=false（缺省）走 O_NOFOLLOW 防线（一步 open，不做
 * lstat→open 的 check-then-use）；Truncate 的调用方传 true 以保持其既有语义
 * （路径来自 CLI，非远程动作源）。注：O_NOFOLLOW 只看最后一段，中间目录软链
 * 仍可被穿过——残余与旧声明相同。 */
enum class CapPolicy { Reject, Truncate };

enum class CapReadStatus {
	OK,           /* 成功（Truncate 时可能已按 cap 截断） */
	TOO_LARGE,    /* 仅 Reject：文件大于 cap */
	OPEN_FAILED,  /* 打不开（含被 O_NOFOLLOW 拒绝的符号链接） */
	READ_FAILED,  /* 读中途出错；已读到的部分保留在 out 里 */
};

inline CapReadStatus readFileCapped(const std::string& path, std::size_t cap, CapPolicy policy,
		std::string& out, bool followSymlinks = false) {
	out.clear();
	int flags = O_RDONLY | O_CLOEXEC;
	if (!followSymlinks) { flags |= O_NOFOLLOW; }
	int fd = ::open(path.c_str(), flags);
	if (fd < 0) { return CapReadStatus::OPEN_FAILED; }
	std::array<char, 8192> buf;
	for (;;) {
		if (out.size() >= cap) {
			if (policy == CapPolicy::Truncate) { break; }
			/* 已读满 cap 后再探测 1 字节即可判定超限（无需读完整个文件） */
			char probe = 0;
			ssize_t n = ::read(fd, &probe, 1);
			if (n > 0) {
				::close(fd);
				return CapReadStatus::TOO_LARGE;
			}
			break;
		}
		std::size_t want = buf.size();
		if (want > cap - out.size()) { want = cap - out.size(); }
		ssize_t n = ::read(fd, buf.data(), want);
		if (n < 0) {
			if (errno == EINTR) { continue; }
			::close(fd);
			return CapReadStatus::READ_FAILED;
		}
		if (n == 0) { break; }
		out.append(buf.data(), static_cast<std::size_t>(n));
	}
	::close(fd);
	return CapReadStatus::OK;
}

/* 整文件受限读取（Reject 策略的薄封装）：保留原有两句报错锚点
 * 「无法打开<what> …」与「<what> … 超过字节上限 N」；
 * what 只影响报错主体名（"文件" / "提示词文件" / "密钥文件"）。 */
inline bool readWholeFileLimited(const std::string& path, std::size_t cap,
		std::string& out, std::string& err, const char* what = "文件") {
	switch (readFileCapped(path, cap, CapPolicy::Reject, out)) {
	case CapReadStatus::OK:
		return true;
	case CapReadStatus::TOO_LARGE:
		err = std::string(what) + " " + path + " 超过字节上限 " + std::to_string(cap);
		break;
	default:
		/* OPEN_FAILED 与 READ_FAILED 同文案：与收敛前实现逐字一致 */
		err = std::string("无法打开") + what + " " + path;
		break;
	}
	return false;
}

/* ---- 受限 FD 读取（M2/B2-3 单点，2026-09-20）----
 * agenttools::readFileLimited 与 mtinclude::readIncludeFile 此前是同一骨架的
 * 两份拷贝（open 三旗 + 8192 循环 + EINTR + 上限），只报错文案不同——
 * 读放大/软链穿越判据漂移即防线不一致，收敛到此。
 * 只读、超限即停；**不抛错**——错误文案留在调用方（grep 守门锚定各处原文）。
 * totalBytes：非空时累计已读字节（mtinclude 的多文件总量预算用）；
 * totalCap 与 totalBytes 同用（0 表示不校验总量）。
 * 注：O_NOFOLLOW 只看最后一段（中间目录软链仍可被穿过）——残余与旧声明相同，
 * 能写 script 目录的进程本就能直接放真文件，不构成增量能力。 */
enum class FdReadStatus {
	OK,              /* 读满成功 */
	SYMLINK,         /* open 被 O_NOFOLLOW 拒绝（符号链接 ELOOP） */
	OPEN_FAILED,     /* open 其他失败 */
	READ_FAILED,     /* read 失败 */
	TOO_LARGE,       /* 超过单文件上限 */
	TOTAL_TOO_LARGE, /* 累计超过总量上限 */
};
inline FdReadStatus readFdNoFollowLimited(const std::string& path, std::size_t cap,
		std::string& out, std::size_t* totalBytes = nullptr, std::size_t totalCap = 0) {
	out.clear();
	int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		if (errno == ELOOP) { return FdReadStatus::SYMLINK; }
		return FdReadStatus::OPEN_FAILED;
	}
	std::array<char, 8192> buf;
	for (;;) {
		ssize_t n = ::read(fd, buf.data(), buf.size());
		if (n < 0) {
			if (errno == EINTR) { continue; }
			::close(fd);
			return FdReadStatus::READ_FAILED;
		}
		if (n == 0) { break; }
		out.append(buf.data(), static_cast<std::size_t>(n));
		if (out.size() > cap) {			/* 单文件上限先判（与旧语义一致） */
			::close(fd);
			return FdReadStatus::TOO_LARGE;
		}
		if (totalBytes) {
			*totalBytes += static_cast<std::size_t>(n);
			if (totalCap > 0 && *totalBytes > totalCap) {
				::close(fd);
				return FdReadStatus::TOTAL_TOO_LARGE;
			}
		}
	}
	::close(fd);
	return FdReadStatus::OK;
}

/* ---- EINTR 重试单点（2026-09-20 重构阶段 4.2）----
 * main.cpp 安装 SIGINT/SIGTERM 处理器时**明确不用 SA_RESTART**
 *（为了让 accept 等阻塞点被中断以便检查停止标志），因此 EINTR 在本项目里是
 * 常态而非异常：可中断系统调用返回 -1/EINTR 的语义是「再试一次」，
 * 既不是「出错」也不是「EOF」。
 * 此前这条语义散落在 3 处，其中 2 处误判为终态：run_command 排空把 EINTR 当
 * EOF（截断子进程输出，并因提前关闭读端给仍在跑的子进程送 SIGPIPE）；
 * waitpid 的 EINTR 被当「已无子进程」（留下僵尸）。收敛到这里，
 * 调用点只表达「我要调什么」。
 * 形状约束：被包装的调用以返回 -1 表示失败、并以 errno 报因。 */
template <typename Fn>
auto retryEintr(Fn&& fn) -> decltype(fn()) {
	for (;;) {
		auto r = fn();
		if (r == -1 && errno == EINTR) { continue; }
		return r;
	}
}

/* ---- 信任前提体检（BQ-2，2026-09-29 审计 P2-2 收口）----
 * Lua 沙箱因 ffi 保留而不是安全边界（luasandbox.cpp 的自陈）：驱动 chunk 经
 * ffi.C 拥有全进程能力，「驱动文件属操作者可信域」是唯一前提。权限位是这个
 * 前提最便宜的可观测代理——组/其他可写的驱动文件意味着任何本机用户都能改写
 * 「等效于宿主进程本身」的代码。按 socket 父目录 0700 体检的先例
 * （mcpbackend prepareListenSocket），响亮告警不阻断：umask 022 下自写的文件
 * 正常是 0644 不触发；共享组开发的 002 umask 属操作者自担，但必须看见。
 * stat 失败/非普通文件不告警（加载方自会以「文件不存在」响亮报错，这里
 * 不抢报错权）；跨线程去重（守护 chunk 的加载发生在守护线程），每路径一次。 */
inline void auditTrustedFilePath(const std::string& path, const char* what) {
	struct stat st{};
	if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) { return; }
	if ((st.st_mode & 0022) == 0) { return; }
	static std::mutex warnMu;
	static std::set<std::string> warned;
	std::lock_guard<std::mutex> lock(warnMu);
	if (!warned.insert(path).second) { return; }
	std::fprintf(stderr,
		"警告: %s '%s' 组或其他人可写（%04o）——驱动经 ffi 拥有全进程能力，"
		"此权限削弱了沙箱的信任前提；建议 chmod g-w,o-w\n",
		what, path.c_str(), static_cast<unsigned>(st.st_mode & 0777));
}

} // namespace bot
