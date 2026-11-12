#pragma once
/* actionsource.hpp —— 动作输入源（移植 bot4cj/src/ActionSource.cj）
 * 通道优先级：--tcp > --input > 标准输入 stdin。
 */

#include <cstddef>
#include <cstdio>
#include <chrono>
#include <iostream>		/* FileReader::read 的 I/O 错误告警走 std::cerr（评估后维持：
			 * <ostream> 只给类型、不给 std::cerr 这个对象） */
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <unistd.h>		/* TcpStreamReader 析构里的 ::close */

#include "scriptlimit.hpp"	/* kMaxScriptBytes / ScriptTooLarge / readAllLimited /
				 * LimitedReader：限流原语已析出叶子头（离线工具与 agent
				 * 工具层只引那份，不必拉进本头的 CLI/动作源域） */
#include "util_except.hpp"	/* Reader 基类（FileReader/TcpStreamReader 直接继承） */

namespace bot {

/* 命令行选项的单一容器（旧扁平 CLI 形态，MCP/agent 已裁剪）。
 * tcpPort/tcpIdle 等数值项保留原始字符串：数值形态与范围校验在
 * openActionSource / validateOptions 内完成，本结构只消灭 stringly-typed 键。 */
struct CliOptions {
	std::optional<std::string> robot;
	bool help = false;
	std::string helpTopic;		/* --help <topic> 分段帮助 */
	std::optional<std::string> input;

	/* 物理设备/非回环网络/宿主 Shell 的显式开关。C++ HAL 在 Step 2 接入后
	 * 由 HALManager 强制执行；当前解析层先把它保存下来。 */
	bool allowHardware = false;

	/* 动作脚本的墙钟预算（秒，原始串；空 = 缺省 180）。超时通过
	 * LuaExecBudget 指令钩子中断解释器中的 Lua 代码；阻塞的 FFI 调用不可中断。 */
	std::string actionTimeoutSec;

	/* 会话别名注入（--var NAME=VALUE / --var-env NAME=ENVVAR），传给
	 * RobotStruct::run 的 injectVars，生命周期 = 本次 run()。 */
	std::vector<std::string> varSpecs;
	std::vector<std::string> varEnvSpecs;
	std::map<std::string, std::string> injectVars;

	/* --daemon-grace-ms：RobotStruct::deactivate 二段屏障的宽限上限。
	 * 空串 = 缺省 daemon_limits::kGraceMsDefault。 */
	std::string daemonGraceMs;

	/* ---- TCP 动作源（--tcp）---- */
	struct Tcp {
		bool enabled = false;
		std::string tcpPort;
		std::string tcpHost = "127.0.0.1";
		std::string tcpToken;
		std::string tcpIdle;
		std::string tcpMaxAuthAttempts;
		std::string tcpTotalTimeout;
	} tcp;
};

/* 脚本输入的字节上限四件套（kMaxScriptBytes / ScriptTooLarge / readAllLimited /
 * LimitedReader）已迁 scriptlimit.hpp，经上面的包含仍在 bot:: 下同名可见。 */

/* 以 EOF(-1) 表示输入结束的字符流 */
class FileReader : public Reader {
	std::FILE* file_;

public:
	explicit FileReader(const std::string& path) : file_(std::fopen(path.c_str(), "rb")) {}
	~FileReader() override { if (file_) { std::fclose(file_); } }

	/* 持 FILE* 句柄：拷贝会造成双重 fclose（F-25） */
	FileReader(const FileReader&) = delete;
	FileReader& operator=(const FileReader&) = delete;

	bool good() const { return file_ != nullptr; }

	int read() override {
		if (!file_) { return -1; }
		int c = std::fgetc(file_);
		/* R3：区分 EOF 与读错误——磁盘 I/O 错误静默当作脚本结束会截断动作 */
		if (c == EOF && std::ferror(file_)) {
			std::cerr << "警告：动作脚本读取发生 I/O 错误，按 EOF 处理（脚本可能被截断）" << std::endl;
		}
		return c;
	}
};

/* 已连接 TCP 客户端（内部 64KiB 缓冲，一次 recv 填满后逐字节出队，审计 M2；
 * EOF=0/错误=-1）
 * 空闲超时：对端连上后不再发字节时不能永久挂死进程（秒级由调用方给定）。
 * 总时长预算（C-M2）：空闲超时按「每字节」重置——慢滴对端每 <idle 秒发
 * 1 字节即可无限期挂住进程。从连接建立时刻起算 wall-clock 上限，超限按
 * 输入结束处理（脚本按截断语义走后续报错路径）。 */
class TcpStreamReader : public Reader {
	int fd_;
	int idleSec_;
	std::chrono::steady_clock::time_point deadline_;
	bool timedOut_ = false;
	bool overBudget_ = false;
	std::string buf_;
	std::size_t pos_ = 0;
	static constexpr std::size_t kBufCap = 64u << 10;

public:
	explicit TcpStreamReader(int fd, int idleSec,
			std::chrono::steady_clock::time_point deadline)
		: fd_(fd), idleSec_(idleSec), deadline_(deadline) {}
	~TcpStreamReader() override { if (fd_ >= 0) { ::close(fd_); } }

	/* 持 socket fd：拷贝会造成双重 close（F-25） */
	TcpStreamReader(const TcpStreamReader&) = delete;
	TcpStreamReader& operator=(const TcpStreamReader&) = delete;

	int read() override;
};

/* ---- TCP 口令校验三态（2026-09-20 重构阶段 4.3）----
 * 必须区分「对端给了凭据但不匹配」与「对端什么都没给」：
 *   Ok           口令正确
 *   Rejected     收到凭据行但内容不匹配 / 超长 —— 计入爆破计数
 *   NoCredential 未收到凭据行（空闲超时 EAGAIN、EOF、EINTR）—— **不得**计为鉴权失败，
 *                否则任意未认证对端连上不发字节、重复 5 次即可终止进程
 *                （旧实现把 EAGAIN 与不匹配混为一谈，且误报「连续 5 次校验失败」）。
 * 暴露为公开函数便于白盒单测（与 ActionRunner::resolveActionDevice 同惯例）。 */
enum class TcpAuthStatus { Ok, Rejected, NoCredential };

TcpAuthStatus checkTcpToken(int client, const std::string& token);

/* 打开动作输入源：tcp 优先 > 文件 > 标准输入（MemoryReader 整读）。
 * 返回的读取器一律带字节上限；TCP 通道另含绑定地址、空闲超时与可选口令。 */
std::unique_ptr<Reader> openActionSource(const CliOptions& options);

} // namespace bot
