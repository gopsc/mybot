#pragma once
/* agentaudit.hpp —— agent 工具调用的审计轨迹（JSON Lines 追加写）
 *
 * 动机（原 docs/proposals/audit-approval-cancel.md P1，2026-09-23 移至 .tmp/）：
 * agent 会话此前唯一的痕迹是
 * 日志流（stderr）上的工具回显——无时间戳、无持久化、无结构化（该日志**恒开**，
 * 见 docs/agent.md；`--verbose` 不是本项目的选项）。现场机器人（部署形态 B）
 * 出事后「模型到底做了什么」无从复盘。本模块在**宿主工具派发的唯一漏斗**
 * （DispatchGate::run，见 agentdispatch）落一条 JSON Lines 记录。MCP 后端
 * （--mcp-backend）不发起模型调用，但工具条目仍经同一漏斗记账，会话头尾由
 * mcpbackend 自己记。
 *
 * 设计约束：
 *   * 默认关闭（--audit-log 不给 = 不写任何东西），开启即 append-only，
 *     不做轮转（交给外部工具）；
 *   * 图片**不进日志**：capture_image 的 base64 只记字节数与 64 位指纹——
 *     否则每次拍照数百 KB 灌进磁盘，且画面可能含隐私；
 *   * run_command 的命令原文要记，但 KEY=VALUE 形态的敏感值先遮蔽
 *     （maskSecretsInText；判据与 agent_subprocess 的环境清洗同源）；
 *   * 失败也记（含参数错误/工具异常）：「模型想做什么但没做成」同样是审计信息；
 *   * 只在 agent 主线程写（工具循环无并发派发），故不加锁。
 */

#include <memory>
#include <optional>
#include <string>

#include "json.hpp"

namespace bot {
namespace agent {

/* 一条工具调用审计记录。字段与 JSON 行的映射见 AuditLog::write。 */
struct AuditEntry {
	/* SAN-9（2026-09-22）：记录类型。**加法演进**——既有工具行的字段名、
	 * 顺序与语义一个不动，新增记录类型靠这个字段区分（老消费方按
	 * `tool == "run_command"` 之类的过滤表达式解析，结果逐字节不变）。
	 *   "tool"    —— 既有形态：一次工具调用；
	 *   "session" —— 会话边界（start/end/error/disconnect_action/auth_failed）。
	 * 2026-10-01 批次 A（P1-6）：kind="model" 与 session 的模型侧字段
	 * （driver/model/endpoint/api_key_source/resumed）随 agent 循环迁 Rust
	 * 退场——C++ 后端不发起模型调用，这些字段在本侧零写入者；模型轮次与
	 * 会话配置行由 Rust agent 自己的审计（agent/src/audit.rs，字段名同源）
	 * 写进 agent 侧审计文件，两端文件互不混合。 */
	std::string kind = "tool";
	int turn = -1;			/* 任务内的模型轮次（未知为 -1） */
	std::string requestId;		/* MCP 请求关联 ID（缺省不写） */
	std::string tool;		/* 工具名（kind="tool"）/ 事件名（kind="session"） */
	Json args;			/* 解析成功的参数对象（否则空） */
	std::string argsRaw;		/* 原始参数文本（截断到 kMaxAuditArgsRaw） */
	bool ok = true;			/* false = 参数错误/未知工具/工具异常/脚本执行失败 */
	std::string error;		/* ok=false 时的人话原因 */
	long long ms = 0;		/* 耗时（工具执行 / 模型调用） */
	std::size_t bytes = 0;		/* 回传模型的文本字节数 */
	std::size_t imageBytes = 0;	/* 图片 data URL 字节数（0 = 无图） */
	std::string imageFp;		/* 图片指纹（FNV-1a 64 hex，非密码学摘要） */
	std::optional<long long> exitCode;	/* run_command 专属（结构化直传，见 AgentToolResult::exitCode） */
	/* G2（2026-09-23）：工具自报的**生效摘要**（apply_sql 等热插/高危工具）。
	 * 只做加法：老工具不给，工具行的既有字段与顺序不动。 */
	std::string summary;

	/* ---- kind="session" 专用 ---- */
	std::string status;		/* "start" / "end" / "error" / "disconnect_action" / "auth_failed" */
};

/* 参数原文进审计前的截断上限：审计要能对账，但一条 2 MiB 的参数串会把日志
 * 本身变成体积源；超限截断并在值里显式标注（不静默）。 */
constexpr std::size_t kMaxAuditArgsRaw = 4096;

class AuditLog {
public:
	AuditLog() = default;
	AuditLog(const AuditLog&) = delete;
	AuditLog& operator=(const AuditLog&) = delete;
	~AuditLog();

	/* path == "-" 时写 stderr；其余为追加打开的文件路径。
	 * 打开失败返回 false 并把原因写进 err（调用方在上电前报错退出）。 */
	bool open(const std::string& path, std::string& err);

	/* 追加一条记录。日志流损坏（磁盘满等）时向 stderr 告警一次，不再静默。 */
	void write(const AuditEntry& e);

	bool enabled() const { return opened_; }
	const std::string& sessionId() const { return sessionId_; }
	const std::string& path() const { return path_; }

private:
	std::string path_;
	std::string sessionId_;
	bool opened_ = false;
	bool toStderr_ = false;
	bool warnBroken_ = false;	/* 损坏告警只打一次 */
	void* file_ = nullptr;		/* FILE*（避免在头里拖 <cstdio>） */
};

/* 把文本里「敏感名=值」等形态的值遮蔽成 ***（run_command 的命令原文进日志前调用）。
 * 名字判据与 agent_subprocess 的环境清洗同源（isSensitiveEnvName），另加
 * authorization/bearer 两个只对文本遮蔽有意义的词。值边界：空白或引号。
 * 覆盖四种形态：`KEY=VALUE`、`Name: value`（含 `Authorization: Bearer <tok>`）、
 * 裸 `Bearer <tok>`、以及 JSON 引号键 `"name": value`（2026-10-08 补，见实现处
 * 注释——本仓真实密钥落盘形态恰是最后一种）。 */
std::string maskSecretsInText(const std::string& text);

/* FNV-1a 64 位指纹的 hex 文本（16 字符）。用途是把图片在日志里对上号，
 * 不是防篡改——审计日志的完整性靠文件系统权限与外部收集，不靠摘要。 */
std::string fingerprint64(const std::string& s);

/* ISO-8601 本地时间戳（毫秒 + UTC 偏移），如 2026-09-22T17:04:11.238+08:00 */
std::string auditTimestamp();

} // namespace agent
} // namespace bot
