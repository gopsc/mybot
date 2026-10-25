#include "agentproto.hpp"

#include <stdexcept>
#include <utility>

#include "jsonparse.hpp"
#include "util_except.hpp"
#include "util_str.hpp"

namespace bot {
namespace agent {

namespace {

/* 报错里附片段：长报文只在开头出问题，截断避免刷屏 */
std::string snippet(const std::string& s, std::size_t n = 400) {
	return s.size() <= n ? s : s.substr(0, n) + "...(截断)";
}

} // namespace

Json parseToolArguments(const std::string& arguments) {
	std::string t = trim(arguments);
	if (t.empty()) { return JsonObject(); }
	Json v = parseJson(t);
	if (!v.isObj()) {
		throw IllegalArgumentException("工具参数不是 JSON 对象: " + snippet(arguments, 200));
	}
	return v;
}

} // namespace agent
} // namespace bot
