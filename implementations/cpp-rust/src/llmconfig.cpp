#include "llmconfig.hpp"

#include <cmath>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "json.hpp"
#include "jsonconfig.hpp"
#include "util_env.hpp"
#include "util_num.hpp"

namespace bot {

namespace {

constexpr std::size_t kMaxConfigBytes = 64u << 10;

/* 本类文件的读取口径：报错名词/动词逐字沿用旧文案；空文件独立报错。 */
const jsonconfig::ConfigKind kConfigKind = {"配置文件", "需要", true, kMaxConfigBytes};

bool fileReadable(const std::string& path) {
	std::ifstream f(path, std::ios::binary);
	return static_cast<bool>(f);
}

/* 阶段 4.1：本地 readWholeFile 已收敛到 util::readWholeFileLimited——
 * 旧实现读满 cap 即返回、不查剩余，把超限文件静默截断后伪装成
 * 「不是合法 JSON」（密钥文件则伪装成「密钥错误」）。 */

/* 字段类型不符时的统一报错（带字段名与期望类型，排障时不用猜）——
 * 文案本体在 jsonconfig 单点，这里只绑定本文件的读取口径 */
std::string typeError(const std::string& path, const std::string& key, const char* want) {
	return jsonconfig::typeError(kConfigKind, path, key, want);
}

/* ---- wantXxx 六同形校验器的公共骨架（2026-10-01 表驱动化收敛）----
 * 六个校验器同形：「字段缺失 → 通过（保持未配置）」+「类型不符 → typeError」
 * 这两步完全一致，差异只在类型判据与转换。骨架单点化后，各 wantXxx 只剩
 * 自己的类型语义（空串口径 / 值域 / 取整 / 元素遍历），类型判据以谓词表
 * 传入。返回三态：字段缺失 / 类型不符（err 已填）/ 取到值。 */
enum class Fetched { Absent, Mismatch, Ok };

Fetched fetchField(const std::string& path, const Json& root, const char* key,
		bool (*typeOk)(const Json&), const char* wantName,
		std::optional<Json>& out, std::string& err) {
	out = root.get(key);
	if (!out) { return Fetched::Absent; }
	if (!typeOk(*out)) {
		err = typeError(path, key, wantName);
		return Fetched::Mismatch;
	}
	return Fetched::Ok;
}

bool isStrField(const Json& v) { return v.isStr(); }
bool isNumField(const Json& v) { return v.isInt() || v.isFloat(); }
bool isBoolField(const Json& v) { return v.isBool(); }
bool isArrField(const Json& v) { return v.isArr(); }

bool wantString(const std::string& path, const Json& root, const char* key,
		std::optional<std::string>& out, std::string& err) {
	std::optional<Json> v;
	const Fetched f = fetchField(path, root, key, isStrField, "字符串", v, err);
	if (f != Fetched::Ok) { return f == Fetched::Absent; }
	/* 空串按「未配置」处理：示例配置里留空占位是常见写法，若当成有效值会把
	 * camera_device:"" 之类的占位写成「空设备名」这种与意图脱节的值。 */
	if (!v->getValue().empty()) { out = v->getValue(); }
	return true;
}

bool wantInt(const std::string& path, const Json& root, const char* key,
		long lo, long hi, std::optional<int>& out, std::string& err) {
	std::optional<Json> v;
	const Fetched f = fetchField(path, root, key, isNumField, "数字", v, err);
	if (f != Fetched::Ok) { return f == Fetched::Absent; }
	double d = v->isInt() ? static_cast<double>(v->getInt()) : v->getFloat();
	/* P1-5 防线（2026-09-19 评估）：先判有限与值域，再谈取整。配置里写
	 * "timeout": 1e300（或 inf/nan）时 static_cast<long long>(d) 是
	 * float-cast-overflow UB，范围检查根本来不及执行。 */
	if (!std::isfinite(d) || d < static_cast<double>(lo) || d > static_cast<double>(hi)) {
		std::ostringstream os;
		os << d;
		err = rangeErrorText("配置文件 " + path + " 的字段 '" + key + "'", lo, hi, os.str());
		return false;
	}
	if (std::floor(d) != d) {
		err = typeError(path, key, "整数");
		return false;
	}
	out = static_cast<int>(d);
	return true;
}

bool wantBool(const std::string& path, const Json& root, const char* key,
		std::optional<bool>& out, std::string& err) {
	std::optional<Json> v;
	const Fetched f = fetchField(path, root, key, isBoolField, "布尔值", v, err);
	if (f != Fetched::Ok) { return f == Fetched::Absent; }
	out = v->getBool();
	return true;
}

bool wantStringArray(const std::string& path, const Json& root, const char* key,
		std::optional<std::vector<std::string>>& out, std::string& err) {
	std::optional<Json> v;
	const Fetched f = fetchField(path, root, key, isArrField, "字符串数组", v, err);
	if (f != Fetched::Ok) { return f == Fetched::Absent; }
	std::vector<std::string> items;
	for (const Json& item : v->arr) {
		if (!item.isStr()) {
			err = "配置文件 " + path + " 的字段 '" + key + "' 的元素需要字符串";
			return false;
		}
		if (!item.getValue().empty()) { items.push_back(item.getValue()); }
	}
	/* 空数组按「未配置」处理：与 wantString 的空串口径一致，占位写法不生效 */
	if (!items.empty()) { out = std::move(items); }
	return true;
}

/* ---- 读取 + 解析 + 顶层形态 + 未知字段（F2-8 拆分之一）----
 * 骨架（受限读取/解析/顶层形态/未知字段拒绝）已收敛到 jsonconfig::loadRoot
 * 单点，与 agentpolicy 共用；这里只登记本文件自己的 schema 白名单。
 * 白名单包含**全部**两端键：模型侧键（driver/endpoint/model/api_key/采样/
 * 预算/重试/提示词包/会话/stream/摘要……）是 mybot-agent 的合法配置，本侧
 * 只登记不解析（类型/区间由 Rust config.rs 校验）——两端共用一份文件时，
 * 拒绝它们等于让后端读不了操作者的配置（批次 2，2026-10-01）。 */
bool loadConfigRoot(const std::string& path, Json& root, std::string& err) {
	static const std::set<std::string> kKnown = {
		"driver", "var", "endpoint", "model", "api_key", "api_key_file",
		"timeout", "max_tokens", "temperature", "top_p", "max_task_seconds",
		"reasoning_effort", "thinking", "max_turns", "scripts_dir", "allow_shell",
		"allow_hot_sql",
		"prompt_files", "camera_var", "camera_device", "camera_src", "camera_src_dir",
		"allow_camera", "audit_log", "agent_policy", "read_vars", "fs_root",
		"allow_write_file",
		"session_file",
		"max_history_bytes", "max_task_tool_result_bytes", "max_task_image_bytes",
		"max_calls_per_round", "max_retries", "retry_backoff_ms",
		"run_command_timeout_sec", "run_command_max_timeout_sec",
		"action_script_timeout_sec",
		/* Rust agent 专属：模型输出是否流式。C++ 侧没有流式面，只登记 */
		"stream",
		/* Rust agent 专属：被裁任务块是否压成摘要及摘要字节上限，只登记 */
		"history_summary", "max_summary_bytes",
	};
	return jsonconfig::loadRoot(kConfigKind, path, kKnown, root, err);
}

/* 字符串族字段（本侧消费面：scripts/摄像头/审计/策略 + 两个只为了指名拒绝的） */
bool parseConfigStrings(const std::string& path, const Json& root, LlmFileConfig& out,
		std::string& err) {
	if (!wantString(path, root, "scripts_dir", out.scriptsDir, err)) { return false; }
	if (!wantString(path, root, "camera_var", out.cameraVar, err)) { return false; }
	if (!wantString(path, root, "camera_device", out.cameraDevice, err)) { return false; }
	if (!wantString(path, root, "camera_src", out.cameraSrc, err)) { return false; }
	if (!wantString(path, root, "audit_log", out.auditLog, err)) { return false; }
	if (!wantString(path, root, "agent_policy", out.agentPolicy, err)) { return false; }
	/* H1：解析 camera_src_dir 只是为了**指名拒绝**（见 agentmode.cpp 的
	 * buildAgentConfig）——若不在这里解析，它会落到「未知字段」分支，
	 * 报错会让人以为是拼写错误。 */
	if (!wantString(path, root, "camera_src_dir", out.cameraSrcDir, err)) { return false; }
	/* Phase 4：同 camera_src_dir 的 H1 理由——解析出来只为了指名拒绝 fs_root，
	 * 不让它落进「未知字段」分支被误读成拼写错误。 */
	if (!wantString(path, root, "fs_root", out.fsRoot, err)) { return false; }
	return true;
}

/* 数值族字段（本侧消费面：工具层超时；区间单点 llm_limits。跨字段关系
 * （run_command 上限 ≥ 缺省）不在这里判——配置文件可能只给一个字段，那样
 * 要拿**生效值**（另一个是缺省）比，判定落在 agentmode 的合流处。 */
bool parseConfigNumbers(const std::string& path, const Json& root, LlmFileConfig& out,
		std::string& err) {
	std::optional<int> rcTimeout, rcMaxTimeout, scriptTimeout;
	if (!wantInt(path, root, "run_command_timeout_sec",
			llm_limits::kRunCommandTimeoutMinSec, llm_limits::kRunCommandTimeoutMaxSec,
			rcTimeout, err)) { return false; }
	if (!wantInt(path, root, "run_command_max_timeout_sec",
			llm_limits::kRunCommandMaxTimeoutMinSec, llm_limits::kRunCommandMaxTimeoutMaxSec,
			rcMaxTimeout, err)) { return false; }
	/* PL-2：动作脚本执行预算。0 合法 = 显式关闭（「未配置」与「配成 0」必须
	 * 区分，故走 optional 而不是 `if (*opt)`）。 */
	if (!wantInt(path, root, "action_script_timeout_sec",
			llm_limits::kActionScriptTimeoutMinSec, llm_limits::kActionScriptTimeoutMaxSec,
			scriptTimeout, err)) { return false; }
	out.runCommandTimeoutSec = rcTimeout;
	out.runCommandMaxTimeoutSec = rcMaxTimeout;
	out.actionScriptTimeoutSec = scriptTimeout;
	return true;
}

/* 布尔与数组族字段 */
bool parseConfigBools(const std::string& path, const Json& root, LlmFileConfig& out,
		std::string& err) {
	if (!wantBool(path, root, "allow_shell", out.allowShell, err)) { return false; }
	if (!wantBool(path, root, "allow_hot_sql", out.allowHotSql, err)) { return false; }
	/* Phase 5：解析出来只为了指名拒绝（见 llmconfig.hpp 的 allowWriteFile 注释）。 */
	if (!wantBool(path, root, "allow_write_file", out.allowWriteFile, err)) { return false; }
	if (!wantBool(path, root, "allow_camera", out.allowCamera, err)) { return false; }
	/* 回读清单：解析出来**只为了拒绝**（见 llmconfig.hpp 的 readVars 注释）——
	 * 不在这里解析就会落到「未知字段」分支，报错会让人以为是拼写错误。 */
	if (!wantStringArray(path, root, "read_vars", out.readVars, err)) { return false; }
	return true;
}

} // namespace

bool loadLlmConfigFile(const std::string& path, LlmFileConfig& out, std::string& err) {
	Json root;
	if (!loadConfigRoot(path, root, err)) { return false; }
	/* 阶段顺序 = 报错优先级：字符串族 → 浮点 → 整数 → 布尔/数组。
	 * 配置文件有多个字段非法时，报的是这条链上第一个命中的字段。 */
	if (!parseConfigStrings(path, root, out, err)) { return false; }
	if (!parseConfigNumbers(path, root, out, err)) { return false; }
	if (!parseConfigBools(path, root, out, err)) { return false; }
	return true;
}

std::string findDefaultLlmConfig() {
	static const char* kCandidates[] = {"./mybot.llm.json", "./mybot.llm.conf.json"};
	for (const char* c : kCandidates) {
		if (fileReadable(c)) { return c; }
	}
	auto home = getEnvVar("HOME");
	if (home && !home->empty()) {
		std::string p = *home + "/.config/mybot/llm.json";
		if (fileReadable(p)) { return p; }
	}
	return "";
}

} // namespace bot
