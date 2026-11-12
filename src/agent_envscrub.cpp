/* agent_envscrub.cpp —— run_command 子进程的环境清洗域
 *
 * 2026-10-01 自 agent_subprocess.cpp 拆出（行为保持）：敏感词判据（整词切词）、
 * 环境名小写化、子进程继承环境的清洗（buildCleanEnvp）与宿主密钥抹零
 * （collectEnvSecrets/scrubEnvSecrets）。对外判据单点 isSensitiveEnvName 被
 * agentaudit 的命令遮蔽复用——本 TU 即那份判据的锚地。 */

#include "agent_subprocess.hpp"
#include "agent_subprocess_internal.hpp"

#include <cstring>
#include <string_view>
#include <vector>

#include "util_str.hpp"		/* anyWordOf / toLowerAscii（整词切词单点） */

/* 进程环境块。glibc 不在 <unistd.h> 里声明它，必须在**全局作用域**声明：
 * 放进匿名命名空间会变成另一个符号（bot::agent::{anon}::environ），链接期
 * 报 undefined reference。 */
extern char** environ;

namespace bot {
namespace agent {

/* 敏感词：按**整词**匹配（词 = 名字里连续的非字母数字分隔出的片段）。
 * 旧实现是子串匹配，"KEY" 会连带剔除 KEYSTONE / MONKEY / HOCKEY / TOKENIZER——
 * 误伤与漏网同时存在（"APIKEY" / "PGPASSWORD" 这类无分隔符的复合名又恰好
 * 逃过词表？不，旧实现会命中；改成整词后它们必须显式列举）。 */
static bool isSensitiveWord(const std::string& word) {
	static const char* kWORDS[] = {"key", "token", "secret", "password", "passwd",
				       "credential"};
	for (const char* w : kWORDS) {
		if (word == w) { return true; }
	}
	/* 不含分隔符的已知复合密钥名：整词匹配抓不到，又不能退回子串匹配
	 * （会误伤 keystone/monkey），故显式列举——宁可短表可控，也不做模糊匹配。 */
	static const char* kCOMPOUNDS[] = {"apikey", "accesskey", "accesskeyid", "secretkey",
					   "clientsecret", "privatekey", "authkey", "authtoken",
					   "accesstoken", "refreshtoken", "pgpassword", "passphrase"};
	for (const char* w : kCOMPOUNDS) {
		if (word == w) { return true; }
	}
	return false;
}

namespace {

/* 环境变量名（'=' 之前）转小写；无 '=' 的畸形条目返回空串表示跳过 */
std::string lowerEnvName(const char* entry) {
	std::string_view s(entry);
	std::size_t eq = s.find('=');
	if (eq == std::string_view::npos) { return {}; }
	return toLowerAscii(std::string(s.substr(0, eq)));
}

} // namespace

/* 敏感名判据：按分隔符切词后逐词查表（BOT4CJ_LLM_KEY → {bot4cj, llm, key} →
 * 命中 key）。buildCleanEnvp 与 collectEnvSecrets 共用同一份，否则「子进程清洗
 * 名单」与「宿主抹除名单」会各自漂移；agentaudit 的命令遮蔽亦复用它。 */
bool isSensitiveEnvName(const std::string& lowerName) {
	return anyWordOf(lowerName, isSensitiveWord);
}

/* 环境清洗：剔除名字**含敏感词（整词）**的变量。模型可能被外部输入（画面/文件
 * 内容）诱导执行任意命令，不能让子进程继承 LLM API key。
 * 判定按分隔符切词，因此不误伤 KEYSTONE/MONKEY；无分隔符的复合名由
 * isSensitiveWord 的复合表覆盖（APIKEY / PGPASSWORD 仍被剔除）。 */
std::vector<char*> buildCleanEnvp() {
	std::vector<char*> envp;
	for (char** e = ::environ; e && *e; ++e) {
		if (!isSensitiveEnvName(lowerEnvName(*e))) { envp.push_back(*e); }
	}
	envp.push_back(nullptr);
	return envp;
}

std::vector<char*> collectEnvSecrets() {
	std::vector<char*> out;
	for (char** e = ::environ; e && *e; ++e) {
		if (isSensitiveEnvName(lowerEnvName(*e))) { out.push_back(*e); }
	}
	return out;
}

/* 逐字节抹零。用 volatile 目的指针，防止编译器把「之后不再读取」的存储优化掉
 * （被优化掉就等于没抹）。
 * 抹的是整条 "NAME=VALUE"（连名字一起），而 glibc getenv 按 "NAME=" 前缀匹配，
 * 于是数组槽位没被 setenv 换掉的那些变量会直接从环境里**消失**（getenv 返回
 * NULL）。这不影响取值：密钥一律以 BOT4CJ_LLM_KEY 重新注入（堆上的新串，槽位已
 * 替换），而驱动按 BOT4CJ_LLM_KEY → ROBOT_AGENT_API_KEY → DEEPSEEK_API_KEY 的
 * 同一顺序取值，排第一的那个一定有值。 */
void scrubEnvSecrets(const std::vector<char*>& pointers) {
	for (char* p : pointers) {
		if (p == nullptr) { continue; }
		const std::size_t n = std::strlen(p);
		volatile char* v = p;
		for (std::size_t i = 0; i < n; ++i) { v[i] = '\0'; }
	}
}

} // namespace agent
} // namespace bot
