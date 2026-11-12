/* agentaudit.cpp —— 审计轨迹实现（见 agentaudit.hpp 的设计约束） */

#include "agentaudit.hpp"

#include <cstdint>

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <unistd.h>

#include "agent_subprocess.hpp"
#include "util_str.hpp"
#include "util_utf8.hpp"

namespace bot {
namespace agent {

namespace {

/* FNV-1a 64 位参数（素数与偏移基是算法标准值） */
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;
constexpr std::uint64_t kFnvBasis = 14695981039346656037ULL;

/* 遮蔽专用补充词：对「环境变量名清洗」无意义（没有叫这个的环境变量要挡），
 * 但命令文本里的凭据头（Authorization: Bearer xxx）恰好长这样 */
bool isMaskOnlyWord(const std::string& w) {
	return w == "authorization" || w == "bearer";
}

bool maskedWord(const std::string& w) {
	return isSensitiveEnvName(w) || isMaskOnlyWord(w);
}

/* 与 isSensitiveEnvName 同一整词切词法（util::anyWordOf 单点）：名字按非字母
 * 数字分段，任一段命中即遮蔽（api-key → {api, key} 命中；keystone →
 * {keystone} 不命中） */
bool isMaskedName(const std::string& lowerName) {
	return anyWordOf(lowerName, maskedWord);
}

/* 敏感值的结束下标（不含）。裸值到空白或引号为止；值以引号开头时是引号值：
 * 连同定界引号整体遮蔽，扫到**同种**配对引号，未闭合按到串尾处理（宁可多遮
 * 不可漏遮）。引号段与裸段可拼接（shell 连接语义 `"a"b'c'` 是一个值），全部吃掉。
 * 2026-09-24 审计 H1：旧实现把引号一律当终止符，值首字符即引号时掩蔽区为空，
 * `KEY="sk-x"` 的密钥留在明文。 */
std::size_t maskedValueEnd(const std::string& text, std::size_t k) {
	const std::size_t n = text.size();
	while (k < n) {
		const char c = text[k];
		if (c == '"' || c == '\'') {
			const char quote = c;
			++k;
			while (k < n && text[k] != quote) { ++k; }
			if (k < n) { ++k; }	/* 跳过收尾引号 */
			continue;
		}
		if (std::isspace(static_cast<unsigned char>(c))) { break; }
		++k;
	}
	return k;
}

} // namespace

AuditLog::~AuditLog() {
	if (file_ != nullptr) { std::fclose(static_cast<FILE*>(file_)); }
}

bool AuditLog::open(const std::string& path, std::string& err) {
	if (opened_) {
		err = "审计日志已打开: " + path_;
		return false;
	}
	if (path.empty()) {
		err = "审计日志路径为空";
		return false;
	}
	/* 会话 id：时间 + pid 的 64 位 FNV 指纹取 8 位 hex——只用于把同一会话的
	 * 行对上号，不要求不可预测。 */
	{
		struct timespec ts{};
		clock_gettime(CLOCK_REALTIME, &ts);
		const std::uint64_t seed = static_cast<std::uint64_t>(ts.tv_sec) * 1000000000ULL
			+ static_cast<std::uint64_t>(ts.tv_nsec)
			+ static_cast<std::uint64_t>(::getpid()) * 0x9E3779B97F4A7C15ULL;
		sessionId_ = fingerprint64(std::to_string(seed)).substr(0, 8);
	}
	if (path == "-") {
		toStderr_ = true;
	} else {
		FILE* f = std::fopen(path.c_str(), "a");
		if (f == nullptr) {
			err = "无法打开审计日志文件 '" + path + "'（errno=" + std::to_string(errno)
				+ "）；请检查目录是否存在、是否有写权限，或在配置错误阶段先修正路径";
			return false;
		}
		file_ = f;
	}
	path_ = path;
	opened_ = true;
	return true;
}

/* ---- AuditLog::write 的每 kind 字段段（2026-09-29 A3 拆分）----
 * 两个函数只往 line 里放各自 kind 的字段；公共头（ts/session/kind）与
 * 输出尾（stderr/文件落盘）留在 write()。字段与顺序逐字保持。
 * 2026-10-01 批次 A（P1-6）：writeModelFields 已随 agent 循环迁 Rust 删除
 * （C++ 后端不发起模型调用，model 行零写入者；模型轮次记进 agent 侧审计
 * 文件，见 agent/src/audit.rs）。 */

/* 会话边界记录（SAN-9）：C++ 侧只记会话生命周期事件（start/end/error/
 * disconnect_action/auth_failed）。**绝不写密钥**。模型侧配置字段
 * （driver/model/endpoint/api_key_source）已随迁 Rust 退场。 */
static void writeSessionFields(const AuditEntry& e, Json& line) {
	line.put("status", JsonString(e.status.empty() ? "start" : e.status));
	if (!e.error.empty()) { line.put("error", JsonString(e.error)); }
	if (e.ms > 0) { line.put("ms", JsonInt(e.ms)); }
	/* 2026-09-25：断连安全动作（status=disconnect_action）自报"跑了哪个脚本"。
	 * 加法字段，既有 start/end 记录不给、不出现。 */
	if (!e.summary.empty()) { line.put("summary", JsonString(e.summary)); }
}

/* 既有工具行：字段与顺序**一个不动**（兼容性硬约束） */
static void writeToolFields(const AuditEntry& e, Json& line) {
	line.put("turn", JsonInt(e.turn));
	if (!e.requestId.empty()) { line.put("requestId", JsonString(e.requestId)); }
	line.put("tool", JsonString(e.tool));
	if (e.args.isObj()) {
		line.put("args", e.args);
	} else if (!e.argsRaw.empty()) {
		/* 参数解析失败/非对象：记原始文本（截断，显式标注） */
		std::string raw = e.argsRaw;
		if (raw.size() > kMaxAuditArgsRaw) {
			raw = raw.substr(0, kMaxAuditArgsRaw)
				+ "...(截断，原始 " + std::to_string(e.argsRaw.size()) + " 字节)";
		}
		line.put("args_raw", JsonString(sanitizeUtf8(raw)));
	}
	line.put("ok", JsonBool(e.ok));
	if (!e.error.empty()) { line.put("error", JsonString(e.error)); }
	line.put("ms", JsonInt(e.ms));
	line.put("bytes", JsonInt(static_cast<std::int64_t>(e.bytes)));
	if (e.imageBytes > 0) {
		/* 图片只记体积与指纹：base64 不落盘（体积 + 隐私，见头文件约束） */
		line.put("image_bytes", JsonInt(static_cast<std::int64_t>(e.imageBytes)));
		line.put("image_fp", JsonString(e.imageFp));
	}
	if (e.exitCode.has_value()) { line.put("exit_code", JsonInt(*e.exitCode)); }
	/* G2：工具自报的生效摘要（apply_sql 等）。加法字段，老行没有。 */
	if (!e.summary.empty()) { line.put("summary", JsonString(e.summary)); }
}

void AuditLog::write(const AuditEntry& e) {
	if (!opened_) { return; }

	Json line = JsonObject();
	line.put("ts", JsonString(auditTimestamp()));
	line.put("session", JsonString(sessionId_));
	/* kind 显式写在最前（紧跟 session）：老消费方不看它，新消费方按它分派。
	 * 工具行也显式写 "tool"——不是"缺省即 tool"的隐式约定，省得后来者猜。 */
	line.put("kind", JsonString(e.kind.empty() ? "tool" : e.kind));

	if (e.kind == "session") {
		writeSessionFields(e, line);
	} else {
		writeToolFields(e, line);
	}

	std::string text = line.toString();
	text.push_back('\n');
	if (toStderr_) {
		std::fputs(text.c_str(), stderr);
		std::fflush(stderr);
		return;
	}
	FILE* f = static_cast<FILE*>(file_);
	if (f == nullptr || std::fputs(text.c_str(), f) == EOF || std::fflush(f) != 0) {
		/* 落盘失败响亮告警一次：审计「看起来在记、其实没记」比没有更糟。
		 * 不抛异常——审计失败不该打断机器人正在执行的动作。 */
		if (!warnBroken_) {
			warnBroken_ = true;
			std::fputs("警告: 审计日志写入失败（磁盘满/权限？），本次会话的后续记录"
				"可能丢失；工具执行不受影响\n", stderr);
		}
	}
}

std::string maskSecretsInText(const std::string& text) {
	std::string out;
	out.reserve(text.size());
	std::size_t i = 0;
	const std::size_t n = text.size();
	while (i < n) {
		const char c = text[i];
		/* 形态四：JSON 引号键 `"name": value`（2026-10-08 审计 P1 续——`read_file`
		 * 接上本单点后实测发现：本仓真实密钥落盘形态（`mybot.llm.json`/会话
		 * JSONL）恰恰是这种被双引号包住的键名，形态三的裸标识符扫描在遇到键名
		 * 前导的 `"` 时就不是字母/下划线，根本进不了标识符分支，`"api_key": "x"`
		 * 因此被判定为"无赋值形态的普通文本"原样放行——这是 run_command 从
		 * 2026-09-23 G1 起就存在的盲区，cat 一份 JSON 格式的密钥文件从未被真正
		 * 遮蔽过，只是过去没人拿真实 JSON 内容去测过 maskSecretsInText。
		 * 判据：引号、敏感整词、引号收尾、可选空白、冒号——键名本身原样保留
		 * （便于模型看出"这是哪个字段"），值整体替换为 ***（与形态一/三同口径）。 */
		if (c == '"') {
			std::size_t q = i + 1;
			while (q < n && (std::isalnum(static_cast<unsigned char>(text[q]))
				|| text[q] == '_' || text[q] == '-')) { ++q; }
			if (q > i + 1 && q < n && text[q] == '"') {
				std::size_t afterQuote = q + 1;
				std::size_t k = afterQuote;
				while (k < n && std::isspace(static_cast<unsigned char>(text[k]))) { ++k; }
				if (k < n && text[k] == ':' && isMaskedName(toLowerAscii(text.substr(i + 1, q - i - 1)))) {
					out += text.substr(i, afterQuote - i);	/* "api_key" 原样保留 */
					out += text.substr(afterQuote, k - afterQuote);	/* 键后空白 */
					out += ':';
					++k;
					while (k < n && std::isspace(static_cast<unsigned char>(text[k]))) {
						out += text[k];
						++k;
					}
					out += "***";
					i = maskedValueEnd(text, k);
					continue;
				}
			}
			/* 不是"敏感引号键"：不消耗任何字符，落到下面按普通字符逐个拷贝。 */
		}
		if (!(std::isalpha(static_cast<unsigned char>(c)) || c == '_')) {
			out += c;
			++i;
			continue;
		}
		std::size_t j = i;
		while (j < n && (std::isalnum(static_cast<unsigned char>(text[j]))
			|| text[j] == '_' || text[j] == '-')) { ++j; }
		const std::string name = toLowerAscii(text.substr(i, j - i));

		/* 形态一：敏感名=值（裸值或引号值，整体替换为 ***） */
		if (j < n && text[j] == '=' && isMaskedName(name)) {
			out += text.substr(i, j - i);
			out += "=***";
			i = maskedValueEnd(text, j + 1);
			continue;
		}
		/* 形态二：Bearer 令牌（`Bearer <tok>`；裸令牌或引号令牌）。
		 * 只认这个词本身：Authorization 后面跟 Basic/Token 等其他 scheme 时
		 * 由形态三兜住，这里不重复。 */
		if (name == "bearer") {
			out += text.substr(i, j - i);
			std::size_t m = j;
			while (m < n && std::isspace(static_cast<unsigned char>(text[m]))) {
				out += text[m];
				++m;
			}
			out += "***";
			i = maskedValueEnd(text, m);
			continue;
		}
		/* 形态三：敏感头 `Name: value`（如 Authorization: Basic ...）——
		 * 值若是 "bearer"，随后的令牌交给形态二继续遮（Authorization: Bearer
		 * sk-xxx 会先遮掉 "Bearer"，再由形态二遮掉令牌本身）。 */
		if (isMaskedName(name) && j < n && text[j] == ':') {
			out += text.substr(i, j - i);
			std::size_t m = j;
			while (m < n && (text[m] == ':' || std::isspace(static_cast<unsigned char>(text[m])))) {
				out += text[m];
				++m;
			}
			std::size_t p = maskedValueEnd(text, m);
			const std::string scheme = toLowerAscii(text.substr(m, p - m));
			out += "***";
			if (scheme == "bearer") {
				std::size_t q = p;
				while (q < n && std::isspace(static_cast<unsigned char>(text[q]))) {
					out += text[q];
					++q;
				}
				out += "***";
				i = maskedValueEnd(text, q);
				continue;
			}
			i = p;
			continue;
		}
		out += text.substr(i, j - i);
		i = j;
	}
	return out;
}

std::string fingerprint64(const std::string& s) {
	std::uint64_t h = kFnvBasis;
	for (char c : s) {
		h ^= static_cast<unsigned char>(c);
		h *= kFnvPrime;
	}
	char buf[20];
	std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
	return buf;
}

std::string auditTimestamp() {
	struct timespec ts{};
	clock_gettime(CLOCK_REALTIME, &ts);
	struct tm tmv{};
	localtime_r(&ts.tv_sec, &tmv);
	const long off = tmv.tm_gmtoff;
	const char sign = off >= 0 ? '+' : '-';
	const long abso = off >= 0 ? off : -off;
	char buf[96];	/* gcc 的 -Wformat-truncation 按「最坏展开」估算（年可达 11 位、
			 * 时区偏移可达 14 位），48 字节会被误判截断；96 一步到位 */
	std::snprintf(buf, sizeof buf,
		"%04d-%02d-%02dT%02d:%02d:%02d.%03ld%c%02ld:%02ld",
		tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
		tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
		static_cast<long>(ts.tv_nsec / 1000000),
		sign, abso / 3600, (abso % 3600) / 60);
	return buf;
}

} // namespace agent
} // namespace bot
