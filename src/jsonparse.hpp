#pragma once
/* jsonparse.hpp —— 严格 JSON 文本解析（JSON 文本 → bot::Json）
 *
 * 为什么需要它：本项目原有的 Json 只做「程序构造 + 序列化」（矩阵/元数据内部
 * 流转），从不需要读入外部 JSON 文本。agent 模式要解析模型响应（OpenAI 兼容
 * 协议的 JSON 报文），这是仓库里第一条「外部 JSON 文本入口」，故单列一层。
 *
 * 与 Lua/驱动的边界无关：本层不依赖 LuaJIT，纯值解析，可离线单测。
 *
 * 【替代方案评估（决策记录，#29）】
 * 本层解析的是**模型返回的不可信 JSON**，安全契约是硬约束：
 *   1) 严格语法：控制字符必须转义、尾随内容拒绝、\u 代理对完整校验
 *      （nlohmann/json 默认宽松，需逐项开启并自写差异层）；
 *   2) 资源上限：嵌套深度 64 + 字节上限 8 MiB 拒绝而非截断
 *      （nlohmann 深度检查需 SAX 接口，RapidJSON 需组合配置，报错形态
 *      均与本项目契约不同）；
 *   3) 报错契约：失败抛 IllegalArgumentException 且带偏移，报错文案被
 *      agent 链路当作可读反馈透出，第三方库的英文/格式错误不满足；
 *   4) 溢出语义：整数溢出回落 Float，RapidJSON 默认直接报错。
 * 结论：保持自研。若未来替换，须先为上述四条建立等价回归单测
 * （test_jsonparse.cpp 已锚定），再评估 nlohmann/RapidJSON。
 */

#include <cstddef>
#include <string>

#include "json.hpp"

namespace bot {

/* 解析上限（拒绝而非截断）：
 * - 字节数 8 MiB：与脚本输入上限同量级，模型响应实测为 KB 级；
 * - 嵌套深度 64：递归下降解析深嵌套会吃栈，而模型可被输入诱导吐出
 *   "[[[[..." 之类的深嵌套；上限之下任何合法响应都绰绰有余。
 * 「同量级」不等于「同一个常量」，别与 scriptlimit.hpp 的 kMaxScriptBytes 合并：
 * 本常量经 kMcpMaxFrameBytes 与 agent/src/frame.rs 的 MAX_FRAME_BYTES 钉成跨进程契约
 * （守门见 test_mcptransport.cpp 的 mcpbackend_frame_limit_matches_rust_twin），
 * 那个是纯本地内存护栏——合成一个数会让调整一侧静默改掉另一侧。评估记录见提交
 * fc1c66f（2026-10-04「三项评估收口」）。 */
inline constexpr std::size_t kJsonMaxBytes = 8u << 20;
inline constexpr int kJsonMaxDepth = 64;

/* 解析整串 JSON。
 * 严格语义：必须整体消费（尾部多余非空白字符即报错），不接受注释、
 * 单引号、尾随逗号、NaN/Infinity 等扩展。失败抛 IllegalArgumentException，
 * 消息带出错字节偏移（定位长报文里的坏点）。 */
Json parseJson(const std::string& text);

} // namespace bot
