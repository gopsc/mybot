#pragma once
/* agentview.hpp —— 只读视图族（agentview.cpp 的对外契约）
 *
 * 2026-10-01 自 agenttools.hpp 析出（行为保持，robot.hpp A2 窄头模式）；
 * 2026-10-10 契约归位：本 TU 实现的 describeActionScripts / describeHardware /
 * runSqlStatement / resolveActionScriptPath / appendActionEcho 原先声明在
 * agenttools.hpp（拆分时留下的错位——「声明各归各位」是 robot.hpp A2 立下的
 * 原则），现随实现归本头。消费者（agenttools/agenttools_fs/agentmode/
 * context_service/测试）经本头引用；工具装配契约（AgentToolRegistry/
 * makeAgentTools/loadActionScriptFile 等）仍在 agenttools.hpp。 */

#include <cstddef>
#include <string>
#include <vector>

namespace bot {

class RobotStruct;

namespace agent {

/* ---- 发现 2 的 A 步（2026-09-23）：可读变量清单与回读工具 ----
 * 动机：D 步只让模型看见"动作脚本顺带读到的值"，它仍无法**主动**读。而 agent
 * 无法靠"种类"区分传感器与执行器——`Servo.lua` / `Relay.lua` 同样是 `kind=lua`，
 * 对它们调 `play()` 会真驱动硬件（Relay 的 `call({})` 会把 delay 转发给 controller）。
 * 故可读集合由**操作者显式声明**（`--read-var`，可重复，命令行独占；配置文件写
 * `read_vars` 会被拒绝加载，与 `--agent-shell` / `camera_src_dir` 同判据）。
 * 清单为空 = **不注册** `read_variables`（缺省即无此能力）。 */
inline constexpr std::size_t kMaxReadResultBytes = 8u << 10;

/* 解析声明清单 → 当前机器人上**真正可读**的变量：必须已注册，且种类为 `lua`
 * （驱动）或 `daemon`（守护快照——读的是已发布的采样，无 I2C 流量、无副作用）。
 * 其余（别名 / 数值变量 / 名字不存在）一律跳过：既不因一个拼错的名字让整条能力
 * 失效，也不放行"种类不对"的变量（`playQuiet` 对非 lua/daemon 会退化成 `play()`，
 * 与 `capture_image` 的种类防线同一理由）。@p skipped 非空时收集被跳过的名字，
 * 供启动时如实告知（不静默降级）。 */
std::vector<std::string> resolvableReadVars(const std::vector<std::string>& requested,
		RobotStruct& robot, std::vector<std::string>* skipped = nullptr);

/* 渲染回读工具的回执：截断（`kMaxReadResultBytes`）+ UTF-8 消毒 +
 * 「数据非指令」定界（单点，便于离线断言）。 */
std::string formatReadResult(const std::string& body);

/* 系统提示词里的可读变量清单（已解析；空 = 不列）。与工具注册同一解析函数，
 * 两处不会漂移。 */
std::string describeReadableVars(const std::vector<std::string>& requested, RobotStruct& robot);

/* ---- 供工具与系统提示词共用的描述函数（2026-10-10 归位自 agenttools.hpp）---- */

/* 动作脚本清单：递归收集 scriptsDir 下的 *.mt，输出「相对路径 — 首行注释」。
 * 目录不存在时返回一行说明而非抛（提示词里如实告知模型即可）。 */
std::string describeActionScripts(const std::string& scriptsDir);

/* 已注册硬件变量清单。只读名字与种类，绝不调用 read()/play()
 * （对舵机等执行器，play({}) 会真的下发指令）。 */
std::string describeHardware(RobotStruct& robot);

/* ---- SQL 只读渲染（query_sql 工具的单一事实源；2026-10-10 归位自
 * agenttools.hpp）----
 * 解析一条结构 SQL 并渲染成文本。只读、无副作用：不装配硬件、不改结构矩阵。
 *   * SELECT * FROM t —— 从运行时结构矩阵（robot.structures().all()）取数渲染；
 *   * CREATE/INSERT —— 只解析回显（语法验证），不落任何状态。
 * 失败经 SqlOutcome::ok=false 显式传递（此前以「错误: 」字符串前缀当错误码、
 * 调用方再 rfind 前缀翻回异常——文案改动即断链）；text 为**不带前缀**的人话
 * 原因（解析器带行列定位），前缀由调用方按自己的口径渲染。
 * 沿革：REPL /sql（runSqlCommand，全 SELECT 走本函数、含写语句转 applySql
 * 带电生效）与它身边的 SqlStatementBatch 已随 C++ REPL 迁 Rust 删除——
 * 操作者侧的 SQL 通道由 Rust REPL 的 /sql 经 tool.call 直接复用本函数所在
 * 的 query_sql 工具（只读）；带电生效仍是 apply_sql 工具 + applySql 的事。 */
struct SqlOutcome {
	bool ok = true;
	std::string text;
};

SqlOutcome runSqlStatement(const std::string& sql, const RobotStruct& robot);

/* 动作脚本路径解析：请求必须是 scriptsDir 之下的相对路径。
 * 拒绝绝对路径、空段、"."/".."、以及含 NUL 的名字（NUL 会让
 * fopen 截断路径，是「校验的路径 ≠ 打开的路径」经典绕过）。 */
std::string resolveActionScriptPath(const std::string& scriptsDir, const std::string& requested);

/* ---- D（2026-09-23）：动作脚本执行期间的驱动返回表回收（归位自
 * agenttools.hpp）----
 * `run_action_script` 此前只回一句「已执行动作脚本 X（N 字节）」——**模型看不到
 * 任何读数**，而器件读到的值事实上早已产生：`play()` 的顶层回显（luavar 的
 * res / ctrl_res 表，如 BH1750 的 `{result="OK", LUX=…}`）此前只写 stderr，
 * 操作者看得见、模型看不见。现在执行窗口内挂一条回收通道，把回显经本函数追加
 * 进工具回执（见 `kMaxActionEchoBytes`）。 */
inline constexpr std::size_t kMaxActionEchoBytes = 8u << 10;

/* 把回收到的回显追加进回执文本。单点职责：截断 + UTF-8 消毒 + 「数据非指令」
 * 定界（`quoteUntrusted`），便于离线断言。@p echo 为空时**逐字节不改** out——
 * 无回显的脚本（旧式无参设备、`playQuiet` 路径）回执形态与改动前完全一致。 */
void appendActionEcho(std::string& out, const std::string& echo);

} // namespace agent
} // namespace bot
