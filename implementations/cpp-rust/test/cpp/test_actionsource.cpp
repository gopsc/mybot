/* test_actionsource.cpp —— 动作输入源的信任边界（审计 #2）
 *
 * --tcp / --input / stdin 三条通道共用同一个字节上限包装器。这里钉住：
 *   LimitedReader  第 cap+1 个字节即抛，EOF 不计入配额，未超限时字节原样透传
 *   异常类型       ScriptTooLarge 属 MatrixParseExcept 家族，
 *                  调用方按「脚本解析期错误」统一处理即可拿到原文报错；
 *                  kind 标签区分「动作脚本 / 结构脚本」两类输入（F-02）
 *   配置校验       端口 / 监听地址 / 空闲超时非法时一律返回 nullptr（不占端口、不裸崩）
 */

#include <cstddef>
#include <chrono>
#include <dirent.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
/* timeval 依赖本头直取：glibc 经 <sys/socket.h> 间接可见，musl（alpine）不然 */
#include <sys/time.h>
#include <unistd.h>

#include "actionsource.hpp"
#include "harness.hpp"
#include "matrix.hpp"
#include "util_except.hpp"
#include "util_str.hpp"

TH_TEST(limited_reader_passes_bytes_under_the_cap) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abc"));
	bot::LimitedReader lim(std::move(inner), 3);
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK(lim.read() == 'c');
	/* 恰好等于上限：读完最后一个字节仍不抛 */
	TH_CHECK(lim.read() == -1);
	TH_CHECK(lim.read() == -1);
}

TH_TEST(limited_reader_throws_one_byte_past_the_cap) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abcde"));
	bot::LimitedReader lim(std::move(inner), 3);
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK(lim.read() == 'c');
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge, "exceeds the byte limit of 3", lim.read());
	/* 越限后不会「吞掉异常继续放行」：后续每个字节都继续被拒 */
	TH_CHECK_THROWS(bot::ScriptTooLarge, lim.read());
}

TH_TEST(limited_reader_kind_label_distinguishes_script_kinds) {
	/* F-02：同一上限包装器服务 .mt 与 .sql 两类输入，报错首词须能区分类别 */
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abcd"));
	bot::LimitedReader lim(std::move(inner), 2, "structure script");
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge,
		"structure script exceeds the byte limit of 2", lim.read());
}

TH_TEST(limited_reader_eof_does_not_consume_quota) {
	/* EOF 反复返回 -1 不得累加计数（TCP 空闲超时后正是这种形态） */
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader(""));
	bot::LimitedReader lim(std::move(inner), 1);
	for (int k = 0; k < 100; ++k) { TH_CHECK(lim.read() == -1); }
}

TH_TEST(action_script_too_large_is_a_domain_error) {
	/* 2.5：单一根异常——ScriptTooLarge 直接继承 bot::IllegalArgumentException，
	 * I/O 层（actionsource）不再倒挂依赖解析层（matrix.hpp） */
	bot::ScriptTooLarge e(8);
	const bot::IllegalArgumentException& base = e;
	TH_CHECK(std::string(base.what()).find("exceeds the byte limit of 8") != std::string::npos);
	const std::exception& std_e = base;
	TH_CHECK(std::string(std_e.what()) == std::string(e.what()));
}

TH_TEST(too_large_survives_matrix_parser_without_downgrade) {
	/* 端到端一点：把超限流喂给 MatrixParser，报错文本必须仍是原始那句，
	 * 不能被 parse() 的兜底分支折成 "Parse failed at line N"。 */
	const std::string script = "@Action\nrelay0.deg;\n  200;\n  200;\n  200;\n@\n";
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader(script));
	bot::LimitedReader lim(std::move(inner), 20);
	mt::MatrixParser parser(lim);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeds the byte limit of 20", parser.parse());
}


/* ---- TcpStreamReader 分支单测（阶段 4：三份报告点名的盲区）----
 * 用 AF_UNIX socketpair 充当链路：数据/EOF/空闲超时/总预算四分支。 */
TH_TEST(tcp_stream_reader_streams_data_then_eof) {
	int fds[2];
	TH_CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
	{
		bot::TcpStreamReader r(fds[0], 5, deadline);
		TH_CHECK(::write(fds[1], "abc", 3) == 3);
		TH_CHECK(r.read() == 'a');	/* 一次 recv 填满缓冲，随后逐字节出队 */
		TH_CHECK(::write(fds[1], "de", 2) == 2);
		TH_CHECK(r.read() == 'b');
		TH_CHECK(r.read() == 'c');
		TH_CHECK(r.read() == 'd');	/* 缓冲耗尽触发下一次 recv */
		TH_CHECK(r.read() == 'e');
		::close(fds[1]);		/* 对端关写端 */
		TH_CHECK(r.read() == -1);	/* n==0 → EOF */
		TH_CHECK(r.read() == -1);	/* EOF 后保持 EOF */
	}
}

TH_TEST(tcp_stream_reader_idle_timeout_yields_eof) {
	int fds[2];
	TH_CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
	/* 对端连上但不发数据：recv 受 SO_RCVTIMEO 约束（生产路径由
	 * acceptAuthenticatedClient 设置，测试自设短超时），EAGAIN → 超时分支 */
	timeval tv{};
	tv.tv_sec = 0;
	tv.tv_usec = 50 * 1000;
	TH_CHECK(::setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
	{
		bot::TcpStreamReader r(fds[0], 1, deadline);
		TH_CHECK(r.read() == -1);	/* 空闲超时按输入结束处理 */
		TH_CHECK(r.read() == -1);	/* 超时消息只打一次，此后保持 EOF */
	}
	::close(fds[1]);
}

TH_TEST(tcp_stream_reader_over_total_budget_yields_eof_without_recv) {
	int fds[2];
	TH_CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
	/* C-M2：预算在建立时已过——即便对端发来数据也不得再 recv（慢滴对端
	 * 每次 recv 都在 idle 窗口内到达，wall-clock 预算是唯一硬防线） */
	const auto deadline = std::chrono::steady_clock::now() - std::chrono::seconds(1);
	{
		bot::TcpStreamReader r(fds[0], 60, deadline);
		TH_CHECK(::write(fds[1], "xx", 2) == 2);
		TH_CHECK(r.read() == -1);	/* 预算分支优先于 recv */
	}
	::close(fds[1]);
}

TH_TEST(open_action_source_rejects_missing_input_file) {
	bot::CliOptions opts;
	opts.input = "./definitely-not-here-9f3a1c.mt";
	TH_CHECK(bot::openActionSource(opts) == nullptr);
}

TH_TEST(open_action_source_rejects_bad_tcp_port) {
	bot::CliOptions opts;
	for (const char* bad : {"0", "-1", "65536", "abc", ""}) {
		opts = bot::CliOptions{};
		opts.tcp.enabled = true;
		opts.tcp.tcpPort = bad;
		TH_CHECK(bot::openActionSource(opts) == nullptr);
	}
}

TH_TEST(open_action_source_rejects_bad_tcp_host) {
	bot::CliOptions opts;
	opts.tcp.enabled = true;
	opts.tcp.tcpPort = "19999";
	for (const char* bad : {"not-an-ip", "localhost", "999.1.1.1", "127.0.0.1:80"}) {
		opts.tcp.tcpHost = bad;
		TH_CHECK(bot::openActionSource(opts) == nullptr);
	}
}

TH_TEST(open_action_source_rejects_bad_tcp_idle) {
	/* 空闲超时非法即拒绝：缺省 30s 的兜底不能被 "0" 变成「永不超时」 */
	bot::CliOptions opts;
	opts.tcp.enabled = true;
	opts.tcp.tcpPort = "19999";
	opts.tcp.tcpHost = "127.0.0.1";
	for (const char* bad : {"0", "-5", "86401", "soon"}) {
		opts.tcp.tcpIdle = bad;
		TH_CHECK(bot::openActionSource(opts) == nullptr);
	}
}

/* ---- F-1/F-3（2026-09-22，原 TD-2 剩余部分）：区间校验 ---- */

TH_TEST(open_action_source_rejects_bad_tcp_max_auth_attempts) {
	/* 下限 1、上限 1000（util::tcp_limits）：0/负/越界/非数字均拒绝，
	 * 与既有 tcpIdle/tcpPort 校验同一 nullptr 契约。 */
	bot::CliOptions opts;
	opts.tcp.enabled = true;
	opts.tcp.tcpPort = "19999";
	opts.tcp.tcpHost = "127.0.0.1";
	for (const char* bad : {"0", "-1", "1001", "five"}) {
		opts.tcp.tcpMaxAuthAttempts = bad;
		TH_CHECK(bot::openActionSource(opts) == nullptr);
	}
}

TH_TEST(open_action_source_rejects_bad_tcp_total_timeout) {
	/* 下限 1、上限 86400（util::tcp_limits），与 --tcp-idle 上限同数量级 */
	bot::CliOptions opts;
	opts.tcp.enabled = true;
	opts.tcp.tcpPort = "19999";
	opts.tcp.tcpHost = "127.0.0.1";
	for (const char* bad : {"0", "-1", "86401", "long"}) {
		opts.tcp.tcpTotalTimeout = bad;
		TH_CHECK(bot::openActionSource(opts) == nullptr);
	}
}

/* ---------------- fd 生命周期（0.5：FdGuard RAII） ---------------- */

namespace {

/* /proc/self/fd 条目数：本函数自身因 opendir 多占一个 fd，前后一致即可比对 */
std::size_t openFdCount() {
	DIR* d = ::opendir("/proc/self/fd");
	if (d == nullptr) { return 0; }
	std::size_t n = 0;
	while (::readdir(d) != nullptr) { ++n; }
	::closedir(d);
	return n;
}

/* 必然走到「bind 失败」抛异常的一组 TCP 选项 */
bot::CliOptions tcpBindFailOptions() {
	bot::CliOptions opts;
	opts.tcp.enabled = true;
	opts.tcp.tcpHost = "192.0.2.1";	/* TEST-NET-1：文档保留段，不会是本机地址 */
	opts.tcp.tcpPort = "9000";
	/* 显式非空 token：绕开「非回环必须设口令」的前置拒绝（H-2），
	 * 也不受 BOT4CJ_TCP_TOKEN 环境影响 */
	opts.tcp.tcpToken = "s3cret";
	return opts;
}

} // namespace

TH_TEST(tcp_listen_socket_is_released_when_bind_fails) {
	/* 0.5：openTcpActionSource 的 fd 出口全部 RAII 化（FdGuard），替换原先
	 * 近十条手工 ::close。192.0.2.1 非本机地址，bind 必以 EADDRNOTAVAIL 失败
	 * ——此时监听 fd 已创建，异常路径必须关闭它。预热一次后反复触发并比对
	 * /proc/self/fd 条目数：任一出口漏关都会累积泄漏。 */
	TH_CHECK_THROWS_MSG(std::runtime_error, "绑定失败",
		bot::openActionSource(tcpBindFailOptions()));	/* 预热：排除库级惰性 fd */

	const std::size_t before = openFdCount();
	for (int i = 0; i < 8; ++i) {
		TH_CHECK_THROWS_MSG(std::runtime_error, "绑定失败",
			bot::openActionSource(tcpBindFailOptions()));
	}
	TH_CHECK(openFdCount() == before);
}

/* ---------------- M1：恒时比较 safeEquals ---------------- */

TH_TEST(safe_equals_matches_identical_strings) {
	TH_CHECK(bot::safeEquals("", ""));
	TH_CHECK(bot::safeEquals("token", "token"));
	TH_CHECK(bot::safeEquals(std::string("a\0b", 3), std::string("a\0b", 3)));
}

TH_TEST(safe_equals_rejects_mismatched_content) {
	/* 首字节即错与末字节才错都拒绝（恒时语义对结果无差别） */
	TH_CHECK(!bot::safeEquals("token", "Xoken"));
	TH_CHECK(!bot::safeEquals("token", "tokeX"));
	TH_CHECK(!bot::safeEquals("token", "tokEn"));
}

TH_TEST(safe_equals_rejects_length_difference) {
	TH_CHECK(!bot::safeEquals("token", "tokenx"));
	TH_CHECK(!bot::safeEquals("token", "toke"));
	TH_CHECK(!bot::safeEquals("", "x"));
}

/* ==================== TCP 口令校验三态（2026-09-20 重构阶段 0/4.3）====================
 * 缺陷实证：`recv != 1` 把 SO_RCVTIMEO 到期（EAGAIN）与「凭据不匹配」混为一谈，
 * 调用方把两者都计入 authFails，连满 5 次即抛错退出进程。于是任意未认证对端
 * 只要连上 5 次、每次不发任何字节（每次挂满 --tcp-idle），就能终止进程，
 * 且诊断误报为「口令连续 5 次校验失败（可能为扫描/爆破）」。
 * 契约：NoCredential（空闲超时/EOF/中断）不得计为鉴权失败；Rejected 才计数。
 * 用 socketpair 充当链路，SO_RCVTIMEO 由用例自设（生产路径由 acceptAuthenticatedClient 设）。
 */
namespace {

/* 建立一条带短接收超时的 socketpair；fds[0] = 本端（被校验侧） */
bool makeAuthPair(int fds[2], long usec = 50 * 1000) {
	if (::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) { return false; }
	timeval tv{};
	tv.tv_sec = 0;
	tv.tv_usec = usec;
	return ::setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0;
}

} // namespace

TH_TEST(tcp_token_idle_timeout_is_not_an_auth_failure) {
	int fds[2];
	TH_CHECK(makeAuthPair(fds));
	/* 对端连上但一个字节都不发：必须归类为 NoCredential（不计数），
	 * 而不是「口令校验失败」 */
	TH_CHECK(bot::checkTcpToken(fds[0], "secret") == bot::TcpAuthStatus::NoCredential);
	::close(fds[0]);
	::close(fds[1]);
}

TH_TEST(tcp_token_peer_eof_is_not_an_auth_failure) {
	int fds[2];
	TH_CHECK(makeAuthPair(fds));
	::close(fds[1]);			/* 对端直接关闭：recv 返回 0 */
	TH_CHECK(bot::checkTcpToken(fds[0], "secret") == bot::TcpAuthStatus::NoCredential);
	::close(fds[0]);
}

TH_TEST(tcp_token_mismatch_is_rejected) {
	int fds[2];
	TH_CHECK(makeAuthPair(fds));
	TH_CHECK(::write(fds[1], "wrong\n", 6) == 6);
	TH_CHECK(bot::checkTcpToken(fds[0], "secret") == bot::TcpAuthStatus::Rejected);
	::close(fds[0]);
	::close(fds[1]);
}

TH_TEST(tcp_token_overlong_line_is_rejected) {
	int fds[2];
	TH_CHECK(makeAuthPair(fds));
	/* 凭据行超长：fail-closed 拒绝（且同样计入爆破计数） */
	TH_CHECK(::write(fds[1], "much-too-long-token\n", 20) == 20);
	TH_CHECK(bot::checkTcpToken(fds[0], "secret") == bot::TcpAuthStatus::Rejected);
	::close(fds[0]);
	::close(fds[1]);
}

TH_TEST(tcp_token_match_is_ok) {
	int fds[2];
	TH_CHECK(makeAuthPair(fds));
	TH_CHECK(::write(fds[1], "secret\n", 7) == 7);
	TH_CHECK(bot::checkTcpToken(fds[0], "secret") == bot::TcpAuthStatus::Ok);
	::close(fds[0]);
	::close(fds[1]);
}
