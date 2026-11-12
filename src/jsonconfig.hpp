#pragma once
/* jsonconfig.hpp —— 严格 JSON 配置文件的公共读取骨架（单一事实源）
 *
 * agentpolicy（--agent-policy 策略文件）与 llmconfig（mybot.llm.json）原先各持
 * 一份「受限读取 → 解析 → 顶层对象检查 → 未知字段拒绝」拷贝，报错文案同构、
 * 只差名词。两处判据（读取上限、顶层形态、白名单口径）若再漂移，一边收紧
 * 另一边没跟上就是静默的防线不一致——收敛到此单点，差异全部经 ConfigKind
 * 表达，行为逐字保持。
 *
 * 不属于共享层的：字段级的 want* 解析（类型/区间/空占位口径）两边语义刻意
 * 不同（如策略文件拒绝空数组元素、llm 配置静默丢弃占位），留在各调用方。 */

#include <cstddef>
#include <set>
#include <string>

#include "json.hpp"

namespace bot {
namespace jsonconfig {

/* 一类 JSON 配置文件的读取口径。成员就是两处旧拷贝的全部差异： */
struct ConfigKind {
	const char* label;		/* 报错名词：「配置文件」/「策略文件」 */
	const char* verb;		/* 字段类型报错动词：「需要」/「应为」 */
	bool rejectEmpty;		/* 空文件独立报错，还是落到 JSON 解析失败 */
	std::size_t maxBytes;	/* 读取上限（超限报「过大」而非静默截断） */
};

/* 读取 + 解析 + 顶层形态检查 + 未知字段拒绝。成功时 root 是通过全部检查的
 * 顶层对象；失败返回 false 并把带 path 的人话报错写进 err。
 * known：本类文件承认的字段白名单（各调用方自己的 schema 事实）。 */
bool loadRoot(const ConfigKind& kind, const std::string& path,
		const std::set<std::string>& known, Json& root, std::string& err);

/* 字段类型不符时的统一报错（带字段名与期望类型，排障时不用猜） */
std::string typeError(const ConfigKind& kind, const std::string& path,
		const std::string& key, const char* want);

} // namespace jsonconfig
} // namespace bot
