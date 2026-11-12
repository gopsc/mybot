/* jsonconfig.cpp —— 读取骨架实现（口径与差异声明见 jsonconfig.hpp） */

#include "jsonconfig.hpp"

#include <exception>

#include "jsonparse.hpp"
#include "util_file.hpp"

namespace bot {
namespace jsonconfig {

/* 未知字段拒绝：拼错一个键（如 "apikey"）而静默走缺省，会让人以为配置生效了。
 * 与「未知 --key 退出 2」同一口径（原 llmconfig 的 F2-8 拆分注释，两处同判据）。 */
bool loadRoot(const ConfigKind& kind, const std::string& path,
		const std::set<std::string>& known, Json& root, std::string& err) {
	std::string text;
	if (!readWholeFileLimited(path, kind.maxBytes, text, err, kind.label)) {
		return false;
	}
	if (kind.rejectEmpty && text.empty()) {
		err = std::string(kind.label) + "为空: " + path;
		return false;
	}
	try {
		root = parseJson(text);
	} catch (const std::exception& e) {
		err = std::string(kind.label) + " " + path + " 不是合法 JSON: " + e.what();
		return false;
	}
	if (!root.isObj()) {
		err = std::string(kind.label) + " " + path + " 的顶层必须是 JSON 对象";
		return false;
	}
	for (const auto& kv : root.items()) {
		if (known.count(kv.first) == 0) {
			err = std::string(kind.label) + " " + path + " 含未知字段 '" + kv.first
				+ "'（拼写错误？）";
			return false;
		}
	}
	return true;
}

std::string typeError(const ConfigKind& kind, const std::string& path,
		const std::string& key, const char* want) {
	return std::string(kind.label) + " " + path + " 的字段 '" + key + "' "
		+ kind.verb + want;
}

} // namespace jsonconfig
} // namespace bot
