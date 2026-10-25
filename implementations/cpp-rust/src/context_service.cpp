#include "context_service.hpp"

#include <cstdint>
#include <string>

#include "agentmode.hpp"
#include "agentprompt.hpp"
#include "agentview.hpp"
#include "mcp_protocol.hpp"
#include "robot.hpp"

namespace bot::agent {

Json buildContextData(const AgentModeConfig& cfg, RobotStruct& robot) {
	const std::string sql = structureScriptHead(cfg.structurePath, kStructureHeadBytes);
	const std::string scripts = describeActionScripts(cfg.scriptsDir);

	Json data = JsonObject();
	data.put(mcp_protocol::kRobotName, JsonString(structureDisplayName(cfg.structurePath)));
	data.put(mcp_protocol::kStructurePath, JsonString(cfg.structurePath));
	data.put(mcp_protocol::kScriptsDir, JsonString(cfg.scriptsDir));
	data.put(mcp_protocol::kAllowShell, JsonBool(cfg.allowShell));
	data.put(mcp_protocol::kAllowHotSql, JsonBool(cfg.allowHotSql));
	data.put(mcp_protocol::kHardwareCount,
		JsonInt(static_cast<std::int64_t>(robot.registry().byName().size())));
	data.put(mcp_protocol::kStructureExcerpt, JsonString(sql.empty()
			? std::string("(结构脚本不可读)\n")
			: quoteUntrusted("结构脚本 " + cfg.structurePath + " 摘录：\n", sql)));
	data.put(mcp_protocol::kHardwareList,
		JsonString(quoteUntrusted("硬件变量清单：\n", describeHardware(robot))));
	data.put(mcp_protocol::kScriptsList, JsonString(quoteUntrusted(
			"动作脚本清单（相对路径 + 首行注释）：\n", scripts)));
	data.put(mcp_protocol::kReadableVars,
		JsonString(describeReadableVars(cfg.readVars, robot)));
	return data;
}

} // namespace bot::agent
