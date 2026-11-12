/* cliargs_help.cpp —— --help 帮助文本（拆自 cliargs.cpp，2026-10-01 TU 拆分）
 * 全文帮助 + 五个分段主题（tcp/agent/llm/camera/mcp）+ 分发与 printHelp。
 * 文案是被 C++ 单测字节级锚定、并与 docs/reference.md 黄金比对的对象——
 * 独立成数据性 TU，改文案只需看这一个文件。区间常量经 rangeText 与
 * util_cli.hpp 的 tcp_limits/daemon_limits 同源（帮助与校验不漂移）。 */

#include "cliargs.hpp"

#include <iostream>
#include <string>

#include "util_cli.hpp"
#include "util_str.hpp"		/* toLowerAscii / trim */

namespace bot {

namespace {

/* 选项区间文本单点渲染（B2-4）：--help、校验共用同一组界，避免「帮助里写
 * 一个数、校验用另一个数」这类漂移。（llm_limits 的引用随 LLM 选项面迁
 * mybot-agent 一并移除；tcp_limits/daemon_limits 仍在此使用。） */
std::string rangeText(int lo, int hi) {
	return "范围 " + std::to_string(lo) + "-" + std::to_string(hi);
}

/* 上限文案（--mcp-wall-clock / --mcp-idle-timeout）：与 rangeText 同理，数取自
 * util_cli.hpp 的 mcp_limits，与 cliargs.cpp 的校验同源。措辞是「上限 N」而不是
 * rangeText 的「范围 0-N」——0 在这两个选项里的语义是「不限」而非「下界」，写成
 * 范围会读成「必须给一个 0 到 N 的值」。文本逐字沿用收单点之前的帮助原文：
 * docs/reference.md 的选项表用的是同一个措辞，而现有守门只比对选项**名集合**
 * （cliargs_help_option_set_matches_docs），不比对文案，改字不会红——所以这里
 * 不自作主张顺手统一。 */
std::string capText(int hi) {
	return "上限 " + std::to_string(hi);
}

/* ---- 全文帮助与主题帮助逐字共用的条目首行（2026-10-06 25.3 收单点）----
 * 五个选项的**首行**此前在两处各手抄一份（--mcp-call-budget / --mcp-wall-clock /
 * --mcp-idle-timeout 见全文帮助与 --help mcp，--camera-device / --no-camera 见
 * 全文帮助与 --help camera），字节相同。没有任何守门比对这两个帮助面：
 * cliargs_help_option_set_matches_docs 只取 bot::helpText()，主题帮助不在它的
 * 取材面里，于是抄漏一边不会红，只会让 --help 与 --help mcp 对同一个选项各说
 * 各话（其中两条还带着 mcp_limits 的上限——那就是「帮助写一个数、校验用另一个
 * 数」的第三种抄法）。手法同 tcpOptionsHelp（2026-09-25 D3），只是这里两处
 * 首行**不相邻**（各自后面跟着措辞不同的缩进续行：主题帮助是精简版），故一行
 * 一个函数而不是抽成整块。续行不在单点范围内——它们本就是有意不同的两份文案。 */
std::string mcpCallBudgetLine() {
	return "  --mcp-call-budget <N>   每连接工具调用上限（跑飞护栏；0/空 = 不限，缺省不限）。\n";
}
std::string mcpWallClockLine() {
	return "  --mcp-wall-clock <秒>   每连接墙钟预算（0/空 = 不限，缺省不限；"
		+ capText(mcp_limits::kBudgetSecMax) + "）。\n";
}
std::string mcpIdleTimeoutLine() {
	return "  --mcp-idle-timeout <秒> 每连接空闲（无帧）超时（0/空 = 不限，缺省不限；"
		+ capText(mcp_limits::kBudgetSecMax) + "）。\n";
}
/* 缺省设备 /dev/video0 的权威出处在 modules/Camera.lua:161 的 DEFAULT_DEVICE，
 * 跨构建取不到（本仓禁「构建期代码生成」），故这里的字面值是有意的手抄，
 * 与 src/agentmode.cpp:72 的 --check-config 摘要同源同性质，不在本次收单点范围。 */
std::string cameraDeviceLine() {
	return "  --camera-device <路径> 摄像头设备（缺省 /dev/video0；需支持 MJPEG）\n";
}
std::string noCameraLine() {
	return "  --no-camera           不向智能体提供 capture_image 工具\n";
}

} // namespace

/* TCP 选项块（全文帮助与 --help tcp 共用单点，2026-09-25 D3）：两处此前逐行
 * 手抄同一份，区间常量（rangeText）改一处漏一处只会让 --help 与
 * docs/reference.md 的黄金比对红一条而不知因——组装成函数后文本只有一份。 */
std::string tcpOptionsHelp() {
	std::string s;
	s += "  --tcp <port>       TCP 模式：监听端口接受一次成功连接，读取对端下发的 .mt\n";
	s += "                     （EOF 或 --tcp-idle 超时按输入结束处理，非流式长驻）\n";
	s += "  --tcp-host <addr>  TCP 监听地址，缺省 127.0.0.1；跨机监听（如 0.0.0.0）\n";
	s += "                     必须同时提供 --tcp-token，否则拒绝启动\n";
	s += "  --tcp-token <tok>  TCP 口令：跨机监听必填；对端须先发一行 \"<tok>\\n\" 再发脚本；\n";
	s += "                     校验失败关连接回等，连续 5 次才退出；也可用环境变量 BOT4CJ_TCP_TOKEN\n";
	s += "  --tcp-idle <sec>   TCP 空闲超时，缺省 30s（超时按输入结束处理）；\n";
	s += "                     另有连接总时长预算（600s，随该值 x20 放大）防慢滴挂住进程\n";
	s += "  --tcp-max-auth-attempts <N>  口令连续失败上限（缺省 5，"
		+ rangeText(tcp_limits::kAuthMaxFailsMin, tcp_limits::kAuthMaxFailsMax) + "）\n";
	s += "  --tcp-total-timeout <sec>    连接总时长预算下限（缺省 600，"
		+ rangeText(tcp_limits::kTotalTimeoutMin, tcp_limits::kTotalTimeoutMax)
		+ "）；生效值取该下限与 idle x20 的较大者\n";
	return s;
}

/* 25.4 评估后判不改（100 行）：本函数是**文本表**不是控制流——通篇 s += "…"，
 * 零分支。真正可复用的那一段（TCP 选项块）2026-09-25 D3 已经抽成
 * tcpOptionsHelp，五条跨帮助面逐字相同的首行 25.3 也已收成单点；剩下的按主题
 * 再切只会把一份连续的帮助正文拆成要按顺序拼回来的碎片，而它是
 * cliargs_help_text_covers_key_sections 与 cliargs_help_option_set_matches_docs
 * 两条黄金用例的锚定对象，切碎无收益、有漂移面。 */
std::string helpText() {
	std::string s;
	s += "这是一个机器人动作脚本解析器。\n";
	s += "使用--robot选项指定结构脚本，然后使用管道输入动作脚本，示例：\n";
	s += "  cat scripts/std.mt | ./build/mybot --robot=./robots/spider1.sql\n";
	s += "\n";
	s += "动作输入源（优先级从高到低）：\n";
	s += tcpOptionsHelp();
	s += "  --input <path>     从文件读取动作脚本\n";
	s += "  （缺省）           从 stdin 管道读取\n";
	s += "  --webshell-port <port>   Web SSH 终端服务（#24）：浏览器 xterm.js →\n";
	s += "                     WebSocket(/ws/term) → forkpty 交互 shell。独立于上述输入源，\n";
	s += "                     给端口即启用；GET / 提供单页前端。缺省监听 127.0.0.1\n";
	s += "  --webshell-host <addr>  Web SSH 监听地址（缺省 127.0.0.1）；跨机监听必须\n";
	s += "                     同时提供 --webshell-token，否则拒绝启动\n";
	s += "  --webshell-token <tok>  Web SSH 口令：客户端以 ?token=<tok> 附在连接 URL 上；\n";
	s += "                     非回环监听必填\n";
	s += "  --daemon-grace-ms <ms>  守护线程弃管后的二段停机宽限上限（缺省 30000，"
		+ rangeText(daemon_limits::kGraceMsMin, daemon_limits::kGraceMsMax)
		+ "）；仅结构脚本含 @Daemon 时生效，与 --tcp/--input 等输入模式无关\n";
	s += "\n";
	s += "agent 体系（模型循环已迁 Rust：agent/target/release/mybot-agent）：\n";
	s += "本程序在 agent 体系里的职责是**工具后端**（--mcp-backend）：机器人结构脚本\n";
	s += "加载后硬件常驻内存，工具调用经 AF_UNIX socket 服务；LLM 循环（REPL/--task/\n";
	s += "预算/历史裁剪）由 mybot-agent 承担，它直连 provider、经 --socket 调用本程序。\n";
	s += "模型侧参数（--task/--llm-*/--prompt-file/--session-file/--resume）是\n";
	s += "mybot-agent 自己的选项——本程序会显式拒绝并指引；见 mybot-agent --help\n";
	s += "与 docs/agent.md。\n";
	s += "  --mcp-backend       把 agent 工具层经本地 AF_UNIX socket 暴露给 mybot-agent。\n";
	s += "                      独立模式：不跑模型循环、不发起任何模型调用——每次工具\n";
	s += "                      调用都走既有的「策略确认 → 执行 → 审计」漏斗。与\n";
	s += "                      --tcp/--input 互斥；需要 --robot 与 --mcp-socket\n";
	s += "  --mcp-socket <路径>  AF_UNIX socket 路径（mybot-agent 的 --socket 连这里）。\n";
	s += "                      父目录建议 0700、socket 文件 0600；对端经内核\n";
	s += "                      SO_PEERCRED 校验 uid/gid（不可伪造）\n";
	s += mcpCallBudgetLine();
	s += "                      后端不假设调用方是谁，故自行再强制一层预算\n";
	s += mcpWallClockLine();
	s += "                      注：单次物理调用的 script/command 超时始终在工具层生效\n";
	s += mcpIdleTimeoutLine();
	s += "                      让「连上后一声不吭」的哑连接按时让出唯一的 accept 槽\n";
	s += "  --on-disconnect <脚本>  连接结束（对端关闭/崩溃/超时/协议违规，任何原因）后，\n";
	s += "                      后端自行执行的安全动作脚本（scripts-dir 之下的相对路径，\n";
	s += "                      如 zero.mt）。缺省不执行——此时硬件停在最后一个姿态带电\n";
	s += "                      常驻。脚本在上电前校验（越界/不存在/为空即退出 2）；\n";
	s += "                      不经策略确认（操作者配置的安全动作不该等外部闸门）；\n";
	s += "                      执行失败只记日志/审计，后端继续服务。SIGINT/SIGTERM 停机\n";
	s += "                      不触发（由断电清理链处理）\n";
	s += "  --scripts-dir <目录>  动作脚本根目录（缺省 scripts）；智能体只能执行其下的 .mt\n";
	s += "  --agent-shell         允许智能体执行 shell 命令（注册 run_command 工具）；\n";
	s += "                       **缺省不提供**该工具（任意 shell 执行是最大的一张牌，\n";
	s += "                       要用就显式开启；理由与缓解见 docs/agent.md 安全一节）。\n";
	s += "                       --mcp-backend 下开它**强制**要 --agent-policy 且其\n";
	s += "                       require_confirm 包含 run_command（无人值守暴露危险能力\n";
	s += "                       必须有外部确认闸门）\n";
	s += "  --agent-hot-sql       允许智能体用结构 SQL 改硬件（注册 apply_sql 工具）：\n";
	s += "                       CREATE TABLE / INSERT INTO 会**立即装配并上电**（开 fd、\n";
	s += "                       进断电清理链），失败整批回滚；DELETE 当场断电摘除、\n";
	s += "                       **不可逆**。**缺省不提供**，配置文件的 allow_hot_sql\n";
	s += "                       只能关不能开（只读的 query_sql 不受影响）；--mcp-backend\n";
	s += "                       下开它同样强制策略确认（apply_sql）\n";
	s += "  --read-var <变量名>    声明一个**可读**硬件变量（可重复；注册 read_variables 与\n";
	s += "                       wait_variable 工具，让智能体主动读器件当前值、或轮询等\n";
	s += "                       某个读数满足条件）。**缺省不提供**这两个工具：\n";
	s += "                       只有列进来的变量可读——执行器（Servo/Relay 等）也是 Lua\n";
	s += "                       驱动，靠种类分不出传感器与执行器，故由操作者显式声明；\n";
	s += "                       配置文件写 read_vars 会被拒绝加载（与 --agent-shell 同判据）\n";
	s += "  --fs-root <目录>      list_dir / read_file 的只读根目录（可读机器人主机上的\n";
	s += "                       普通文件，与硬件/shell 无关）。**缺省不提供**这两个工具；\n";
	s += "                       配置文件写 fs_root 会被拒绝加载（与 --read-var 同判据）\n";
	s += "  --agent-write-file    显式开启 write_file（在 --fs-root 根之内创建/覆盖文本文件，\n";
	s += "                       原子写入；目标已存在须显式 overwrite=true 才覆盖，覆盖\n";
	s += "                       不可逆）。**依赖 --fs-root**（没给会在上电前报错）；\n";
	s += "                       危险性与 run_command/apply_sql 同级：--mcp-backend 下开它\n";
	s += "                       **强制**要 --agent-policy 且 require_confirm 含 write_file；\n";
	s += "                       配置文件的 allow_write_file 只能关不能开\n";
	s += "  --agent-policy <路径> 策略钩子（严格 JSON）：声明哪些工具的每次调用要先过\n";
	s += "                       外部确认程序（stdin 收工具名与遮蔽后的参数 JSON，\n";
	s += "                       退出 0 = 放行）；超时按 on_timeout（缺省 deny）处理；\n";
	s += "                       缺省不启用。也可用配置文件 agent_policy 字段\n";
	s += "  --camera-var <变量名> 承载摄像头驱动的变量名（缺省 cam0）；结构脚本已声明则直接用\n";
	s += cameraDeviceLine();
	s += "  --camera-src <图片>   模拟图片来源：不接摄像头也能跑通「拍照→进上下文」。\n";
	s += "                       命令行给的 src 以其**所在目录**为白名单根；配置文件里的\n";
	s += "                       camera_src 不推导根（防止一份落地配置把任意文件读进上下文），\n";
	s += "                       需配 --camera-src-dir 或 BOT4CJ_CAMERA_SRC_DIR，否则驱动默认拒绝\n";
	s += "  --camera-src-dir <目录> capture_image 模拟图片的白名单根目录（**只能命令行给**：\n";
	s += "                       它放宽读权限，配置文件写 camera_src_dir 会被拒绝加载）\n";
	s += noCameraLine();
	s += "  --check-config        只校验配置并打印摘要后退出 0（与 --mcp-backend 联用）：\n";
	s += "                       不装载结构脚本、不上电、不发起任何网络请求（配置文件\n";
	s += "                       拼错时无需真起后端）。会**打开但不写入**审计日志文件。\n";
	s += "                       agent 侧的配置校验用 mybot-agent --check-config\n";
	s += "  --audit-log <路径>    审计轨迹（JSON Lines 追加写）：每次工具调用一条记录\n";
	s += "                       （时间戳/轮次/工具/参数/成败/耗时）；图片只记体积与指纹，\n";
	s += "                       命令原文里的 KEY=VALUE 敏感值先遮蔽；\"-\" 表示写 stderr；\n";
	s += "                       缺省不记录。也可用配置文件 audit_log 字段\n";
	s += "\n";
	s += "示例：\n";
	s += "  # 终端 1：工具后端（硬件上电常驻）\n";
	s += "  ./build/mybot --robot=robots/relay-test.sql --mcp-backend --mcp-socket /tmp/mybot.sock\n";
	s += "  # 终端 2：agent（REPL / --task；密钥经环境变量给）\n";
	s += "  ./agent/target/release/mybot-agent --socket /tmp/mybot.sock\n";
	s += "\n";
	s += "安全约束：动作脚本只能引入新的参数键，不得覆盖结构脚本的元数据列\n";
	s += "（fd / address / max / min / offset 等）与触发器引用名（trigger 列）；\n";
	s += "结构脚本与动作脚本单次输入上限均为 8 MiB。\n";
	s += "\n";
	s += "分段帮助（2026-09-22 新增）：\n";
	s += "  --help tcp     - 只显示 TCP 模式相关选项\n";
	s += "  --help agent   - 只显示 agent 体系（--mcp-backend + mybot-agent）相关选项\n";
	s += "  --help llm     - LLM/模型配置已迁 mybot-agent（指路）\n";
	s += "  --help camera  - 只显示摄像头相关选项\n";
	s += "  --help mcp     - 只显示 MCP 后端模式（--mcp-backend）相关选项\n";
	return s;
}

namespace {

/* ---- 分段帮助的每主题文本（2026-09-29 A3 拆自 helpText(topic) 的 if-else
 * 链）：五个主题各成函数，文本逐字保持。 */
std::string topicTcpHelp() {
	std::string s;
	s += "TCP 模式（动作输入源）：\n\n";
	s += tcpOptionsHelp();
	s += "\n示例：\n";
	s += "  ./build/mybot --robot=robots/spider1.sql --tcp 8080\n";
	s += "  ./build/mybot --robot=robots/spider1.sql --tcp 8080 --tcp-host 0.0.0.0 --tcp-token mysecret\n";
	return s;
}

std::string topicAgentHelp() {
	std::string s;
	s += "agent 体系（模型循环已迁 Rust mybot-agent）：\n\n";
	s += "拓扑：mybot --mcp-backend 提供工具后端（硬件上电常驻，经 AF_UNIX\n";
	s += "socket 服务工具调用）；mybot-agent 跑模型循环（REPL/--task/预算/历史\n";
	s += "裁剪），直连 provider，经 --socket 调用后端。构建 agent：\n";
	s += "bash scripts/build_agent.sh；其选项见 mybot-agent --help 与 docs/agent.md。\n\n";
	s += "本程序的 agent 面选项（都在 --mcp-backend 下有效）：\n";
	s += "  --agent-shell         显式开启 run_command（任意 shell 执行）；后端下开它\n";
	s += "                       强制要 --agent-policy 且 require_confirm 含 run_command\n";
	s += "  --agent-hot-sql       显式开启 apply_sql（结构 SQL 带电生效）；后端下开它\n";
	s += "                       强制要策略确认（apply_sql）。配置文件不能开\n";
	s += "  --read-var <变量名>    声明可读硬件变量（可重复；注册 read_variables 与\n";
	s += "                       wait_variable 工具）。\n";
	s += "                       缺省不提供；配置文件不能给\n";
	s += "  --fs-root <目录>      list_dir / read_file 的只读根目录（主机文件，与硬件\n";
	s += "                       无关）。缺省不提供；配置文件不能给\n";
	s += "  --agent-write-file    显式开启 write_file（在 --fs-root 根内创建/覆盖文本文件）；\n";
	s += "                       依赖 --fs-root；后端下开它强制策略确认（write_file）。\n";
	s += "                       配置文件不能开\n";
	s += "  --agent-policy <路径> 策略钩子：命中 require_confirm 的工具调用先过外部\n";
	s += "                       确认程序（退出 0 = 放行；超时按 on_timeout，缺省 deny）\n";
	s += "  --scripts-dir <目录>  动作脚本根目录（run_action_script 的沙箱边界）\n";
	s += "  --camera-* / --no-camera  摄像头（见 --help camera）\n";
	s += "  --audit-log <路径>    审计轨迹（JSON Lines；\"-\"=stderr；缺省不记录）\n";
	s += "  --check-config        只校验配置并打印摘要后退出 0（离线，不碰硬件）\n\n";
	s += "示例：\n";
	s += "  ./build/mybot --robot=robots/relay-test.sql --mcp-backend \\\n";
	s += "      --mcp-socket /tmp/mybot.sock --agent-shell --agent-policy policy.json\n";
	s += "  ./agent/target/release/mybot-agent --socket /tmp/mybot.sock\n";
	return s;
}

std::string topicLlmHelp() {
	std::string s;
	s += "LLM/模型配置（已迁 Rust mybot-agent）：\n\n";
	s += "模型接入点、密钥、采样与循环参数（--llm-endpoint / --llm-model /\n";
	s += "--llm-config / --llm-timeout 等、--task、--prompt-file、--session-file、\n";
	s += "--resume）都是 mybot-agent 的选项——本程序会显式拒绝并指引。\n\n";
	s += "  mybot-agent --help\n";
	s += "  ./agent/target/release/mybot-agent --socket /tmp/mybot.sock --llm-model gpt-4\n\n";
	s += "环境变量 BOT4CJ_LLM_KEY（兼容 ROBOT_AGENT_API_KEY / DEEPSEEK_API_KEY）\n";
	s += "由 mybot-agent 进程读取（优先级：命令行 > 环境变量 > 配置文件 > 内置缺省）。\n";
	s += "详见 docs/agent.md。\n";
	return s;
}

std::string topicCameraHelp() {
	std::string s;
	s += "摄像头配置选项（--mcp-backend 下有效）：\n\n";
	s += "  --camera-var <变量名> 承载摄像头驱动的变量名（缺省 cam0）\n";
	s += cameraDeviceLine();
	s += "  --camera-src <图片>   模拟图片来源：不接摄像头也能跑通「拍照→进上下文」\n";
	s += "  --camera-src-dir <目录> 模拟图片白名单根目录（只能命令行给）\n";
	s += noCameraLine();
	s += "  --check-config        只校验配置并打印摘要后退出 0（不装结构、不上电、不联网）\n";
	s += "  --audit-log <路径>    审计轨迹（JSON Lines 追加写；\"-\"=stderr；缺省不记录）\n";
	s += "                        也可用配置文件 audit_log 字段\n\n";
	s += "示例：\n";
	s += "  ./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/s.sock \\\n";
	s += "      --camera-device /dev/video1\n";
	return s;
}

std::string topicMcpHelp() {
	std::string s;
	s += "MCP 后端模式（--mcp-backend）：\n\n";
	s += "  --mcp-backend       把 agent 工具层经本地 AF_UNIX socket 暴露给 Rust agent\n";
	s += "                      （mybot-agent，经 --socket 连接；它对上跑 REPL/--task，\n";
	s += "                      对下经帧协议调用这里的工具）。独立模式：不跑模型循环、\n";
	s += "                      不发起任何模型调用——每次工具调用都走既有的\n";
	s += "                      「策略确认 → 执行 → 审计」漏斗（DispatchGate::run）。\n";
	s += "                      与 --tcp / --input 互斥；需要 --robot 与 --mcp-socket。\n";
	s += "  --mcp-socket <路径>  AF_UNIX socket 路径（必填）。父目录建议 0700、socket 文件\n";
	s += "                      0600；对端经内核 SO_PEERCRED 校验 uid/gid（不可伪造）。\n";
	s += mcpCallBudgetLine();
	s += "                      后端不假设调用方是 agent 循环，故自行再强制一层预算。\n";
	s += mcpWallClockLine();
	s += "                      注：单次物理调用的 script/command 超时始终在工具层生效。\n";
	s += mcpIdleTimeoutLine();
	s += "                      让「连上后一声不吭」的哑连接按时让出唯一的 accept 槽；\n";
	s += "                      墙钟预算同样在空闲期收口（到点断连，对端可重连）。\n";
	s += "  --on-disconnect <脚本>  连接结束（任何原因）后由后端自行执行的安全动作脚本\n";
	s += "                      （scripts-dir 之下的相对路径，如 zero.mt）。缺省不执行，\n";
	s += "                      硬件停在最后一个姿态。上电前校验；不经策略确认；失败\n";
	s += "                      只记日志/审计（kind=session, status=disconnect_action）。\n";
	s += "                      SIGINT/SIGTERM 停机不触发（走断电清理链）。\n\n";
	s += "安全：后端开 --agent-shell / --agent-hot-sql / --agent-write-file 时**强制**要\n";
	s += "      --agent-policy，且其 require_confirm 必须分别包含 run_command /\n";
	s += "      apply_sql / write_file（无人值守暴露危险能力必须有外部确认闸门）；\n";
	s += "      纯只读/查询/动作脚本后端不受此约束。\n\n";
	s += "复用 agent 的工具上下文/能力门控选项（决定对外宣告哪些工具）：\n";
	s += "  --agent-shell / --agent-hot-sql / --agent-write-file / --read-var / --fs-root /\n";
	s += "  --camera-* / --no-camera / --scripts-dir / --agent-policy / --audit-log\n";
	s += "（--task / --llm-* / --prompt-file / --session-file / --resume 属于 mybot-agent）\n\n";
	s += "示例：\n";
	s += "  ./build/mybot --robot=robots/relay-test.sql --mcp-backend \\\n";
	s += "      --mcp-socket /run/user/1000/bot4cj/mcp.sock --audit-log -\n";
	return s;
}

} // namespace


/* 分段帮助文本（2026-09-22 可用性改进）：支持快速查看特定主题。
 * 每主题文本在上方具名函数（2026-09-29 A3 拆分），这里只留分发。 */
std::string helpText(const std::string& topic) {
	if (topic.empty()) { return helpText(); }
	const std::string t = toLowerAscii(trim(topic));

	if (t == "tcp") { return topicTcpHelp(); }
	if (t == "agent") { return topicAgentHelp(); }
	if (t == "llm") { return topicLlmHelp(); }
	if (t == "camera") { return topicCameraHelp(); }
	if (t == "mcp") { return topicMcpHelp(); }
	std::string s;
	s += "未知主题: " + topic + "\n\n";
	s += "支持的主题：tcp, agent, llm, camera, mcp\n";
	s += "使用 --help 查看完整帮助\n";
	return s;
}

void printHelp() {
	std::cout << helpText();
}

void printHelp(const std::string& topic) {
	std::cout << helpText(topic);
}

} // namespace bot
