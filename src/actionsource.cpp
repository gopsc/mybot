#include "actionsource.hpp"

#include <iostream>
#include <memory>

namespace bot {

/* 文件通道：--input 指定的 .mt 文件，打不开打印并返回 nullptr。 */
static std::unique_ptr<Reader> openFileSource(const CliOptions& options) {
	const std::string& path = *options.input;
	auto f = std::make_unique<FileReader>(path);
	if (!f->good()) {
		std::cerr << "无法打开动作脚本文件 '" << path << "'" << std::endl;
		return nullptr;
	}
	std::cerr << "从文件读取动作脚本：" << path << std::endl;
	return f;
}

/* 打开动作输入源：文件优先；否则从 stdin 整读（分块 + 超限即抛）。 */
std::unique_ptr<Reader> openActionSource(const CliOptions& options) {
	std::unique_ptr<Reader> raw;
	if (options.input) {
		raw = openFileSource(options);
	} else {
		raw = std::make_unique<MemoryReader>(readAllLimited(std::cin, kMaxScriptBytes));
	}
	if (!raw) { return nullptr; }
	return std::make_unique<LimitedReader>(std::move(raw), kMaxScriptBytes);
}

} // namespace bot
