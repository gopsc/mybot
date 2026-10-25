#pragma once
/* agenttools.hpp —— agent 模式工具层
 *
 * 工具全部作用于「常驻内存的机器人实例」（RobotStruct 已 active 且未 deactivate），
 * 这是 agent 模式相对于管道模式的关键差别：动作脚本一跑完硬件不释放，
 * 智能体可以在多轮工具调用之间保持机器人姿态与总线句柄。
 *
 * 工具层不认识 HTTP/模型：execute(args) 只吃 Json、吐文本，便于离线单测。
 */

#include <cstddef>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "agentproto.hpp"
#include "json.hpp"

namespace bot {

class RobotStruct;
class MatrixVars_Hardware;

namespace agent {

/* 运行时工具执行结果。跨进程 JSON 字段由 mcp_protocol.hpp 约束。 */
struct AgentToolResult {
	std::string text;
	std::string imageDataUrl;	/* 非空 = "data:image/jpeg;base64,..." */
	bool ok = true;			/* false = 工具本身失败（参数错/未知工具/异常） */
	std::string error;		/* ok=false 时的人话原因 */
	/* SAN-4（2026-09-22）：这一次调用**是否真的被派发给了工具**。
	 * false = 根本没执行（策略拒绝 / 未知工具 / 参数错误），因此**副作用必然未发生**；
	 * true（缺省）= 执行过，可能产生副作用——哪怕 ok=false（工具内失败、脚本跑了一半）
	 * 也一样，那种情况机器人可能停在半途，必须如实告知模型。
	 * 用途单点：TaskBudget::admit 据它决定"要不要说那句副作用已发生"。
	 * 为什么不用 ok 代替：`ok` 把"没执行"与"执行了但失败"混在一起，而这两件事
	 * 对模型的意义完全相反。 */
	bool executed = true;
	/* SAN-8②（2026-09-22）：这一次失败是**参数问题**（缺参数/类型不符/越界），
	 * 而不是执行问题。判据由工具层按**异常类型**给出（IllegalArgumentException），
	 * 派发漏斗据此把回执改成「工具参数错误: …」并把 executed 置 false——
	 * 模型看到的应当是"没执行、参数不对"，而不是"脚本执行失败、机器人可能停在半途"。 */
	bool paramError = false;
	/* G2（2026-09-23）：供审计对账的结构化**生效摘要**（与回传模型的 text 相对）：
	 * text 是给模型的自然语言回执，审计此前只能看到其中的 args（apply_sql 的
	 * SQL 原文）与 ok/error，复盘"这次热插到底改了什么"要重跑才能知道。
	 * summary 承载工具自己构造的机器可读生效信息，**原样进审计**（如 apply_sql
	 * 新增几张表/几个变量/几行、瞬态动作几行）。只做**加法**：老工具留空，
	 * 既有审计 schema 逐字节不变。 */
	std::string summary;
	/* G2 结构化出口（2026-10-10）：run_command 的退出码自结构化来源（RunResult）
	 * 直入审计，替代「审计从回执文本反解 exit_code=」的文本协议（extractExitCode
	 * 随该协议删除）——结构化值在 formatRunResult 处存在，此前被丢进文本、下一跳
	 * 再反解回来，自产自销的解析是多余的脆弱面。只被审计消费，不进 MCP 线协议；
	 * 给模型看的回执文本（含 exit_code= 行）逐字节不变。其余工具恒 nullopt。 */
	std::optional<long long> exitCode;
	/* 带构造函数（非聚合）：存量代码大量使用两字段初始化 {text, img}，聚合
	 * 形态下它们会触发 -Wmissing-field-initializers（本仓库 -Wall -Wextra
	 * 零告警基线）；构造函数让两字段形态显式表示「ok=true 缺省」。 */
	AgentToolResult() = default;
	AgentToolResult(std::string t, std::string img, bool ok_ = true, std::string err_ = "",
			bool executed_ = true, bool paramError_ = false, std::string summary_ = "")
		: text(std::move(t)), imageDataUrl(std::move(img)), ok(ok_), error(std::move(err_)),
		  executed(executed_), paramError(paramError_), summary(std::move(summary_)) {}
};

/* 一个可被模型调用的工具。execute 返回给模型的内容；抛异常表示工具失败
 * （注册表会折成「工具执行失败: ...」文本回传模型，不打断会话）。 */
struct AgentTool {
	std::string name;
	std::string description;
	Json parameters;	/* JSON Schema（object） */
	std::function<AgentToolResult(const Json& args)> execute;
};

class AgentToolRegistry {
	std::vector<AgentTool> tools_;
	/* 保留 vector 的注册顺序，同时用名称索引加速 contains/execute。
	 * 重名工具维持原有语义：第一个注册的工具优先。 */
	std::unordered_map<std::string, std::size_t> index_;

public:
	void add(AgentTool t) {
		const std::size_t index = tools_.size();
		const std::string name = t.name;
		tools_.push_back(std::move(t));
		index_.try_emplace(name, index);
	}
	bool contains(const std::string& name) const;

	/* 派发一次工具调用。未知工具与工具内部异常都折成文本返回
	 * （模型据此换个做法继续，而不是让整轮 agent 会话崩掉）。 */
	AgentToolResult execute(const std::string& name, const Json& args) const;

	std::vector<ToolSpec> specs() const;
};

/* 工具运行环境。robot 非空是前提（agent 模式必带 --robot）。 */
struct AgentToolContext {
	RobotStruct* robot = nullptr;
	std::string scriptsDir = "scripts";	/* 动作脚本根目录（相对路径沙箱边界） */
	std::string structurePath;		/* 结构脚本路径（仅用于工具输出标注） */
	int commandTimeoutSec = 10;		/* run_command 缺省超时 */
	int maxCommandTimeoutSec = 60;		/* run_command 超时上限 */
	bool allowShell = false;		/* true = 注册 run_command（安全阀门，缺省关） */
	/* 热插表（2026-09-23）：true = 注册 apply_sql（结构 SQL 带电生效）。
	 * 与 allowShell 同一条门控链（--agent-hot-sql，配置文件不能开）——
	 * 它同样让「模型的一次回复」直接改变带电的硬件结构。只读的 query_sql
	 * 无条件注册，不受这里影响。 */
	bool allowHotSql = false;
	/* 可读变量声明（--read-var，可重复；发现 2 的 A 步）。这里放的是**声明原文**，
	 * 注册与执行时各自经 resolvableReadVars 解析（已注册 + 种类 lua/daemon）——
	 * 于是"注册了没有"与"能读什么"共用同一函数，不会漂移。空 = 不注册该工具。 */
	std::vector<std::string> readVars;
	/* PL-2（2026-09-22）：动作脚本执行预算（秒）。run_action_script 是本工具集里
	 * **唯一曾无任何上界**的执行路径，而它默认开启；脚本本身是线性矩阵、DSL 无
	 * 循环，挂死只可能来自 Lua 驱动自己的 call()。>0 = 开启（窗口内关 JIT + 挂
	 * 指令计数钩子，见 luaexec.hpp）；<=0 = 明确关闭，退化为此前的无预算行为。 */
	int scriptTimeoutSec = 180;
	/* 摄像头：Lua 驱动变量（modules/Camera.lua）。为空 = 不注册 capture_image。
	 * 抓到的图片经 AgentToolResult.imageDataUrl 进入下一轮对话。 */
	MatrixVars_Hardware* camera = nullptr;
	std::string cameraDevice;	/* 空 = 用驱动缺省（/dev/video0） */
	std::string cameraSrc;		/* 非空 = 模拟图片来源文件（无摄像头也能跑通全链路） */
	/* ---- H1：模拟图片白名单的两个独立输入 ----
	 * 此前 src_root（"允许读哪个目录"）是由 cameraSrc 自己 `canonical` 后取
	 * parent_path 推导的 —— 而 src 的所在目录当然包含 src，判据**恒真**，
	 * 等于没有白名单：一份落在 CWD 的 ./mybot.llm.json 写 camera_src=/etc/shadow
	 * 就能把它 base64 读进模型上下文，再由同一份配置可控的 endpoint 外发；
	 * 而 allow_camera 缺省为真、cam0 自动注入，**不需要 --agent-shell**。
	 * 现在两者解耦：
	 *   cameraSrcRoot  = 显式根目录（--camera-src-dir，**只能命令行给**）；
	 *   cameraSrcFromCli = cameraSrc 是否来自命令行。只有命令行来源才允许用
	 *                     "src 的所在目录"当根（操作者自己指的文件，他本就能读，
	 *                     这也保住了 --camera-src 的快速上手路径）；配置文件来源
	 *                     一律不推导，交由驱动的 BOT4CJ_CAMERA_SRC_DIR 判定，
	 *                     两者都没有即驱动侧"未放行"拒绝。不推导、不猜、不回落 "."。 */
	bool cameraSrcFromCli = false;
	std::string cameraSrcRoot;
	/* Phase 4（2026-10-07）：list_dir / read_file 的只读根目录（--fs-root）。
	 * 空 = 不注册这两个工具（安全缺省）。**命令行独占**：它决定"能读哪个目录"，
	 * 等价于放宽读权限，判据与 cameraSrcRoot/readVars 同族——配置文件写 fs_root
	 * 会被 buildAgentConfig 拒绝加载。buildAgentConfig 已校验其 canonical 存在
	 * 且是目录（配置错误不碰真机），这里收到的要么是空串要么是已验证的路径。
	 * 路径沙箱判据单点在 agent_sandbox.hpp 的 resolveUnderRoot，不在本结构体内
	 * 重复判定。 */
	std::string fsRoot;
	/* write_file 的独立开关（Phase 5，2026-10-08，--agent-write-file）。
	 * **独立于 fsRoot**（不是 `!ctx.fsRoot.empty()` 的派生判据）：写权限不该
	 * 因为开了读根就静默获得，必须操作者再显式开一道。buildAgentConfig 已
	 * 校验它依赖 fsRoot 非空（见 agentmode.hpp），这里收到的要么两者都为真，
	 * 要么本字段为 false——工具注册判据仍按本字段本身判断（不按其蕴含的
	 * 前置条件），与 read_variables 用 resolvableReadVars(...).empty() 做
	 * 注册判据而不是"猜它应该蕴含什么"同一原则。 */
	bool allowWriteFile = false;
};

/* 构造标准工具集：list_action_scripts / run_action_script / list_hardware / query_sql，
 * （camera 非空时）capture_image，（allowHotSql 时）apply_sql，
 * （allowShell 时）run_command，（fsRoot 非空时）list_dir / read_file，
 * 以及（allowWriteFile 时）write_file。 */
AgentToolRegistry makeAgentTools(const AgentToolContext& ctx);

/* ---- 只读视图族（describeActionScripts / describeHardware / runSqlStatement /
 * resolveActionScriptPath / appendActionEcho）2026-10-10 归位 agentview.hpp
 * ——声明跟着实现 TU 走（robot.hpp A2「声明各归各位」同一原则）。 ---- */

/* 动作脚本装载（沙箱解析 + 体积上限读取 + 非空校验），失败抛 std::exception。
 * runActionScriptFile 的前半段；--on-disconnect 的上电前预检也走它——
 * "这个脚本能不能跑"的判据不因校验时机不同而分叉。 */
std::string loadActionScriptFile(const std::string& scriptsDir, const std::string& requested);

/* 动作脚本执行核心（2026-09-25，随 --on-disconnect 抽出）：loadActionScriptFile →
 * 执行预算窗口 → 回显回收 → robot->run。`run_action_script`
 * 工具与后端断连安全动作（mcpbackend）共用这一份，于是"哪些路径能跑、跑多久、
 * 回显怎么收"只有一处判据。requested 是 scriptsDir 之下的相对路径；返回脚本
 * 字节数；失败抛 std::exception（脚本不存在/为空/越界/执行失败），由调用方
 * 决定折成工具回执还是日志。@p echo 接收驱动 play() 的顶层回显文本。
 * @p vars：调用方临时注入的会话别名（透传给 robot->run 的 injectVars，见
 * robot.hpp）——脚本里的 $(键) 就地解析，作用域限本次 run()。缺省空 = 不注入。 */
std::size_t runActionScriptFile(const AgentToolContext& ctx, const std::string& requested,
		std::string& echo, const std::map<std::string, std::string>& vars = {});


} // namespace agent
} // namespace bot
