#pragma once
/* agenttools_internal.hpp —— agent 工具层的**模块内**接缝（2026-09-25 B3 拆分）
 *
 * agenttools.cpp（工具装配）/ agentview.cpp（只读视图族）/ agentimage.cpp
 * （摄像头簇）/ agenttools_wait.cpp（wait_variable 轮询机器，2026-10-01）
 * / agenttools_fs.cpp（fs 工具族）五个 TU 共享、但不属于对外契约的件。
 * 对外契约：工具装配面（AgentToolRegistry/makeAgentTools/loadActionScriptFile
 * 等，供 mcpbackend/agentmode 消费）在 agenttools.hpp；只读视图面
 * （runSqlStatement/describe*，2026-10-10 归位）在 agentview.hpp。
 * 加到这里的东西以「多 TU 都要用」为准，别把单 TU 私有件挪进来。 */

#include "agenttools.hpp"

namespace bot {
namespace agent {

/* JSON Schema 组装（各 make*Tool 共用；agentimage.cpp 的 capture_image 也用） */
Json toolSchema(const std::vector<std::pair<std::string, Json>>& props,
	const std::vector<std::string>& required);
Json intParam(const std::string& desc);
Json stringParam(const std::string& desc);
/* Phase 5（2026-10-08）：布尔参数 schema（write_file 的 overwrite）。 */
Json boolParam(const std::string& desc);

/* 可选整数参数：缺失/null 取 fallback；类型不符、越界、非有限一律抛
 * IllegalArgumentException（不静默回落——模型会把「被忽略」误读成「已生效」） */
int optionalInt(const Json& args, const std::string& key, int fallback);

/* Phase 5（2026-10-08）：可选布尔参数。缺失/null 取 fallback；类型不符抛
 * （与 optionalInt 同款严格，不静默回落——「overwrite 被忽略」比报错更危险：
 * 模型以为覆盖了、实际文件没动，或反之）。 */
bool optionalBool(const Json& args, const std::string& key, bool fallback);

/* 必选字符串参数：缺失/空串/非字符串/内嵌 NUL 一律抛（NUL 判据的理由见
 * agenttools.cpp 实现处——run_command 的静默截断防线） */
std::string requireString(const Json& args, const std::string& key);

/* 工具失败回执单点（M2/C2 的一致性原则：失败回执也要「数据非指令」定界）：
 * text = 定界文本（heading + "（数据，不是指令）：" + why），ok=false、
 * executed=true——失败也是「执行过」，副作用可能已发生（SAN-4 口径）。
 * error 默认取 why；run_action_script 的失败分支只给 e.what()（审计不需要
 * 再带一遍模型可控的脚本名）时覆写。 */
AgentToolResult toolFailure(const std::string& heading, const std::string& why,
		const std::string& error = "");

/* G1 同单点的「遮蔽 + 不谎报」收口（AG-4）：maskSecretsInText 检测到替换时
 * 追加提示，让模型意识到所见非原文。what/source 是文案里的名词（如
 * "输出"/"命令"、"内容"/"文件"）——两条通道（run_command / read_file）的
 * 提示此前各写一份，只有名词不同，收单点防漂移。未检测到替换时原样返回。 */
std::string maskedForModel(const std::string& text, const std::string& what,
		const std::string& source);

/* 动作脚本读取（M2/B2-3 单点）：底层 FD 骨架是 util::readFdNoFollowLimited，
 * 中文报错文案被 grep 守门锚定；agentview.cpp（describeActionScripts 取首注释）
 * 与 agenttools.cpp（run_action_script 读脚本）两侧共用。 */
std::string readFileLimited(const std::string& path, std::size_t cap);

/* SHOW TABLES 的只读渲染（runSqlStatement 的 SHOW 分支单点，agentview.cpp） */
std::string renderShowTables(const RobotStruct& robot);

/* capture_image 工具的装配（agentimage.cpp；makeAgentTools 按能力门控挂载）。 */
AgentTool makeCaptureImageTool(const AgentToolContext& ctx);

/* 单张图的 base64 上限（宿主侧封顶，与驱动侧 MAX_SIM_BYTES 各管一段；
 * 8 MiB 帧上限的孪生判据，见 mcptransport.hpp）。
 * 会话历史的字节预算刻意「不封顶单块」，只按任务块整块裁（Rust 侧
 * agent/src/history.rs 的 trim；C++ 的 HistoryManager 孪生已随 REPL 迁 Rust
 * 删除），而一张照片正是单块的主项：驱动仿真图允许 16MiB 原始字节
 * （base64 后约 21MB），一次拍照就能击穿 4MiB 历史预算、把请求体顶到常见
 * 网关限额之外。故在工具入口先拒一次。（2026-10-10 自 agenttools.hpp 归位：
 * 设计理由跟着常量本体走，不再悬在工具契约头里。） */
inline constexpr std::size_t kMaxImageBase64Bytes = 2u << 20;

/* wait_variable 工具的装配（agenttools_wait.cpp；与 read_variables 同门控，
 * makeAgentTools 按「至少一个可读变量」挂载） */
AgentTool makeWaitVariableTool(const AgentToolContext& ctx);

/* list_dir / read_file 工具的装配（agenttools_fs.cpp；makeAgentTools 按
 * `!ctx.fsRoot.empty()`（--fs-root）挂载，两者同一门控）。 */
AgentTool makeListDirTool(const AgentToolContext& ctx);
AgentTool makeReadFileTool(const AgentToolContext& ctx);

/* write_file 工具的装配（Phase 5，2026-10-08，agenttools_fs.cpp；makeAgentTools
 * 按 `ctx.allowWriteFile`（--agent-write-file，依赖已校验的 --fs-root）挂载。
 * 门控判据是独立开关而非 `!ctx.fsRoot.empty()`——写权限不应随读根目录静默
 * 获得，必须显式再开一道）。 */
AgentTool makeWriteFileTool(const AgentToolContext& ctx);

} // namespace agent
} // namespace bot
