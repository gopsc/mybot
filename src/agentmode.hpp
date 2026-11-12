#pragma once
/* agentmode.hpp —— agent 工具后端的配置组装（--mcp-backend）
 *
 * C++ 侧在 agent 体系里的职责是「工具后端」：main 在 --mcp-backend 下先
 * active() 机器人，再由 mcpbackend 在 AF_UNIX socket 上同步服务工具调用，
 * 全程硬件常驻；会话结束才 deactivate。agent 循环本体（REPL/模型调用/预算/
 * 历史裁剪）在 Rust 侧 agent/src（mybot-agent），经帧协议调用这里的工具层。
 *
 * 本模块只做配置组装与工具上下文：buildAgentConfig（命令行/环境/配置文件/
 * 内置缺省四层合并 + 能力门控 + 审计/策略装载）与 makeToolContext（工具表
 * 的单一落点）。模型调用不在这里——LLM 请求由 Rust agent 直连 provider。
 */

#include <iosfwd>
#include <memory>
#include <string>
#include <vector>

#include "actionsource.hpp"
#include "agentaudit.hpp"
#include "agentpolicy.hpp"
#include "agentproto.hpp"
#include "agenttools.hpp"	/* AgentToolContext（makeToolContext 的返回类型） */

namespace bot {

class RobotStruct;

namespace agent {

/* 工具后端（--mcp-backend）真实消费的配置面。
 *
 * 2026-09-26 收缩：agent 循环迁 Rust（c1e25f15）后，凡只服务于「C++ 侧自己
 * 跑模型循环」的字段一律删除——它们在 --mcp-backend 下永不生效（buildAgentConfig
 * 是后端唯一调用点；曾经的 LLM 层与提示词体积预检对 mcpBackend 直接 return，
 * 即后端从不执行，故连同这些字段一并删除；且 --task/--resume/--session-file/
 * --prompt-file/--llm-* 在 cliargs::validateOptions 阶段就被拒绝，根本到不了这里）。
 * 模型侧配置（endpoint/model/api_key/采样/预算/提示词包/会话）由 Rust agent 的
 * config.rs 独立解析，宿主不再镜像。
 * 保留下来的都是后端装配工具上下文（makeToolContext）、能力门控、审计/策略与
 * context.get 素材真实读取的字段。 */
struct AgentModeConfig {
	/* 摄像头（capture_image 工具）。allowCamera=false 时不提供该工具；
	 * 驱动变量解析不到时也只是不提供（摄像头对机器人是可选外设）。 */
	std::string cameraVar = "cam0";
	std::string cameraDevice;	/* 空 = 驱动缺省 /dev/video0 */
	std::string cameraSrc;		/* 非空 = 模拟图片来源文件（无摄像头也能跑通全链路） */
	/* H1：cameraSrc 是否来自命令行（--camera-src）。只有命令行来源才允许用
	 * "src 的所在目录"当白名单根；配置文件来源一律不推导（详见 agenttools.hpp
	 * 的 AgentToolContext 注释——旧实现无条件推导，判据恒真，等于没有白名单）。 */
	bool cameraSrcFromCli = false;
	/* H1：capture_image 模拟图片的白名单根目录（--camera-src-dir）。
	 * **只能命令行给**：它决定"能读哪个目录"，等价于放宽读权限，故与 allow_shell
	 * 同判据——配置文件里写 camera_src_dir 一律拒绝加载并指名原因
	 * （缺省查找会读 CWD 的 ./mybot.llm.json，「这个文件存在」不构成授权）。 */
	std::string cameraSrcDir;
	bool allowCamera = true;
	std::string scriptsDir = "scripts";
	std::string structurePath;
	bool allowShell = false;	/* true = 注册 run_command（缺省关，见 actionsource.hpp 注） */
	/* 热插表（2026-09-23）：true = 注册 apply_sql（结构 SQL 带电生效）。
	 * 与 allowShell 同一条门控链：只能命令行 --agent-hot-sql 开启，配置文件
	 * 的 allow_hot_sql 只能关不能开（见 actionsource.hpp 注）。 */
	bool allowHotSql = false;
	/* 回读（2026-09-23，发现 2 的 A 步）：允许模型**主动读**的硬件变量名清单
	 * （--read-var，可重复）。**命令行独占**：配置文件写 read_vars 会被拒绝加载
	 * （与 allow_shell / camera_src_dir 同判据）。空 = 不注册 read_variables。 */
	std::vector<std::string> readVars;
	/* list_dir / read_file 的只读根目录（Phase 4，2026-10-07，--fs-root）。
	 * **命令行独占**（配置文件写 fs_root 会被拒绝加载，与 readVars 同判据）。
	 * 空 = 不注册这两个工具。buildAgentConfig 在上电前校验其 canonical 存在
	 * 且是目录（配置错误不碰真机）——走到 makeToolContext 时要么是空串，
	 * 要么已经是校验通过的路径。 */
	std::string fsRoot;
	/* write_file 的独立开关（Phase 5，2026-10-08，--agent-write-file）。
	 * **独立于 fsRoot**：开了只读根不等于给了写权，必须再显式开一道
	 * （写能覆盖/改写，危险性与 allowShell/allowHotSql 同级）。buildAgentConfig
	 * 校验它依赖 fsRoot 非空（给了这个开关却没给 --fs-root 是配置错误）；
	 * --mcp-backend 下还强制要求策略确认（见 enforceBackendConfirmPolicy）。 */
	bool allowWriteFile = false;
	/* 断连安全动作（2026-09-25，--on-disconnect）：连接结束后由后端自行执行的
	 * 动作脚本（scriptsDir 之下的相对路径）。命令行独占（配置文件不能给）；
	 * buildAgentConfig 在上电前经 loadActionScriptFile 预检（越界/不存在/为空
	 * 即配置错误）。空 = 不执行。执行判据与 run_action_script 同源
	 * （runActionScriptFile），但**不经 DispatchGate/策略确认**：这是操作者
	 * 预先配置的安全动作，不是模型的请求，等外部闸门反而违背它的目的。 */
	std::string onDisconnectScript;
	/* MCP 首帧共享密钥（2026-09-29，审计 P2-1 落地；mcpbackend.hpp 残留风险
	 * 清单里自陈的设计）。**只从环境变量 BOT4CJ_MCP_TOKEN 读**（命令行传密钥
	 * 会进 /proc/<pid>/cmdline 全局可读；配置文件是模型路径的低信任层）。
	 * 空串 = 不启用（现状语义）；设置但为空 / 超长 = 配置错误，上电前失败。
	 * 时序要点：必须在 prepareAgentConfig 的 scrubEnvSecrets **之前**捕获成
	 * std::string——该名字含 "token"，会被 isSensitiveEnvName 从宿主环境抹零
	 * （这正是设计的一环：模型驱动的 run_command 子进程拿不到它，
	 * /proc/<宿主>/environ 也读不到）。 */
	std::string mcpAuthToken;
	bool verbose = true;

	/* ---- 工具层超时（后端真实消费：makeToolContext → AgentToolContext）----
	 * 配置文件同名字段（run_command_timeout_sec 等）的落点；区间单点见 llm_limits。
	 * 与已迁 Rust 的模型循环预算（max_calls_per_round / 重试次数 / 退避时长）不同：
	 * 那三类是 agent 侧的事，后端不再镜像，已于 2026-09-26 删除。上下文字节预算
	 * 三字段随 2026-10-01 批次 A（P1-5）一并退役（见 llmconfig.hpp 头注）。 */
	int commandTimeoutSec = 10;	/* run_command 缺省超时 → AgentToolContext */
	int maxCommandTimeoutSec = 60;	/* run_command 超时上限 → AgentToolContext */
	/* PL-2：动作脚本执行预算（秒）→ AgentToolContext。0 = 显式关闭预算。 */
	int scriptTimeoutSec = 180;

	/* ---- 由 buildAgentConfig 填出的旁路信息 ---- */
	/* 实际使用的配置文件路径（空 = 没用配置文件），用于在会话开始时如实告知 */
	std::string configPath;

	/* ---- 审计轨迹（--audit-log / 配置文件 audit_log；空 = 关闭）----
	 * shared_ptr：buildAgentConfig 在这里打开（打不开即配置错误，上电前失败），
	 * MCP 后端与本配置共享同一实例。auditLogPath 只用于会话开始的如实告知。 */
	std::shared_ptr<AuditLog> audit;
	std::string auditLogPath;

	/* ---- 策略钩子（--agent-policy / 配置文件 agent_policy；空 = 不启用）----
	 * 在 buildAgentConfig 里加载成成品（策略文件写错属配置错误，上电前失败）；
	 * policyPath 只用于会话开始的如实告知。与 run_command 的开关互补：
	 * --agent-shell 管「工具给不给」，策略管「给了之后每次调用要不要过外部闸门」。 */
	std::shared_ptr<const AgentPolicy> policy;
	std::string policyPath;
};

/* 结构脚本展示名（去目录、去 .sql 后缀）：REPL 提示符、会话文件的 robot 指纹
 * 字段与 MCP 后端 context.get 的 robotName 共用——各写一遍迟早分叉。 */
std::string structureDisplayName(const std::string& path);

/* 由 CLI 选项组装配置。失败返回 false 并把「人话报错」写进 err。 */
bool buildAgentConfig(const CliOptions& opts, AgentModeConfig& out, std::string& err);

/* PL-1（2026-09-22，--check-config）：把**已经校验通过的**后端配置渲染成人类可读
 * 摘要。纯函数、无副作用，供 main 在校验模式下打印后退出 0。只报 --mcp-backend
 * 工具面真实生效的项（结构/脚本目录/工具超时/摄像头/能力门控/审计/策略）；模型侧
 * 配置由 mybot-agent --check-config 自行校验。注意它**不做校验**——判据单点在
 * buildAgentConfig（失败时调用方已 return 2），这里再校验一遍只会制造两处漂移。 */
std::string summarizeAgentConfig(const AgentModeConfig& cfg);

/* 组装工具上下文（AgentToolContext）的**单一落点**：MCP 后端（--mcp-backend）经此
 * 得到工具表，于是「对外提供哪些工具、能读哪些变量、摄像头怎么解析」的判据只此一处。
 * 只读 cfg + robot（调用方须先 active()）；不上电、不发起模型调用。
 * 跳过项（--read-var 名字打错等）如实写进 log，不静默降级。 */
AgentToolContext makeToolContext(const AgentModeConfig& cfg, RobotStruct& robot,
		std::ostream& log);

} // namespace agent
} // namespace bot
