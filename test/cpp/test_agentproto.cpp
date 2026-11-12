#include "harness.hpp"

#include <string>

#include "agentproto.hpp"
#include "jsonparse.hpp"
#include "util_except.hpp"

using namespace bot;
using namespace bot::agent;

/* 沿革：这里曾覆盖宿主 ⇄ Lua 驱动的整条规范化协议（buildDriverRequest /
 * messageToJson / parseDriverResponse 及其形变矩阵、A7 长度上限）。agent 循环
 * 迁 Rust 后传输层已删除（见 agentproto.hpp），对等语义由 Rust 侧
 * agent/src（bridge/prompt）与 scripts/agent_e2e.sh 承担；本文件只剩仍然
 * 存活的参数解析单点。 */

TH_TEST(agentproto_parse_tool_arguments) {
	TH_CHECK(parseToolArguments("").isObj());
	TH_CHECK(parseToolArguments("   ").isObj());
	TH_CHECK(parseToolArguments("{\"x\":1}").get("x")->getInt() == 1);
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "不是 JSON 对象",
		parseToolArguments("[1,2]"));
	TH_CHECK_THROWS(IllegalArgumentException, parseToolArguments("{bad}"));
}
