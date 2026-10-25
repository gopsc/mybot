#pragma once
/* mcptransport.hpp —— MCP 后端的帧传输与纯协议件
 *
 * 2026-10-01 自 mcpbackend.hpp 析出（行为保持，随 mcptransport.cpp 的 TU 拆分
 * 对齐声明归属）：帧常量与编解码、deadline 收发、SO_PEERCRED、socket 路径
 * 占用探测（A-1）、首帧共享密钥三态（MCP-1）、回执脱敏。消费者：mcplisten.cpp
 * （serveConnection/acceptLoop）、mcpbackend.cpp（sanitizeError/认证接线）与
 * 白盒单测 test_mcptransport.cpp。
 */

#include <chrono>
#include <cstddef>
#include <ostream>
#include <string>
#include <string_view>

namespace bot {
namespace agent {

/* 运行期日志前缀单点（2026-10-10 收敛）：mcplisten/mcptransport 两 TU 的
 * 24 处日志此前各写一份「MCP 后端：」字面量——前缀漂移会破坏按它 grep 的
 * 运维习惯。读者是后端操作者，中文与运行期报错同区（docs/development.md
 * 的报错语言分区）。 */
inline constexpr std::string_view kMcpLogPrefix = "MCP 后端：";

/* 帧上限：**收紧到 8 MiB**，对齐 bot4cj 自己的 JSON 解析器（jsonparse.hpp 的
 * kJsonMaxBytes）。libmsg 的上限是 64 MiB，但一个 64 MiB 的合法帧会被我们的
 * 解析器以一个离真实成因很远的错误拒掉（评估 §2.3 缺点 4），故在帧层就先收紧。
 * 跨进程契约：Rust 侧 agent/src/frame.rs 的 MAX_FRAME_BYTES 是同一常量的孪生，
 * 改动必须双侧同步（agent_e2e 的越界用例与两侧单测各自锚住己侧；
 * test_mcpbackend 的 mcpbackend_frame_limit_matches_rust_twin 读源比对钉住）。 */
inline constexpr std::size_t kMcpMaxFrameBytes = 8u << 20;

/* 帧头长度：4 字节 big-endian uint32 载荷字节长（与 pymsg/gomsg/libmsg 字节兼容，
 * 无 magic / 无版本 / 无 flags / 无校验和）。 */
inline constexpr std::size_t kMcpHeaderSize = 4;

/* 把载荷封成一帧：4 字节 BE 长度前缀 + 载荷字节。 */
std::string mcpEncodeFrame(const std::string& payload);

/* accept 后校验对端身份：内核 SO_PEERCRED 给出的 uid/gid 必须与本进程一致
 * （不可伪造，评估 §3.1）。匹配返回 true；不匹配或 getsockopt 失败返回 false
 * 并把原因写进 log。暴露为公开函数便于白盒单测（socketpair 造对端），与
 * actionsource.hpp 的 TcpAuthStatus 同惯例。 */
bool mcpCheckPeerCred(int fd, std::ostream& log);

/* ---- 启动前的 socket 路径占用探测（A-1，2026-09-25 审计）----
 * 原实现无条件 ::unlink 已存在的路径：两个 mybot 误配同一条 --mcp-socket 时，
 * 后启动者会静默偷走 socket 文件、先启动者继续监听但永远不可达（双实例静默
 * 劫持）。探测三态：
 *   PathFree    —— 路径不存在，或存在且是**无人监听**的陈旧 socket（可安全
 *                  unlink 后绑定；上一次实例没来得及清理的残留正是这一类）；
 *   PathBusy    —— 路径上已有活着的监听者（connect 即成功，或对端积压满/
 *                  探测超时——fail-closed 一律按「有人在用」拒绝启动）；
 *   PathUnusable —— 路径存在但不是 socket 文件（不能替操作者删掉一个陌生
 *                  文件），或探测自身出错（权限/异常 errno）。
 * why 非空时给人话成因（启动失败的报错文案用）。暴露为公开函数便于白盒单测
 * （临时目录里造 listening/stale/非 socket 三态），与 mcpCheckPeerCred 同惯例。 */
enum class McpSocketProbe { PathFree, PathBusy, PathUnusable };
McpSocketProbe mcpProbeSocketPath(const std::string& path, std::string& why);

/* ---- 首帧共享密钥校验（MCP-1，审计 P2-1，纯协议件可离线单测）----
 * payload 是连接的第一帧载荷。三态：
 *   Ok          —— 是 auth 帧（{"_route":"auth","token":...}）且 token 匹配；
 *   Failed      —— 是 auth 帧但 token 不匹配 / token 字段缺失或非字符串 /
 *                  载荷不是合法 JSON / 顶层不是对象；
 *   NotAuthFrame—— 合法 JSON 对象但 _route 不是 "auth"（旧客户端直接发
 *                  tool.list 之类的首个请求，需要与「密钥错了」区分开报错）。
 * 比对常数时间（长度差异折叠进累计差，不短路）：本地同 UID 攻击者逐字节
 * 测回应时间的侧信道在此威胁模型下不算近路，但常数时间是免费的，做了。 */
enum class McpAuthOutcome { Ok, Failed, NotAuthFrame };
McpAuthOutcome mcpCheckAuthFrame(const std::string& expected, const std::string& payload);

/* ---- 首帧认证回执（MCP-1；mcpCheckAuthFrame 的对偶回帧）----
 * serveConnection 认证判定后的两条固定回帧：通过 → {"success":true,"data":
 * {"auth":true}}（lock-step，Rust 侧 authenticate 在等这一帧）；不通过 →
 * {"success":false,"error":...}——文案单点在此：不回显 token、不区分「错密钥」
 * 与「没带密钥」（信息量最小化）。经 Json + mcp_protocol 常量构造（wire 测试
 * 禁生产 TU 退回裸字面量），字节形态由 test_mcptransport 的字节锚定用例钉住
 * ——回帧是对端 authenticate 的判据，字节漂移（哪怕语义等价）也该显式过一道
 * 测试而非静默发生。 */
std::string mcpAuthOkFrame();
std::string mcpAuthRejectFrame();

/* ---- 帧传输接缝（实现在 mcptransport.cpp，2026-10-01 TU 拆分；
 * serveConnection / acceptLoop 在 mcpbackend.cpp 消费）----
 * readFrame 两段式（空闲等首字节 + 帧开始后共享绝对 deadline 防 Slowloris）
 * 与 sendFrame（写侧共享绝对 deadline + poll(POLLOUT)，与读侧同一条防线）
 * 的完整语义见 mcptransport.cpp 实现处。 */
enum class FrameResult { Ok, PeerClosed, Violation, IdleTimeout };
FrameResult readFrame(int fd, std::string& payload, int recvTimeoutSec,
	std::chrono::steady_clock::time_point idleDeadline, std::ostream& log);
/* 发一帧：帧头与载荷共享 sendTimeoutSec 的绝对 deadline（慢读端不能无限
 * 挂住单线程后端——2026-10-01 批次 A / P1-3，此前靠 acceptLoop 的
 * SO_SNDTIMEO 兜底且 setsockopt 失败只告警）。 */
bool sendFrame(int fd, const std::string& payload, int sendTimeoutSec);

/* 主线程轮询粒度：accept 与逐帧接收共用（200ms = 对停止信号的响应上限，
 * 不是超时——空闲时不断连，靠 deadline 收口）。 */
inline constexpr int kMcpPollIntervalMs = 200;
/* 发送 deadline：慢读端挂住写侧的上限（评估 §7.6 加固清单；2026-10-01 起
 * 由 sendFrame 的 poll+deadline 直接执行，不再经 SO_SNDTIMEO 间接生效）。 */
inline constexpr int kMcpSendTimeoutSec = 5;

/* 错误文案里的路径段遮蔽（'/' 起整段换 <redacted>）：routeToolCall 的回执
 * 防泄路径用；实现随传输件在 mcptransport.cpp。 */
std::string sanitizeError(const std::string& in);

} // namespace agent
} // namespace bot
