#include "agentmode.hpp"

#include <cctype>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

#include "llmconfig.hpp"
#include "agenttools.hpp"
#include "agentview.hpp"
#include "hardware.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_str.hpp"

namespace fs = std::filesystem;

namespace bot {
namespace agent {

namespace {

/* 显式 "none" = 本次不读配置文件。
 * 为什么需要：缺省查找会看 CWD 里的 ./mybot.llm.json，于是「同一份配置换台机器就
 * 变了行为」——CI/守门尤其需要确定性（否则开发者个人配置会悄悄改变测试结果，
 * 实测踩过）。命令行与环境变量都支持该值。 */
bool isConfigDisabled(const std::string& s) {
	return toLowerAscii(trim(s)) == "none";
}

/* 选配置文件：命令行 > 环境变量 BOT4CJ_LLM_CONFIG > 缺省查找。找不到即返回空串
 * （配置文件是可选的）；显式给了路径却读不到由 loadLlmConfigFile 报错——不能
 * 静默回落到缺省，否则用户会以为配置生效了。 */
std::string pickConfigPath(const CliOptions& opts) {
	if (!opts.agent.llmConfig.empty()) {
		return isConfigDisabled(opts.agent.llmConfig) ? std::string() : opts.agent.llmConfig;
	}
	if (auto env = getEnvVar("BOT4CJ_LLM_CONFIG"); env && !env->empty()) {
		return isConfigDisabled(*env) ? std::string() : *env;
	}
	return findDefaultLlmConfig();
}

} // namespace

/* PL-1（2026-09-22）：把**已经校验通过的**后端配置渲染成人类可读摘要。
 * 为什么是纯渲染而不是「再校验一遍」：校验是 buildAgentConfig 的单点职责，
 * 它失败时调用方已经 return 2。这里再造一套判据只会带来两处漂移——
 * 正是本项目反复强调要避免的。因此本函数只读 cfg、无副作用、可离线单测。
 * 2026-09-26：agent 循环迁 Rust 后，这里只报 --mcp-backend 工具面真实生效的
 * 配置；模型侧（endpoint/model/key/采样/提示词/会话）由 mybot-agent --check-config
 * 自行校验，宿主不再打印——否则恒为缺省值的「接入点未配置」只会误导操作者。 */
std::string summarizeAgentConfig(const AgentModeConfig& cfg) {
	auto orNone = [](const std::string& s, const char* fallback) {
		return s.empty() ? std::string(fallback) : s;
	};

	std::string s;
	s += "配置校验通过（--mcp-backend 工具后端）：\n";
	if (!cfg.configPath.empty()) { s += "  配置文件    : " + cfg.configPath + "\n"; }
	else { s += "  配置文件    : (未使用)\n"; }
	s += "  结构脚本    : " + cfg.structurePath + "\n";
	s += "  动作脚本目录: " + cfg.scriptsDir + "\n";
	s += "  工具超时    : run_command=" + std::to_string(cfg.commandTimeoutSec)
		+ "s，上限=" + std::to_string(cfg.maxCommandTimeoutSec)
		+ "s，action_script=" + std::to_string(cfg.scriptTimeoutSec) + "s\n";
	s += "  摄像头      : " + std::string(cfg.allowCamera
			? (cfg.cameraSrc.empty() ? "启用（变量 " + cfg.cameraVar + "，设备 "
					+ orNone(cfg.cameraDevice, "/dev/video0（驱动缺省）") + "）"
				: "启用（模拟来源 " + cfg.cameraSrc + "）")
			: "不提供 capture_image 工具") + "\n";
	s += "  run_command : " + std::string(cfg.allowShell ? "已开启（--agent-shell）" : "未提供（缺省关）") + "\n";
	s += "  apply_sql   : " + std::string(cfg.allowHotSql ? "已开启（--agent-hot-sql）" : "未提供（缺省关）") + "\n";
	/* 回读：只报**声明了什么**（能不能解析要到上电后才知道，判据不在摘要这一层；
	 * 会话开始时的提示会点名被跳过的名字）。 */
	s += "  read/wait_variable: " + (cfg.readVars.empty()
			? std::string("未提供（缺省关；用 --read-var <变量名> 指定可读变量）")
			: "已声明 " + std::to_string(cfg.readVars.size()) + " 项") + "\n";
	s += "  list_dir/read_file: " + (cfg.fsRoot.empty()
			? std::string("未提供（缺省关；用 --fs-root <目录> 指定只读根目录）")
			: "已开启（根目录 " + cfg.fsRoot + "）") + "\n";
	s += "  write_file  : " + std::string(cfg.allowWriteFile
			? "已开启（--agent-write-file，根目录同 --fs-root）" : "未提供（缺省关）") + "\n";
	s += "  审计轨迹    : " + orNone(cfg.auditLogPath, "(未开启)") + "\n";
	s += "  策略钩子    : " + orNone(cfg.policyPath, "(未启用)") + "\n";
	s += "  断连安全动作: " + orNone(cfg.onDisconnectScript, "(未配置；断连后硬件停在最后姿态)") + "\n";
	return s;
}


/* 结构脚本展示名（去目录、去 .sql 后缀）：REPL 提示符、会话文件的 robot 指纹
 * 字段与 MCP 后端 context.get 的 robotName 共用同一份（批次 1）——各写一遍
 * 迟早分叉。声明在 agentmode.hpp（mcpbackend.cpp 也用）。 */
std::string structureDisplayName(const std::string& path) {
	std::string name = path;
	if (std::size_t slash = name.rfind('/'); slash != std::string::npos) {
		name = name.substr(slash + 1);
	}
	if (name.size() > 4 && name.substr(name.size() - 4) == ".sql") {
		name = name.substr(0, name.size() - 4);
	}
	return name;
}

namespace {

/* 分层选取（命令行 > 环境变量 > 配置文件 > 空）：envName=null 跳过环境层 */
std::string pickString(const std::string& cli, const char* envName,
		const std::optional<std::string>& fromFile) {
	if (!cli.empty()) { return cli; }
	if (envName != nullptr) {
		if (auto v = getEnvVar(envName); v && !v->empty()) { return *v; }
	}
	return fromFile.value_or("");
}

bool mergeToolBudgets(const LlmFileConfig& file, AgentModeConfig& out, std::string& err) {
	if (file.runCommandTimeoutSec) { out.commandTimeoutSec = *file.runCommandTimeoutSec; }
	if (file.runCommandMaxTimeoutSec) {
		out.maxCommandTimeoutSec = *file.runCommandMaxTimeoutSec;
	}
	if (file.actionScriptTimeoutSec) { out.scriptTimeoutSec = *file.actionScriptTimeoutSec; }
	// 只配置上限时，也必须与合并后的缺省超时比较。
	if (out.maxCommandTimeoutSec < out.commandTimeoutSec) {
		err = "run_command 超时上限低于缺省超时（run_command_max_timeout_sec="
			+ std::to_string(out.maxCommandTimeoutSec) + "s < run_command_timeout_sec="
			+ std::to_string(out.commandTimeoutSec) + "s）：请把上限调到不小于缺省，"
			"或一并调小缺省超时";
		return false;
	}
	return true;
}

/* ---- 6) 摄像头（capture_image） ---- */
bool pickCamera(const CliOptions& opts, const LlmFileConfig& file,
		AgentModeConfig& out, std::string& err) {
	out.allowCamera = opts.agent.noCamera ? false : file.allowCamera.value_or(true);
	out.cameraVar = pickString(opts.agent.cameraVar, nullptr, file.cameraVar);
	if (out.cameraVar.empty()) { out.cameraVar = "cam0"; }
	if (!isSafeIdent(out.cameraVar)) {
		err = "摄像头变量名必须是安全标识符（字母/数字/下划线），实际是 '"
			+ out.cameraVar + "'（来自 --camera-var 或配置文件的 camera_var 字段）";
		return false;
	}
	out.cameraDevice = pickString(opts.agent.cameraDevice, nullptr, file.cameraDevice);
	out.cameraSrc = pickString(opts.agent.cameraSrc, nullptr, file.cameraSrc);
	/* H1：来源决定「能不能用 src 自己推导白名单根」（判据见 agenttools.hpp 的
	 * AgentToolContext）。pickString 里命令行优先，故命令行非空即等于采用了它。 */
	out.cameraSrcFromCli = !opts.agent.cameraSrc.empty();
	/* H1：白名单根目录**只从命令行**取；配置文件写 camera_src_dir 由
	 * buildAgentConfig 拒绝加载（与 allow_shell 同判据，见那里）。 */
	out.cameraSrcDir = opts.agent.cameraSrcDir;
	return true;
}

/* ---- 各编号步骤的具名实现（拆分自 buildAgentConfig：原函数把编号步骤全部
 * 内联，读哪个判据都要先定位到步骤号再往下翻；拆出后每个函数一个职责，
 * 签名/判据/文案不变——编排顺序仍是下面的 buildAgentConfig）。
 * 2026-09-26：LLM 层（endpoint/model/key/采样）与会话恢复组合校验随 agent
 * 循环迁 Rust 删除，剩下的都是 --mcp-backend 真实执行的步骤。 */

/* 「配置文件只能收紧、不能放宽」的统一报错口径：放宽能力的一侧（哪个字段、
 * 为什么危险、该敲哪个命令行开关）一次说全，四个字段共用同一形态。 */
std::string relaxingFieldError(const std::string& cfgPath, const std::string& field,
		const std::string& why, const std::string& cliSwitch) {
	return "配置文件 " + (cfgPath.empty() ? std::string("(缺省查找)") : cfgPath)
		+ " 设置了 " + field + "：" + why
		+ "，只能由命令行 " + cliSwitch + " 提供，配置文件不能给"
		+ "（请删除该字段或置回缺省；缺省查找会读 CWD 的 ./mybot.llm.json，"
		  "「这个文件存在」不构成授权）";
}

/* 6/7/7b) 摄像头与能力门控。H1：camera_src_dir 决定 capture_image 的模拟图片
 * 白名单根，等价于**放宽读权限**，故与 allow_shell 同判据——只能命令行给。
 * 缺省查找会读 CWD 的 ./mybot.llm.json，于是一个未经审查的落地文件就能同时
 * 改 endpoint（外发）+ camera_src（读哪个文件）+ 白名单根（能不能读）+
 * 注册 run_command（模型回复直接变成主机 shell），把「任意文件 → base64 →
 * 模型上下文 → 攻击者网关」串成一条链；而 allow_camera 缺省为真、cam0 自动
 * 注入，这条链**不需要 --agent-shell**——所以四个字段一律「配置文件只能关」。 */
bool applyGatingLayer(const CliOptions& opts, const LlmFileConfig& file,
		const std::string& cfgPath, AgentModeConfig& out, std::string& err) {
	/* 6) 摄像头（变量名/设备/来源的常规三层合并已在 pickCamera 内完成） */
	if (!pickCamera(opts, file, out, err)) { return false; }
	if (file.cameraSrcDir) {
		err = relaxingFieldError(cfgPath, "camera_src_dir",
			"它决定 capture_image 能读哪个目录（放宽读权限）", "--camera-src-dir");
		return false;
	}

	/* 7) agent 行为：scripts-dir 命令行优先；两个危险开关缺省**不提供**
	 * 且只能命令行开（安全缺省：评估 C12 翻转 + 审计 4.1 收紧；
	 * 热插表 2026-09-23 与 run_command 同判据——apply_sql 会长出新硬件并
	 * **立即上电**，「模型回复直接改变带电的硬件结构」）。 */
	out.scriptsDir = opts.agent.scriptsDir.empty() ? "scripts" : opts.agent.scriptsDir;
	if (opts.agent.scriptsDir.empty() && file.scriptsDir) { out.scriptsDir = *file.scriptsDir; }
	out.allowShell = opts.agent.agentShell;
	if (!opts.agent.agentShell && file.allowShell.value_or(false)) {
		err = relaxingFieldError(cfgPath, "allow_shell",
			"run_command 等于把主机 shell 交给模型", "--agent-shell");
		return false;
	}
	out.allowHotSql = opts.agent.agentHotSql;
	if (!opts.agent.agentHotSql && file.allowHotSql.value_or(false)) {
		err = relaxingFieldError(cfgPath, "allow_hot_sql",
			"apply_sql 会按模型给的 SQL 立即装配并给新硬件上电（开 fd、进断电清理链）",
			"--agent-hot-sql");
		return false;
	}
	out.structurePath = opts.robot ? *opts.robot : "";

	/* 7b) 回读清单（发现 2 的 A 步，2026-09-23）：「能读哪些变量」是由操作者
	 * 授予的能力（执行器与传感器靠种类分不开，Servo/Relay 也是 lua 驱动，
	 * 清单必须由人列），同上四个字段：只能命令行给。 */
	out.readVars = opts.agent.readVars;
	if (file.readVars) {
		err = relaxingFieldError(cfgPath, "read_vars",
			"它决定模型能主动读哪些硬件变量（等同于给模型一条读通道）", "--read-var");
		return false;
	}

	/* Phase 4（2026-10-07）：list_dir / read_file 的只读根目录。同上四个字段：
	 * 只能命令行给——它决定"能读哪个目录"，等价于放宽读权限。 */
	out.fsRoot = opts.agent.fsRoot;
	if (file.fsRoot) {
		err = relaxingFieldError(cfgPath, "fs_root",
			"它决定 list_dir/read_file 能读哪个目录（等同于给模型一条主机文件读通道）",
			"--fs-root");
		return false;
	}
	/* 给了根就校验它是真实存在的目录——与 --on-disconnect 的上电前预检同口径：
	 * 配置错误在结构装载与上电之前失败，而不是等模型第一次调 list_dir 才发现。
	 * 这里**不**做 canonical 化后替换 out.fsRoot（保持操作者原样传入，判据单点
	 * 仍是工具层的 resolveUnderRoot）；只做一次可读性/类型体检。 */
	if (!out.fsRoot.empty()) {
		std::error_code ec;
		const fs::path p = fs::canonical(out.fsRoot, ec);
		if (ec || !fs::is_directory(p, ec)) {
			err = "--fs-root 只读根目录不可用（不存在或不是目录）: " + out.fsRoot;
			return false;
		}
	}

	/* Phase 5（2026-10-08）：write_file 的独立开关。与 allow_shell/allow_hot_sql
	 * 同判据——写权限（能覆盖/改写主机文件）只能命令行 --agent-write-file 给，
	 * 配置文件写 true 拒绝加载。 */
	out.allowWriteFile = opts.agent.agentWriteFile;
	if (!opts.agent.agentWriteFile && file.allowWriteFile.value_or(false)) {
		err = relaxingFieldError(cfgPath, "allow_write_file",
			"write_file 能覆盖/改写主机文件（覆盖不可逆）", "--agent-write-file");
		return false;
	}
	/* 跨字段依赖：write_file 复用 --fs-root 作为写根，故给了 --agent-write-file
	 * 却没给 --fs-root 是配置错误（写权限天然应 ⊆ 读权限，没有"只能写不能读"
	 * 的正当场景）。在结构装载与上电之前失败（配置错误不碰真机）。 */
	if (out.allowWriteFile && out.fsRoot.empty()) {
		err = "--agent-write-file 需要同时提供 --fs-root <目录>"
			"（write_file 在其中创建/覆盖文件，写根复用只读根，不能只写不读）";
		return false;
	}
	return true;
}

/* 10) 审计轨迹：在这里就打开——路径打不开属于配置错误，必须在结构装载与
 * 上电之前失败（「配置错误不碰真机」），而不是等到第一次工具调用才炸。 */
bool openAuditLog(const CliOptions& opts, const LlmFileConfig& file,
		AgentModeConfig& out, std::string& err) {
	out.auditLogPath = pickString(opts.agent.auditLog, nullptr, file.auditLog);
	if (!out.auditLogPath.empty()) {
		out.audit = std::make_shared<AuditLog>();
		if (std::string auditErr; !out.audit->open(out.auditLogPath, auditErr)) {
			err = auditErr;
			return false;
		}
	}
	return true;
}

/* 11) 策略钩子：在这里就加载——策略文件写错属于配置错误，必须在上电之前
 * 失败（同一口径）。注意它**不是**安全边界：确认程序与宿主同权限，真正的
 * 隔离仍是专用用户 / 容器（docs/agent.md 安全一节的既有口径不变）。 */
bool loadPolicyHook(const CliOptions& opts, const LlmFileConfig& file,
		AgentModeConfig& out, std::string& err) {
	out.policyPath = pickString(opts.agent.agentPolicy, nullptr, file.agentPolicy);
	if (!out.policyPath.empty()) {
		if (std::string policyErr; !(out.policy = AgentPolicy::load(out.policyPath, policyErr))) {
			err = policyErr;
			return false;
		}
	}
	return true;
}

/* 11b) MCP 后端 + 危险能力 ⇒ 强制外部确认（评估 §3.2，用户定「折中」）。
 * --mcp-backend 把工具暴露给**任意外部 MCP 客户端**、且硬件全程带电常驻，
 * 信任面比坐在终端前的 agent REPL 大得多。故当后端开了危险能力时，**强制**
 * 要有策略钩子、且该钩子确实对相应工具要求外部确认（require_confirm，超时
 * fail-closed）：
 *   --agent-shell   （run_command）→ 策略必须 require_confirm "run_command"
 *   --agent-hot-sql （apply_sql）  → 策略必须 require_confirm "apply_sql"
 *   --agent-write-file（write_file）→ 策略必须 require_confirm "write_file"
 * 折中：纯只读 / 查询 / 动作脚本后端（未开上述危险能力）不受此约束。
 * 注意 agentpolicy 仍**不是**隔离边界（同 uid 进程可绕过，见 docs/agent.md
 * 与 mcpbackend.hpp 的残留风险说明）——它是「每次调用先过人/审批」的确认闸门。 */
bool enforceBackendConfirmPolicy(const CliOptions& opts, const AgentModeConfig& out,
		std::string& err) {
	if (!opts.mcp.enabled) { return true; }
	if (out.allowShell
		&& (out.policy == nullptr || !out.policy->requiresConfirm("run_command"))) {
		err = "--mcp-backend 开了 --agent-shell（run_command）：后端对外暴露且硬件带电，"
			"必须用 --agent-policy 提供策略钩子，且其 require_confirm 必须包含 \"run_command\""
			"（无人值守暴露任意 shell 必须有外部确认闸门）";
		return false;
	}
	if (out.allowHotSql
		&& (out.policy == nullptr || !out.policy->requiresConfirm("apply_sql"))) {
		err = "--mcp-backend 开了 --agent-hot-sql（apply_sql）：后端对外暴露且硬件带电，"
			"必须用 --agent-policy 提供策略钩子，且其 require_confirm 必须包含 \"apply_sql\""
			"（热插表会立即给新硬件上电，必须有外部确认闸门）";
		return false;
	}
	if (out.allowWriteFile
		&& (out.policy == nullptr || !out.policy->requiresConfirm("write_file"))) {
		err = "--mcp-backend 开了 --agent-write-file（write_file）：后端对外暴露，"
			"必须用 --agent-policy 提供策略钩子，且其 require_confirm 必须包含 \"write_file\""
			"（无人值守暴露改写主机文件的能力必须有外部确认闸门，覆盖又是不可逆操作）";
		return false;
	}
	return true;
}

/* 11c) 断连安全动作（--on-disconnect）：上电前预检脚本能装载——路径越界 /
 * 不存在 / 为空都是配置错误，必须在这里失败。否则要等到**第一次断连**、也就是
 * 最需要它的那一刻才发现脚本名拼错，硬件照旧停在最后一个姿态。判据与
 * run_action_script 同源（loadActionScriptFile），不另写一份。 */
bool precheckDisconnectScript(const CliOptions& opts, AgentModeConfig& out, std::string& err) {
	out.onDisconnectScript = opts.mcp.onDisconnect;
	if (out.onDisconnectScript.empty()) { return true; }
	try {
		(void)loadActionScriptFile(out.scriptsDir, out.onDisconnectScript);
	} catch (const std::exception& e) {
		err = "--on-disconnect 脚本不可用 [" + out.onDisconnectScript + "]: " + e.what()
			+ "（须是 --scripts-dir 之下的相对路径，且非空）";
		return false;
	}
	return true;
}

/* 11d) MCP 首帧共享密钥（2026-09-29，审计 P2-1）：环境变量 BOT4CJ_MCP_TOKEN。
 * 只认环境变量（命令行会进全局可读的 cmdline；配置文件是低信任层）。
 * fail-closed 两类显式拒绝：set-but-empty（操作者以为开了认证、实际静默裸奔）
 * 与超长（多半是把文件路径或别的什么误当密钥给了）。上限 256：真实共享密钥
 * 用不到更长，而帧上限/日志体积都不必为它让路。
 * 必须在 prepareAgentConfig 的 scrubEnvSecrets 之前调用（此后 environ 里
 * 这个名字已被抹零，再 getenv 只得 nullptr）——buildAgentConfig 的调用序
 * 已保证（scrub 在 build 之后）。 */
bool captureMcpAuthToken(AgentModeConfig& out, std::string& err) {
	const auto v = getEnvVar("BOT4CJ_MCP_TOKEN");
	if (!v) { return true; }	/* 未设置 = 不启用（现状语义） */
	constexpr std::size_t kMaxTokenBytes = 256;
	if (v->empty()) {
		err = "BOT4CJ_MCP_TOKEN 已设置但为空——首帧认证无法启用。"
			"要么给非空值，要么 unset 它；空值会被当作「想开认证但没开成」"
			"处理（拒绝启动），不会静默退回无认证。";
		return false;
	}
	if (v->size() > kMaxTokenBytes) {
		err = "BOT4CJ_MCP_TOKEN 过长（" + std::to_string(v->size())
			+ " 字节，上限 " + std::to_string(kMaxTokenBytes)
			+ "）——共享密钥不需要这么长，请确认给的不是文件路径。";
		return false;
	}
	out.mcpAuthToken = *v;
	return true;
}

} // namespace

bool buildAgentConfig(const CliOptions& opts, AgentModeConfig& out, std::string& err) {
	/* 编排：后端配置组装按序落位，每步的判据/文案在上方对应的具名函数里。
	 * 任何一步失败都发生在结构装载与上电之前（「配置错误不碰真机」）。
	 * 2026-09-26：agent 循环迁 Rust 后，LLM 层（endpoint/model/key/采样）、
	 * 提示词包装载、体积预检与会话恢复组合校验都已删除——它们在 --mcp-backend
	 * 下永不生效（详见 agentmode.hpp 的 AgentModeConfig 收缩说明）。
	 * 2026-10-01 批次 A（P1-5）：上下文字节预算的搬运与摘要行（applyContextBudgets）
	 * 连同 R5m 互钉一并退役——后端从不消费这三个值，单一事实源是 Rust config.rs。 */

	/* 1) 配置文件（最低优先级的一层，命令行/环境变量随后覆盖） */
	LlmFileConfig file;
	std::string cfgPath = pickConfigPath(opts);
	if (!cfgPath.empty()) {
		if (!loadLlmConfigFile(cfgPath, file, err)) { return false; }
		out.configPath = cfgPath;
	}

	if (!mergeToolBudgets(file, out, err)) { return false; }			/* 工具层超时 */
	if (!applyGatingLayer(opts, file, cfgPath, out, err)) { return false; }	/* 6/7/7b) 门控 */
	if (!openAuditLog(opts, file, out, err)) { return false; }		/* 10) 审计 */
	if (!loadPolicyHook(opts, file, out, err)) { return false; }		/* 11) 策略钩子 */
	if (!enforceBackendConfirmPolicy(opts, out, err)) { return false; }	/* 11b) 后端强制确认 */
	if (!precheckDisconnectScript(opts, out, err)) { return false; }	/* 11c) 断连安全动作 */
	if (!captureMcpAuthToken(out, err)) { return false; }		/* 11d) MCP 首帧密钥 */
	return true;
}

/* 组装工具上下文（AgentToolContext）：agent REPL 与 MCP 后端（--mcp-backend）
 * 共用这一个函数——「对外提供哪些工具、能读哪些变量、摄像头怎么解析」的判据
 * 只在这里发生一次，两条路径不会漂移（后端暴露的工具集与 agent 模式逐字节一致）。
 * 只读配置 + robot，不发起模型调用、不上电（调用方负责 active() 在先）。
 *
 * 2026-10-10 评估后判不改（两结构同构的镜像）：AgentModeConfig 是 CLI/配置
 * 入口（还带 mcpAuthToken / onDisconnectScript / audit / policy / verbose 等
 * 永远不进工具上下文的字段），AgentToolContext 是工具运行期视图（robot 指针、
 * 已解析的摄像头指针）——分层不同、非同构，逐字段拷贝是适配器本身而不是
 * 待消除的重复；抽成转换构造只是搬位置。真正的漂移风险（配置加了字段却忘了
 * 传导）由 test_llmconfig_assembly 的 fsRoot/allowWriteFile/camera 传导钉覆盖。 */
AgentToolContext makeToolContext(const AgentModeConfig& cfg, RobotStruct& robot,
		std::ostream& log) {
	AgentToolContext tctx;
	tctx.robot = &robot;
	tctx.scriptsDir = cfg.scriptsDir;
	tctx.structurePath = cfg.structurePath;
	tctx.allowShell = cfg.allowShell;
	tctx.allowHotSql = cfg.allowHotSql;
	tctx.commandTimeoutSec = cfg.commandTimeoutSec;
	tctx.maxCommandTimeoutSec = cfg.maxCommandTimeoutSec;
	tctx.scriptTimeoutSec = cfg.scriptTimeoutSec;	/* PL-2：动作脚本执行预算 */
	tctx.readVars = cfg.readVars;			/* 发现 2 的 A 步：声明原文（注册时解析） */
	tctx.fsRoot = cfg.fsRoot;	/* Phase 4：已在 buildAgentConfig 校验存在且是目录 */
	tctx.allowWriteFile = cfg.allowWriteFile;	/* Phase 5：已在 buildAgentConfig 校验依赖 fsRoot */
	/* 声明的可读变量里被跳过的那些（未注册 / 种类不是 lua·daemon）如实告知：
	 * 静默丢能力正是本项目反复要避免的形态——`--read-var` 敲错一个字，
	 * 操作者必须能从启动输出里看出来，而不是等到模型说"我读不到"。 */
	if (!cfg.readVars.empty()) {
		std::vector<std::string> skipped;
		const std::vector<std::string> resolved = resolvableReadVars(cfg.readVars, robot, &skipped);
		if (resolved.empty()) {
			log << "提示: --read-var 声明的变量一个都不可读（未注册，或种类不是 lua/daemon），"
				"本次不提供 read_variables / wait_variable 工具\n";
		}
		if (!skipped.empty()) {
			log << "提示: 以下 --read-var 声明被跳过（未注册，或种类不是 lua/daemon）: "
				<< joinNames(skipped) << "\n";
		}
	}
	if (cfg.allowCamera) {
		tctx.camera = robot.registry().find(cfg.cameraVar);
		tctx.cameraDevice = cfg.cameraDevice;
		tctx.cameraSrc = cfg.cameraSrc;
		/* H1：白名单的两个输入分别传递——来源标记决定"能不能用 src 推导根"，
		 * cameraSrcRoot 是操作者显式给的根（只能来自命令行，见 buildAgentConfig）。 */
		tctx.cameraSrcFromCli = cfg.cameraSrcFromCli;
		tctx.cameraSrcRoot = cfg.cameraSrcDir;
		if (tctx.camera == nullptr) {
			if (cfg.verbose) {
				log << "提示: 结构脚本里没有摄像头驱动变量 '" << cfg.cameraVar
					<< "'，本次不提供 capture_image 工具\n";
			}
		} else if (std::string_view(tctx.camera->kindName()) != "lua") {
			/* 必须是 Lua 驱动：playQuiet 对别的种类就退化成 play()（hardware.hpp），
			 * 那样模型调一次「拍照」就会向别名/数值变量/舵机真下发 {path,src}。
			 * 与 agentdriver 对 LLM 驱动的种类校验同一条判据。 */
			if (cfg.verbose) {
				log << "提示: 硬件变量 '" << cfg.cameraVar << "' 不是 Lua 驱动（实际是 "
					<< tctx.camera->kindName() << "），本次不提供 capture_image 工具\n";
			}
			tctx.camera = nullptr;
		}
	}
	return tctx;
}

} // namespace agent
} // namespace bot
