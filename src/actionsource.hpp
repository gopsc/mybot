#pragma once
/* actionsource.hpp —— 动作输入源（--input 文件 > 标准输入 stdin） */

#include <cstddef>
#include <cstdio>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "scriptlimit.hpp"
#include "util_except.hpp"

namespace bot {

/* 命令行选项的单一容器（旧扁平 CLI 形态；TCP 动作源与 --allow-hardware
 * 已移除，硬件访问默认允许）。 */
struct CliOptions {
	std::optional<std::string> robot;
	bool help = false;
	std::string helpTopic;		/* --help <topic> 分段帮助 */
	std::optional<std::string> input;

	/* 动作脚本的墙钟预算（秒，原始串；空 = 缺省 180）。 */
	std::string actionTimeoutSec;

	/* 会话别名注入（--var NAME=VALUE / --var-env NAME=ENVVAR）。 */
	std::vector<std::string> varSpecs;
	std::vector<std::string> varEnvSpecs;
	std::map<std::string, std::string> injectVars;

	/* --daemon-grace-ms：RobotStruct::deactivate 二段屏障的宽限上限。 */
	std::string daemonGraceMs;
};

/* 以 EOF(-1) 表示输入结束的字符流 */
class FileReader : public Reader {
	std::FILE* file_;

public:
	explicit FileReader(const std::string& path) : file_(std::fopen(path.c_str(), "rb")) {}
	~FileReader() override { if (file_) { std::fclose(file_); } }

	FileReader(const FileReader&) = delete;
	FileReader& operator=(const FileReader&) = delete;

	bool good() const { return file_ != nullptr; }

	int read() override {
		if (!file_) { return -1; }
		int c = std::fgetc(file_);
		if (c == EOF && std::ferror(file_)) {
			std::cerr << "警告：动作脚本读取发生 I/O 错误，按 EOF 处理（脚本可能被截断）" << std::endl;
		}
		return c;
	}
};

/* 打开动作输入源：--input 文件优先，否则读标准输入（MemoryReader 整读）。
 * 返回的读取器一律带字节上限。 */
std::unique_ptr<Reader> openActionSource(const CliOptions& options);

} // namespace bot
