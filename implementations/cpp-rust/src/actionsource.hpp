#pragma once
/* actionsource.hpp —— 动作输入源（移植 bot4cj/src/ActionSource.cj）
 * 通道优先级：--tcp > --input > 标准输入 stdin。
 */

#include <cstddef>
#include <cstdio>
#include <chrono>
#include <iostream>		/* FileReader::read 的 I/O 错误告警走 std::cerr（评估后维持：
			 * <ostream> 只给类型、不给 std::cerr 这个对象） */
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <unistd.h>		/* TcpStreamReader 析构里的 ::close */

#include "scriptlimit.hpp"	/* kMaxScriptBytes / ScriptTooLarge / readAllLimited /
				 * LimitedReader：限流原语已析出叶子头（离线工具与 agent
				 * 工具层只引那份，不必拉进本头的 CLI/动作源域） */
#include "util_except.hpp"	/* Reader 基类（FileReader/TcpStreamReader 直接继承） */

namespace bot {

/* 命令行选项的类型化视图（main 经白名单校验后构造）。
 * tcpPort/tcpIdle 保留原始字符串：数值形态与范围校验在 openActionSource
 * 内完成（报错文案与退出路径不变），本结构只消灭 stringly-typed 键与查找。 */
/* 命令行选项的单一容器（2026-10-01 分组化，行为保持）：全局与输入源字段留在
 * 顶层，三个模式域各自嵌套成子结构——TCP 动作源（tcp）、agent 模式（agent，
 * MCP 后端复用其中的工具上下文门控）、MCP 后端模式（mcp）。原字段名保持
 * 不变（仅模式布尔改为组内 enabled），调用点只多一段路径。 */
struct CliOptions {
	std::optional<std::string> robot;
	bool help = false;
	std::string helpTopic;  /* 2026-09-22: --help <topic> 分段帮助 */
	std::optional<std::string> input;

	/* ---- Web SSH（--webshell-port，#24 feat/web-ssh MVP）----
	 * 浏览器终端服务：xterm.js → WebSocket(/ws/term) → forkpty → 交互 shell。
	 * 独立于 --tcp（那是动作输入源；这是终端服务）。缺省不启用：给
	 * --webshell-port 才监听；--webshell-token 不给 = 空口令（仅本机调试，
	 * 监听 127.0.0.1 时使用；非回环监听必须给 token，见 main 校验）。 */
	bool webshell = false;
	std::string webshellPort;
	std::string webshellHost = "127.0.0.1";
	std::string webshellToken;

	/* --daemon-grace-ms：RobotStruct::deactivate 二段屏障的宽限上限（原写死
	 * kMaxGraceMs=30000，2026-09-22 F-2 参数化）。全局选项（不限 --agent/
	 * --tcp/--input 任一模式——任何声明了 @Daemon 的结构脚本都可能触发弃管
	 * 路径）。字符串保留原始输入，校验在 main.cpp 内完成（与 tcpPort 同惯例，
	 * 报错文案单点）；空串 = 用缺省 30000。 */
	std::string daemonGraceMs;

	/* ---- TCP 动作源（--tcp）---- */
	struct Tcp {
		bool enabled = false;	/* --tcp */
		std::string tcpPort;
		std::string tcpHost = "127.0.0.1";
		std::string tcpToken;
		std::string tcpIdle;
		/* --tcp-max-auth-attempts：口令连续失败上限（原写死 kTcpAuthMaxFails=5，
		 * 2026-09-22 F-1 参数化）。字符串保留原始输入，校验在 openActionSource 内
		 * 完成（与 tcpPort/tcpIdle 同惯例）；空串 = 用缺省 5。 */
		std::string tcpMaxAuthAttempts;
		/* --tcp-total-timeout：连接总时长预算下限（原写死 tcpTotalBudgetSec 里的
		 * 600，2026-09-22 F-3 参数化）。生效值仍取 max(该下限, idleSec*20)——
		 * 「总预算」本就是「至少这么多，且随 idle 放大」的语义，不是可能比
		 * idle*20 更小的硬上限。空串 = 用缺省 600。 */
		std::string tcpTotalTimeout;
	} tcp;

	/* ---- agent 模式（--agent）----
	 * agent 模式与动作输入源（--tcp / --input / stdin）互斥：前者让智能体
	 * 工具循环成为主流程，后者是「读一段 .mt 就跑完退出」的一次性流程。
	 * 数值型选项沿用 tcpPort/tcpIdle 的惯例保留原始字符串，统一在
	 * agent::buildAgentConfig 内校验（报错文案与退出路径单点）。 */
	struct Agent {
		bool enabled = false;	/* --agent */
		bool agentOptionsUsed = false;	/* 出现过 agent 专属选项（非 agent 场景据此报错） */
		std::string agentTask;		/* --task：非空 = 一次性任务，空 = 交互 REPL */
		/* 安全缺省（2026-09-20 评估 C12 收口）：run_command 涉及任意 shell 执行，
		 * 故**缺省不提供**，且只能由命令行 --agent-shell 开启；配置文件的
		 * allow_shell **只能关不能开**（写 true 直接拒绝加载并指名原因，见
		 * agentmode.cpp 的 buildAgentConfig 第 7 步）
		 * （旧行为是缺省提供 + --agent-no-shell 关闭，安全侧默认值反了）。 */
		bool agentShell = false;	/* --agent-shell：显式开启 run_command */
		/* 热插表（2026-09-23）：apply_sql 工具让模型用结构 SQL 长出新硬件并**立即
		 * 上电**（开 fd、进 deactivate 清理链），与 run_command 同级的一张牌——
		 * 同样缺省不提供、同样只能由命令行 --agent-hot-sql 开启，配置文件的
		 * allow_hot_sql **只能关不能开**。只读的 query_sql 不受此门控。 */
		bool agentHotSql = false;	/* --agent-hot-sql：显式开启 apply_sql */
		/* 回读（2026-09-23，发现 2 的 A 步）：`--read-var <名>`，可重复。
		 * 只有列进来的变量才允许 `read_variables` 读——**命令行独占**，理由同
		 * --agent-shell/--agent-hot-sql：它给模型一条"主动读硬件"的通道，配置文件
		 * 写 read_vars 会被拒绝加载（缺省查找会读 CWD 的 ./mybot.llm.json，
		 * 「这个文件存在」不构成授权）。清单为空 = 不注册该工具（缺省即无此能力）。 */
		std::vector<std::string> readVars;
		std::string llmEndpoint;
		std::string llmModel;
		std::string llmConfig;		/* --llm-config：配置文件路径（缺省自动查找） */
		std::string llmDriver;		/* --llm-driver：协议驱动表名（= modules/<名>.lua） */
		std::string llmVar;		/* --llm-var：承载驱动变量的名字 */
		std::string llmMaxTurns;
		std::string llmMaxTokens;
		std::string llmTimeout;
		/* --llm-task-timeout：单个任务的墙钟预算（秒，A4）。与 llmTimeout 不同维度：
		 * 那条管一次模型调用，这条管"一个任务能让硬件带电多久"。0 = 不限。
		 * 同 llmTimeout 一样只存原始串，校验在 buildAgentConfig（配置错误不碰真机）。 */
		std::string llmTaskTimeout;
		std::string scriptsDir;
		/* --prompt-file：提示词包输入，可重复（每项为文件或目录）。加载与拼接
		 * 在 agent::buildAgentConfig 完成（配置错误不碰真机），本结构只收集。 */
		std::vector<std::string> promptFiles;
		/* ---- 摄像头（capture_image） ---- */
		std::string cameraVar;		/* --camera-var：承载 modules/Camera.lua 的变量名 */
		std::string cameraDevice;	/* --camera-device：重设设备路径 */
		std::string cameraSrc;		/* --camera-src：模拟图片来源文件 */
		/* --camera-src-dir：capture_image 模拟图片的**白名单根目录**（H1）。
		 * 命令行独占：它决定"能读哪个目录"，等价于放宽读权限，故配置文件不能给
		 * （写了直接拒绝加载，与 --agent-shell 同判据）。不给时：命令行的 --camera-src
		 * 用其所在目录当根，配置文件来源的 camera_src 则不推导（驱动侧默认拒绝）。 */
		std::string cameraSrcDir;
		bool noCamera = false;		/* --no-camera：不提供拍照工具 */
		/* --fs-root <目录>：list_dir / read_file 的**只读根目录**（Phase 4，2026-10-07）。
		 * 命令行独占：它决定"能读哪个目录"，等价于放宽读权限，判据与 --camera-src-dir /
		 * --read-var 同族——配置文件写 fs_root 会被拒绝加载。空 = 不注册这两个工具
		 * （安全缺省）。是否可用（canonical 存在且是目录）在 buildAgentConfig 于上电前
		 * 校验（配置错误不碰真机）。 */
		std::string fsRoot;
		/* --agent-write-file（Phase 5，2026-10-08）：显式开启 write_file 工具
		 * （在 --fs-root 根之内创建/覆盖文本文件）。**独立于 --fs-root**：
		 * 开了读根不等于给了写权，写权限必须再显式开一道（写能覆盖/改写，
		 * 危险性与 run_command / apply_sql 同级）。依赖 --fs-root 非空——
		 * 给了本开关却没给 --fs-root 是配置错误（buildAgentConfig 上电前拒绝）。
		 * 配置文件写 allow_write_file 会被拒绝加载（同 allow_shell 判据）。 */
		bool agentWriteFile = false;	/* --agent-write-file：显式开启 write_file */
		/* --audit-log：审计轨迹落点（JSON Lines 追加；"-" = stderr）。
		 * 缺省空 = 不记录（保持既有语义）。打开失败的报错与退出在
		 * agent::buildAgentConfig（配置错误不碰真机）。 */
		std::string auditLog;
		/* --agent-policy：策略钩子文件（严格 JSON；空 = 不启用，全部放行）。
		 * 加载与校验失败在 agent::buildAgentConfig 报错退出（配置错误不碰真机）。 */
		std::string agentPolicy;
		/* --session-file：会话持久化文件（JSON Lines 追加写，批次 1）。写入是
		 * 纯输出（配置文件的 session_file 字段亦可给）；**恢复是输入通道**，
		 * --resume 只认命令行给出的路径（判据与理由见 AgentModeConfig 注释）。 */
		std::string sessionFile;
		/* --resume：与 --session-file 联用，恢复既有会话后继续。布尔 flag，
		 * 与 --agent 同在表外显式解析（cliargs）。 */
		bool resume = false;
		/* --check-config（PL-1，2026-09-22）：只校验配置并打印摘要，不装载结构脚本、
		 * 不上电、不联网。配置校验本身仍由 buildAgentConfig 单点负责（这里不另起
		 * 一套判据），故 main 里只是「打印摘要后 return 0」一个分支。属 agent 专属
		 * 选项：置 agentOptionsUsed，非 agent 模式由既有逻辑拒绝；未配 --robot 同样
		 * 被「agent 模式需要 --robot」那条拒绝（不会静默打印帮助退出 0）。 */
		bool checkConfig = false;
	} agent;

	/* ---- MCP 后端模式（--mcp-backend，方案 F / 拓扑 F3）----
	 * 一个**独立模式**：把 agent 工具层经本地 AF_UNIX socket 暴露给 Rust MCP
	 * sidecar（sidecar 对上说 MCP over stdio，对下说 pymsg 兼容帧）。它不跑
	 * agent loop、不发起任何模型调用——每次工具调用都由外部 MCP 客户端驱动，
	 * 后端只负责「策略确认 → 执行 → 审计」这条既有漏斗（DispatchGate::run）。
	 *
	 * 与 --agent / --tcp / --input 互斥（它自己就是主流程，不争 stdin、不争
	 * 主线程——同步服务阻塞主线程正是正确行为，见 .tmp 评估 §2.3）。它**复用**
	 * agent 的工具上下文选项（--agent-shell / --agent-hot-sql / --read-var /
	 * --camera-* / --scripts-dir / --agent-policy / --audit-log），因为这些正是
	 * 「对外宣告哪些能力」的门控；但不需要任何 --llm-* / --task（无模型调用）。
	 *
	 * mcpSocket 沿用「路径存原始串、校验单点」惯例（同 tcpPort）：必填、长度
	 * 受 sockaddr_un.sun_path 限制、父目录 0700、socket 文件 0600，对端经
	 * SO_PEERCRED 校验 uid/gid（内核级，不可伪造）。 */
	struct Mcp {
		bool enabled = false;	/* --mcp-backend */
		std::string mcpSocket;
		/* 每连接预算（评估 §3.2「预算再强制」）：后端**不得假设调用方是 agent loop**，
		 * 故自己再强制一层跑飞护栏——超过则拒绝派发（被拒调用无副作用）。
		 * 沿 tcpPort 惯例存原始串、校验单点（cliargs）；0/空 = 不限。
		 * 注意：**单次**物理调用的 scriptTimeoutSec / commandTimeoutSec 始终在工具层
		 * 生效，与这两个「整连接总量」护栏是不同维度。 */
		std::string mcpCallBudget;	/* --mcp-call-budget：每连接工具调用上限 */
		std::string mcpWallClock;	/* --mcp-wall-clock：每连接墙钟预算（秒） */
		/* --mcp-idle-timeout（A-2，2026-09-25 审计）：每连接**空闲**（无帧）超时。
		 * 缺省不限（长生命周期控制通道）；显式给值让「连上后一声不吭」的哑对端
		 * 按时让出单连接串行模型下唯一的 accept 槽。墙钟预算同样在空闲期收口。 */
		std::string mcpIdleTimeout;
		/* --on-disconnect（2026-09-25）：连接结束（任何原因）后由后端自行执行的
		 * 安全动作脚本（scripts-dir 之下的相对路径，如 zero.mt）。此前 agent 进程
		 * 崩溃/被杀/断网时硬件保持**最后一个姿态**带电常驻，直到操作者手动干预
		 * （docs/agent.md 已知限制）。命令行独占：它决定"断连后硬件做什么"，
		 * 与 --agent-shell 同判据，配置文件不能给。空 = 不执行（旧行为）。 */
		std::string onDisconnect;
	} mcp;
};

/* 脚本输入的字节上限四件套（kMaxScriptBytes / ScriptTooLarge / readAllLimited /
 * LimitedReader）已迁 scriptlimit.hpp，经上面的包含仍在 bot:: 下同名可见。 */

/* 以 EOF(-1) 表示输入结束的字符流 */
class FileReader : public Reader {
	std::FILE* file_;

public:
	explicit FileReader(const std::string& path) : file_(std::fopen(path.c_str(), "rb")) {}
	~FileReader() override { if (file_) { std::fclose(file_); } }

	/* 持 FILE* 句柄：拷贝会造成双重 fclose（F-25） */
	FileReader(const FileReader&) = delete;
	FileReader& operator=(const FileReader&) = delete;

	bool good() const { return file_ != nullptr; }

	int read() override {
		if (!file_) { return -1; }
		int c = std::fgetc(file_);
		/* R3：区分 EOF 与读错误——磁盘 I/O 错误静默当作脚本结束会截断动作 */
		if (c == EOF && std::ferror(file_)) {
			std::cerr << "警告：动作脚本读取发生 I/O 错误，按 EOF 处理（脚本可能被截断）" << std::endl;
		}
		return c;
	}
};

/* 已连接 TCP 客户端（内部 64KiB 缓冲，一次 recv 填满后逐字节出队，审计 M2；
 * EOF=0/错误=-1）
 * 空闲超时：对端连上后不再发字节时不能永久挂死进程（秒级由调用方给定）。
 * 总时长预算（C-M2）：空闲超时按「每字节」重置——慢滴对端每 <idle 秒发
 * 1 字节即可无限期挂住进程。从连接建立时刻起算 wall-clock 上限，超限按
 * 输入结束处理（脚本按截断语义走后续报错路径）。 */
class TcpStreamReader : public Reader {
	int fd_;
	int idleSec_;
	std::chrono::steady_clock::time_point deadline_;
	bool timedOut_ = false;
	bool overBudget_ = false;
	std::string buf_;
	std::size_t pos_ = 0;
	static constexpr std::size_t kBufCap = 64u << 10;

public:
	explicit TcpStreamReader(int fd, int idleSec,
			std::chrono::steady_clock::time_point deadline)
		: fd_(fd), idleSec_(idleSec), deadline_(deadline) {}
	~TcpStreamReader() override { if (fd_ >= 0) { ::close(fd_); } }

	/* 持 socket fd：拷贝会造成双重 close（F-25） */
	TcpStreamReader(const TcpStreamReader&) = delete;
	TcpStreamReader& operator=(const TcpStreamReader&) = delete;

	int read() override;
};

/* ---- TCP 口令校验三态（2026-09-20 重构阶段 4.3）----
 * 必须区分「对端给了凭据但不匹配」与「对端什么都没给」：
 *   Ok           口令正确
 *   Rejected     收到凭据行但内容不匹配 / 超长 —— 计入爆破计数
 *   NoCredential 未收到凭据行（空闲超时 EAGAIN、EOF、EINTR）—— **不得**计为鉴权失败，
 *                否则任意未认证对端连上不发字节、重复 5 次即可终止进程
 *                （旧实现把 EAGAIN 与不匹配混为一谈，且误报「连续 5 次校验失败」）。
 * 暴露为公开函数便于白盒单测（与 ActionRunner::resolveActionDevice 同惯例）。 */
enum class TcpAuthStatus { Ok, Rejected, NoCredential };

TcpAuthStatus checkTcpToken(int client, const std::string& token);

/* 打开动作输入源：tcp 优先 > 文件 > 标准输入（MemoryReader 整读）。
 * 返回的读取器一律带字节上限；TCP 通道另含绑定地址、空闲超时与可选口令。 */
std::unique_ptr<Reader> openActionSource(const CliOptions& options);

} // namespace bot
