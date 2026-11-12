#pragma once
/* cliargs.hpp —— 命令行解析 / 校验 / 帮助文本（CLI11 扁平 CLI）
 *
 * 旧实现是手写 `--key=value` / `--key value` 解析器；本次改为 CLI11 2.x。
 * 行为契约保持：未知参数/缺值退出码 2，`--help` 优先于校验。
 */

#include <string>

#include "actionsource.hpp"

namespace bot {

/* 解析结果：opts 是类型化选项；errorCode 非 0 时调用方按该码退出，
 * error 已写好给 stderr 的人话文案（CLI11 的异常不穿透到 main）。 */
struct ParsedArgs {
	CliOptions opts;
	bool help = false;
	int errorCode = 0;
	std::string error;
};

/* 解析 argv；CLI11 的 ParseError 在此折成 errorCode（2）、help 折成 help=true。 */
ParsedArgs parseArgs(int argc, char** argv);

/* 组合校验/取值归一：--var/--var-env、--timeout、--daemon-grace-ms。
 * 违规时向 stderr 打印并返回 2；通过返回 0。--robot 的必选性由 CLI11
 * required() 在解析期强制（无参数调用除外，按帮助处理）。 */
int validateOptions(CliOptions& opts);

/* 帮助全文（单一字符串来源，便于单测锚定）。 */
std::string helpText();

} // namespace bot
