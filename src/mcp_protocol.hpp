#pragma once
/* mcp_protocol.hpp —— 跨进程 MCP JSON 协议字段的 C++ 单一命名表。
 * 线帧仍由 mcptransport 负责；本文件只定义路由与业务载荷字段，避免路由实现
 * 和工具结果序列化各自散落字符串。Rust 对应 agent/src/protocol.rs，两侧名单由
 * test/cpp/test_mcptransport.cpp 的 mcpbackend_protocol_wire_names_match_rust_twin
 * 互钉（含「生产 TU 不得退回裸字面量」），改一侧必须同步另一侧。
 */

namespace bot::agent::mcp_protocol {
inline constexpr const char* kRoute = "_route";
inline constexpr const char* kPing = "ping";
inline constexpr const char* kToolList = "tool.list";
inline constexpr const char* kToolCall = "tool.call";
inline constexpr const char* kContextGet = "context.get";
inline constexpr const char* kAuth = "auth";
inline constexpr const char* kToken = "token";

inline constexpr const char* kSuccess = "success";
inline constexpr const char* kData = "data";
inline constexpr const char* kError = "error";
inline constexpr const char* kTools = "tools";
inline constexpr const char* kName = "name";
inline constexpr const char* kDescription = "description";
inline constexpr const char* kInputSchema = "inputSchema";
inline constexpr const char* kArguments = "arguments";
inline constexpr const char* kRequestId = "requestId";

inline constexpr const char* kText = "text";
inline constexpr const char* kImageDataUrl = "imageDataUrl";
inline constexpr const char* kOk = "ok";
inline constexpr const char* kExecuted = "executed";
inline constexpr const char* kParamError = "paramError";
inline constexpr const char* kSummary = "summary";

inline constexpr const char* kRobotName = "robotName";
inline constexpr const char* kStructurePath = "structurePath";
inline constexpr const char* kScriptsDir = "scriptsDir";
inline constexpr const char* kAllowShell = "allowShell";
inline constexpr const char* kAllowHotSql = "allowHotSql";
inline constexpr const char* kHardwareCount = "hardwareCount";
inline constexpr const char* kStructureExcerpt = "structureExcerpt";
inline constexpr const char* kHardwareList = "hardwareList";
inline constexpr const char* kScriptsList = "scriptsList";
inline constexpr const char* kReadableVars = "readableVars";
}
