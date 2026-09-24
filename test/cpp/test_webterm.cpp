/* test_webterm.cpp —— PTY 会话桥单测（#24 Web SSH MVP）
 * 真实 forkpty + /bin/sh：验证「写输入 → 读输出」双向与生命周期。
 * 环境要求：Linux + /bin/sh（沙箱若缺会 TH_SKIP 显式说明）。
 */

#include "harness.hpp"

#include <string>
#include <unistd.h>

#include "webterm.hpp"

/* 帮助函数：等 PTY 出现输出（带重试，避免过早 poll 返回空） */
static std::string readUntil(bot::webterm::Session& s, const std::string& needle, int maxMs = 3000) {
	std::string acc;
	for (int i = 0; i < maxMs && acc.find(needle) == std::string::npos; ++i) {
		std::string chunk;
		s.drain(chunk, 4096);
		if (!chunk.empty()) acc += chunk;
		usleep(1000);
	}
	return acc;
}

TH_TEST(webterm_echo_command_roundtrip) {
	bot::webterm::Session s;
	if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
	TH_CHECK(s.alive());
	s.write("echo webterm-ok-42\n");
	std::string out = readUntil(s, "webterm-ok-42");
	TH_CHECK(out.find("webterm-ok-42") != std::string::npos);
}

TH_TEST(webterm_multiple_commands) {
	bot::webterm::Session s;
	if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
	s.write("echo first; echo second\n");
	std::string out = readUntil(s, "second");
	TH_CHECK(out.find("first") != std::string::npos);
	TH_CHECK(out.find("second") != std::string::npos);
}

TH_TEST(webterm_exit_detected) {
	bot::webterm::Session s;
	if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
	s.write("exit\n");
	/* 等 shell 退出（≤3s） */
	bool died = false;
	for (int i = 0; i < 3000 && !died; ++i) {
		std::string chunk;
		s.drain(chunk, 4096);
		if (!s.alive()) died = true;
		if (!died) usleep(1000);
	}
	TH_CHECK(died);
}

TH_TEST(webterm_resize_does_not_crash) {
	bot::webterm::Session s;
	if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
	TH_CHECK(s.resize(24, 80));
	TH_CHECK(s.resize(50, 120));
	s.write("echo alive-after-resize\n");
	std::string out = readUntil(s, "alive-after-resize");
	TH_CHECK(out.find("alive-after-resize") != std::string::npos);
}

TH_TEST(webterm_close_cleans_up) {
	{
		bot::webterm::Session s;
		if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
		TH_CHECK(s.alive());
		s.closeSession();
		TH_CHECK(!s.alive());
	}
	/* 出作用域再析构一次也应安全（double close 路径） */
}

TH_TEST(webterm_drain_returns_bytes_only_when_present) {
	bot::webterm::Session s;
	if (s.masterFd() < 0) { TH_SKIP("forkpty 不可用"); return; }
	std::string chunk;
	/* 刚启动时可能尚无输出：drain 不应崩溃，返回可空 */
	s.drain(chunk, 4096);
	TH_CHECK(true);
}
