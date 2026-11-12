#pragma once
/* llmconfig.hpp —— LLM/agent 配置文件（JSON）读取
 *
 * 为什么用 JSON 而不是 Lua：配置文件是**数据**，不是代码。Lua 配置要由宿主内嵌
 * 一个状态机去执行，等于让一份常被复制/分发的文件获得任意代码执行能力；而仓库
 * 已经有严格 JSON 解析器（src/jsonparse.cpp），复用它零成本，还自带「拒绝尾随
 * 字符/坏转义」的严格性。
 *
 * 字段全部可选：缺省即交给下一层（命令行 > 环境变量 > 本文件 > 驱动内置缺省）。
 * 未知字段一律拒绝——与「未知 --key 退出 2」同一口径，防拼错后静默失效。
 *
 * 2026-10-01 批次 A（P1-5，agentmode.hpp「批次 2」自计划落地）：模型侧字段
 * （driver/var/endpoint/model/api_key/采样/预算/重试/提示词包/会话）的解析随
 * agent 循环迁 Rust 一并退役——本侧解析后无消费者，徒增「改了 C++ 忘了 Rust」
 * 的双端维护与漂移面。这些键**仍在白名单**（kKnown）：两端共用一份
 * mybot.llm.json，它们是 mybot-agent 的合法键，C++ 若当未知字段拒绝会让后端
 * 读不了同一份配置；其类型/区间校验由 Rust 侧 config.rs 独立负责。本结构只
 * 保留后端真实消费的面：能力门控、摄像头、审计/策略、scripts_dir 与工具层
 * 超时。 */

#include <optional>
#include <string>
#include <vector>

namespace bot {

/* ---- 工具层字段取值区间（B2-4 单点，2026-09-21）----
 * 模型侧区间（timeout/max_tokens/max_turns/字节预算/重试……）已随批次 2 退役：
 * 唯一事实源是 Rust 侧 config.rs 的 limits 模块（跨语言互钉测试
 * test_cross_lang_limits 与这些常量一并退役——C++ 侧不再镜像任何 Rust 常量）。
 * 这里只剩后端**真实消费**的工具层超时区间。 */
namespace llm_limits {
/* run_command 两个超时沿用「缺省 ≤ 上限」的既有形态：缺省上限 600（10 分钟），
 * 请求上限 3600（1 小时）已覆盖现场长任务，再长得先想想是不是该用
 * run_action_script（脚本执行有硬件侧语义，而不是宿主任意命令）。 */
inline constexpr int kRunCommandTimeoutMinSec = 1;
inline constexpr int kRunCommandTimeoutMaxSec = 600;
inline constexpr int kRunCommandMaxTimeoutMinSec = 1;
inline constexpr int kRunCommandMaxTimeoutMaxSec = 3600;
/* PL-2（2026-09-22）：动作脚本执行预算。0 = 显式关闭（退化为此前无预算行为）；
 * 上限 3600 与 run_command 的长任务量级对齐。 */
inline constexpr int kActionScriptTimeoutMinSec = 0;
inline constexpr int kActionScriptTimeoutMaxSec = 3600;
} // namespace llm_limits
struct LlmFileConfig {
	std::optional<std::string> scriptsDir;
	std::optional<bool> allowShell;
	/* 热插表（2026-09-23）：apply_sql 会立刻给新硬件上电，与 allow_shell 同判据
	 * ——解析出来**只为了拒绝它**（只能由命令行 --agent-hot-sql 开启）。之所以
	 * 仍列进已知字段，是为了给出指名道姓的原因，而不是让人以为是拼写错误
	 * （与下面的 camera_src_dir 同一处理）。 */
	std::optional<bool> allowHotSql;
	std::optional<std::string> cameraVar;
	std::optional<std::string> cameraDevice;
	std::optional<std::string> cameraSrc;
	/* H1：这个字段被解析出来**只为了拒绝它**——capture_image 的白名单根目录
	 * 只能由命令行 --camera-src-dir 提供（配置文件不能放宽读权限，与 allow_shell
	 * 同判据）。之所以仍列进已知字段而不是靠"未知字段"报错，是为了给出指名道姓的
	 * 原因，而不是让人以为是拼写错误。 */
	std::optional<std::string> cameraSrcDir;
	/* 回读（2026-09-23，发现 2 的 A 步）：这个字段被解析出来**只为了拒绝它**——
	 * `read_variables` 的可读清单只能由命令行 `--read-var` 提供（配置文件不能给
	 * 模型开放"主动读硬件"的能力，与 allow_shell / camera_src_dir 同判据）。
	 * 仍列进已知字段而不是靠"未知字段"报错，是为了给出指名道姓的原因。 */
	std::optional<std::vector<std::string>> readVars;
	std::optional<bool> allowCamera;
	/* Phase 4（2026-10-07）：list_dir / read_file 的只读根目录——解析出来**只为了
	 * 拒绝它**（同 cameraSrcDir/readVars 的判据）：只能命令行 --fs-root 提供，
	 * 配置文件不能给模型开放"读主机文件"的能力。 */
	std::optional<std::string> fsRoot;
	/* Phase 5（2026-10-08）：write_file 的独立开关——解析出来**只为了拒绝它**
	 * （同 allow_shell/allow_hot_sql/fsRoot 的判据）：只能命令行 --agent-write-file
	 * 提供，配置文件不能给模型开放"改写主机文件"的能力（写比读更危险）。 */
	std::optional<bool> allowWriteFile;
	/* 审计轨迹落点（JSON Lines；"-" = stderr）。空/未配置 = 不记录。
	 * 与 --audit-log 同义；命令行优先。 */
	std::optional<std::string> auditLog;
	/* 策略钩子文件（--agent-policy 同义；命令行优先）。空/未配置 = 不启用。 */
	std::optional<std::string> agentPolicy;
	/* 运行期数值（B4）：run_command 的缺省与最大超时、动作脚本执行预算。
	 * 未配置 = 用各结构体的编译期缺省；区间与决策理由见 llm_limits。
	 * 跨字段关系（上限 ≥ 缺省）在 agentmode 按**生效值**判定——只配一个
	 * 字段时也要挡住「上限低于缺省」。 */
	std::optional<int> runCommandTimeoutSec;
	std::optional<int> runCommandMaxTimeoutSec;
	/* PL-2：动作脚本执行预算（秒）。0 = 显式关闭预算。 */
	std::optional<int> actionScriptTimeoutSec;
};

/* 解析配置文件。失败返回 false 并把「带字段名的人话报错」写进 err：
 * 文件不可读、不是合法 JSON、**本侧消费字段的**类型/范围不符、未知字段全部
 * 拒绝（模型侧字段只经白名单，不校验——那是 mybot-agent 的职责）。 */
bool loadLlmConfigFile(const std::string& path, LlmFileConfig& out, std::string& err);

/* 缺省配置文件查找：./mybot.llm.json → ./mybot.llm.conf.json →
 * $HOME/.config/mybot/llm.json。都不存在返回空串（配置文件是可选的）。 */
std::string findDefaultLlmConfig();

} // namespace bot
