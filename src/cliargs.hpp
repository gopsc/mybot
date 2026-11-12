#pragma once
/* cliargs.hpp —— 命令行解析 / 校验 / 帮助文本（自 main.cpp 纯搬移）
 *
 * 搬出动机：CLI 面此前**不可测**——parseArgs / validateOptions / print_help 都定义在
 * main.cpp 里，而 main.cpp 不在 MYBOT_CORE_SOURCES 中，mybot_tests 链接不到，
 * test/ 对这三个名字的引用为 0；~6 个校验分支只有 2 个被黑盒覆盖。
 * 搬出后 mybot 与 mybot_tests 共用同一份实现（与其余 TU 同口径）。
 *
 * 行为契约（逐字保持）：报错文案、打印目标（std::cerr/std::cout）、退出码（0/2）。
 * 唯一形态变化：print_help 的 std::cout 序列改为先合成字符串再一次性输出，
 * 输出字节完全相同（每行仅换行，不依赖 flush 时机），换来可单测的锚点。
 *
 * 【为何不直接用 POSIX getopt_long（决策记录，#31）】
 * getopt_long 是标准方案，但与本 CLI 面存在以下**不可兼容的行为差异**，
 * 强行替换会破坏既有行为契约（报错文案/退出码/分段帮助均为对外契约）：
 *   1) **可选值的分离形式**：--tcp <port> 裸写合法（flag）、后跟数字才消费
 *     （可选值）。GNU getopt 的 optional_argument **只对 `--opt=value` 形式
 *     生效**，`--tcp 8080` 这类分离形式不会被消费（8080 会落为位置参数）。
 *     本项目还要求「下一参数以 -- 开头或不存在 = 无值」，getopt 无此判据；
 *   2) **严格报错契约**：未知键/缺值/组合校验必须逐字输出既定中文文案并
 *     exit 2；getopt 自带的错误输出（opterr）是英文且格式固定，无法逐字对齐；
 *   3) **分段帮助**：--help tcp/agent/llm/camera/mcp 的按主题帮助与帮助文本
 *     的**字节级单测锚点**（helpText 可测），getopt/argp 的自动帮助不满足；
 *   4) **可重复选项**：--read-var / --prompt-file 可重复 push_back，getopt
 *     天然支持重复但不提供类型化累积，仍需外层再包一层。
 * 若未来换库，需先为上述四条差异补齐等价实现并全量回归单测（test_cliargs.cpp）。
 */

#include <string>
#include <vector>

#include "actionsource.hpp"

namespace bot {

/* 解析结果：类型化选项 + 两类需要统一拒绝的键（F-20 未知键 / N-4 带值键缺值） */
struct ParsedArgs {
	CliOptions opts;
	std::vector<std::string> unknown;
	std::vector<std::string> missingValue;
};

/* `--key=value` 与 `--key value` 双形态解析（忽略位置参数）。
 * 未知键收进 unknown、带值键裸写收进 missingValue，均由 validateOptions 统一拒绝。 */
ParsedArgs parseArgs(int argc, char** argv);

/* F-20/N-4/agent 选项组合校验：违规即打印并返回退出码 2，通过返回 0 */
int validateOptions(ParsedArgs& args);

/* PL-4（2026-09-22）：把「`--help` 优先于校验」这条**顺序**从 main 抽出来，变成
 * 可链接、可单测的判定。抽出的动机与 cliargs 整体搬出 main 同源：`main` 不在
 * MYBOT_CORE_SOURCES、链接不进 mybot_tests，于是这条顺序此前只有一条**名不副实**
 * 的用例守着——它只调 parseArgs，把 main 里的 help 检查挪到校验之后照样绿。
 * 判定与打印分离：帮助文本仍由调用方打印（避免单测里刷一屏），这里只回答走哪条路。 */
enum class Preflight {
	Proceed,		/* 继续流水线 */
	Help,			/* 调用方打印帮助并退出 0 */
	ConfigError,		/* 校验失败（错误已由 validateOptions 打印），退出 2 */
};
Preflight preflightCli(ParsedArgs& args);

/* 帮助全文（单一字符串来源，便于单测锚定；--help 与错误提示共用） */
std::string helpText();

/* 分段帮助文本（2026-09-22 可用性改进）：支持 --help <topic> 快速查看特定主题。
 * topic 为空或不识别时返回完整帮助；识别的主题返回该段落。 */
std::string helpText(const std::string& topic);

/* 输出帮助全文（stdout） */
void printHelp();

/* 输出分段帮助（stdout，2026-09-22） */
void printHelp(const std::string& topic);

} // namespace bot
