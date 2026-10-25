/* test_agentaudit.cpp —— 审计轨迹（--audit-log）的直接锚点
 *
 * 覆盖面：
 *   1) maskSecretsInText：敏感 KEY=VALUE 遮蔽 / 非敏感名不误伤 / 普通命令原样
 *   3) fingerprint64：确定性 + 输入不同指纹不同
 *   4) AuditLog：JSON Lines 落盘形态（ts/session/tool/ok/ms/bytes 齐备）、
 *      图片只记体积与指纹（base64 不落盘）、坏路径上电前失败
 *
 * 审计是「事后复盘」的证据链，这里的断言就是它的最低可信判据：
 * 行必须是合法 JSON、字段齐备、绝不含图片数据本体。
 */

#include <fstream>
#include <iterator>
#include <sstream>
#include <string>

#include "agentaudit.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "jsonparse.hpp"

namespace {

std::string slurp(const std::string& path) {
	std::ifstream f(path);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

} // namespace

/* ---- maskSecretsInText ---- */

TH_TEST(agentaudit_mask_shadows_sensitive_assignment) {
	const std::string out = bot::agent::maskSecretsInText(
		"BOT4CJ_LLM_KEY=sk-abc123 curl -s http://x");
	TH_CHECK(out.find("BOT4CJ_LLM_KEY=***") != std::string::npos);
	TH_CHECK(out.find("sk-abc123") == std::string::npos);
	/* 连字符复合名（api-key）按整词切词同样命中 */
	const std::string out2 = bot::agent::maskSecretsInText("api-key=verysecret run");
	TH_CHECK(out2.find("api-key=***") != std::string::npos);
	TH_CHECK(out2.find("verysecret") == std::string::npos);
	/* Authorization 头形态（遮蔽专用词：不进环境清洗名单，只对文本有意义） */
	const std::string out3 = bot::agent::maskSecretsInText(
		"curl -H \"Authorization: Bearer sk-tok\" http://x");
	TH_CHECK(out3.find("sk-tok") == std::string::npos);
}

/* 形态四：JSON 引号键 `"name": value`（2026-10-08 审计 P1 续发现）。
 * 本仓真实密钥落盘形态（mybot.llm.json、会话 JSONL）恰恰是这种带引号的键名，
 * 旧实现的标识符扫描在遇到键名前导的 `"` 时根本进不了识别分支——意味着
 * `run_command "cat mybot.llm.json"` 从 2026-09-23 G1 起就从未真正遮蔽过这类
 * 密钥，只是没人拿真实 JSON 内容去测过。这里直接钉住真实配置文件的形态。 */
TH_TEST(agentaudit_mask_covers_json_quoted_keys) {
	/* 无空格、紧凑 JSON（真实落盘形态之一） */
	const std::string out = bot::agent::maskSecretsInText(
		"{\"api_key\":\"sk-realsecret123\"}");
	TH_CHECK(out.find("sk-realsecret123") == std::string::npos);
	TH_CHECK(out.find("\"api_key\":***") != std::string::npos);

	/* 带空格（mybot.llm.json.example 的实际排版：`"api_key": "sk-...",`） */
	const std::string out2 = bot::agent::maskSecretsInText(
		"  \"api_key\": \"sk-ThisIsARealSecretKey123\",\n");
	TH_CHECK(out2.find("sk-ThisIsARealSecretKey123") == std::string::npos);
	TH_CHECK(out2.find("\"api_key\": ***") != std::string::npos);
	/* 键名本身原样保留（模型要知道"是哪个字段被遮了"，不是整行消失） */
	TH_CHECK(out2.find("\"api_key\"") != std::string::npos);

	/* 连字符键名（api-key）与整词切词同判据，同样命中 */
	TH_CHECK(bot::agent::maskSecretsInText("\"api-key\": \"hyphen-secret\"")
		.find("hyphen-secret") == std::string::npos);

	/* 冒号前带空格（`"token" : "x"`）也要认得 */
	TH_CHECK(bot::agent::maskSecretsInText("\"token\" : \"spaced\"")
		.find("spaced") == std::string::npos);

	/* 非敏感键名不受牵连：model/note 等普通字段逐字保留 */
	const std::string plain = "\"model\": \"gpt-4\", \"note\": \"just text\"";
	TH_CHECK(bot::agent::maskSecretsInText(plain) == plain);

	/* 引号键但不跟冒号（不是键值对，是普通带引号的词）不触发遮蔽 */
	TH_CHECK(bot::agent::maskSecretsInText("the \"api_key\" field")
		== "the \"api_key\" field");
}

TH_TEST(agentaudit_mask_spares_unrelated_names_and_plain_text) {
	/* KEYSTONE/MONKEY 不含敏感整词，不得误伤（与环境清洗同一判据） */
	TH_CHECK(bot::agent::maskSecretsInText("KEYSTONE=abc MONKEY=x echo hi")
		== "KEYSTONE=abc MONKEY=x echo hi");
	/* 值边界：引号与空白结束值，之后的文本保持原样 */
	const std::string out = bot::agent::maskSecretsInText("token=\"abc def\" tail");
	TH_CHECK(out.find("token=***") != std::string::npos);
	TH_CHECK(out.find(" tail") != std::string::npos);
	/* 没有赋值形态的普通命令逐字保留 */
	const std::string plain = "systemctl status mybot --no-pager";
	TH_CHECK(bot::agent::maskSecretsInText(plain) == plain);
	/* 标识符后不是 '='（如命令 flag -H）不算「名字=值」 */
	TH_CHECK(bot::agent::maskSecretsInText("curl -H x") == "curl -H x");
}

TH_TEST(agentaudit_mask_covers_quoted_values) {
	/* 2026-09-24 审计 H1：值以引号开头（shell 常见形态）时旧实现的 isSep 在
	 * 首字符即刻命中，掩蔽区为空——密钥留在明文里。整个引号值（含定界引号）
	 * 必须一并遮蔽；旧用例只断言了 `token=***` 与尾部子串，泄漏恰好夹在中间。 */
	const std::string out = bot::agent::maskSecretsInText(
		"export BOT4CJ_LLM_KEY=\"sk-abc123\" curl http://x");
	TH_CHECK(out.find("sk-abc123") == std::string::npos);
	TH_CHECK(out.find("BOT4CJ_LLM_KEY=***") != std::string::npos);
	/* 单引号同理 */
	TH_CHECK(bot::agent::maskSecretsInText("api-key='verysecret' run")
		.find("verysecret") == std::string::npos);
	/* 未闭合引号：遮到串尾（宁可多遮不可漏遮） */
	TH_CHECK(bot::agent::maskSecretsInText("token=\"abc").find("abc")
		== std::string::npos);
	/* 引号拼接段（shell 连接语义 "a"b'c' 整体是一个值）全部吃掉 */
	const std::string out2 = bot::agent::maskSecretsInText("api-key=\"a\"b'c' tail");
	TH_CHECK(out2.find("\"a\"") == std::string::npos);
	TH_CHECK(out2.find("b'c'") == std::string::npos);
	TH_CHECK(out2.find(" tail") != std::string::npos);
	/* Bearer 令牌带引号（形态二/三的两级遮蔽都要吃掉引号值） */
	const std::string out3 = bot::agent::maskSecretsInText("Bearer \"sk-tok\" x");
	TH_CHECK(out3.find("sk-tok") == std::string::npos);
	const std::string out4 = bot::agent::maskSecretsInText(
		"Authorization: \"Basic dXNlcjpwYXNz\" tail");
	TH_CHECK(out4.find("dXNlcjpwYXNz") == std::string::npos);
	const std::string out5 = bot::agent::maskSecretsInText(
		"Authorization: Bearer 'sk-tok'");
	TH_CHECK(out5.find("sk-tok") == std::string::npos);
	/* 值后（闭合引号之后）的正常文本不受牵连 */
	const std::string out6 = bot::agent::maskSecretsInText("token=\"abc\" tail");
	TH_CHECK(out6 == "token=*** tail");
}

/* ---- fingerprint64 ---- */

TH_TEST(agentaudit_fingerprint_is_deterministic_and_discriminating) {
	const std::string a = bot::agent::fingerprint64("data:image/jpeg;base64,AAAA");
	const std::string b = bot::agent::fingerprint64("data:image/jpeg;base64,AAAA");
	const std::string c = bot::agent::fingerprint64("data:image/jpeg;base64,AAAB");
	TH_CHECK(a == b);			/* 同输入同指纹（对账靠它） */
	TH_CHECK(a != c);			/* 不同输入不同指纹 */
	TH_CHECK(a.size() == 16);		/* 64 bit → 16 hex 字符 */
}

/* ---- AuditLog ---- */

TH_TEST(agentaudit_writes_jsonl_with_core_fields_and_no_image_payload) {
	fx::TempDir tmp("audit");
	const std::string path = (tmp.path() / "audit.jsonl").string();
	bot::agent::AuditLog log;
	std::string err;
	TH_CHECK_MSG(log.open(path, err), err);

	bot::agent::AuditEntry e;
	e.turn = 2;
	e.tool = "capture_image";
	e.ok = true;
	e.ms = 43;
	e.bytes = 64;
	e.imageBytes = 1024;
	e.imageFp = bot::agent::fingerprint64("data:image/jpeg;base64,/9j/xxxx");
	log.write(e);
	log.write(e);	/* 第二条：同会话 id 应一致 */

	const std::string text = slurp(path);
	std::istringstream ss(text);
	std::string line;
	int lines = 0;
	std::string firstSession;
	while (std::getline(ss, line)) {
		if (line.empty()) { continue; }
		++lines;
		/* 每行都必须是合法 JSON 且核心字段齐备——审计行不可解析即失去证据价值 */
		const bot::Json j = bot::parseJson(line);
		TH_CHECK_MSG(j.isObj(), "第 " + std::to_string(lines) + " 行不是 JSON 对象");
		TH_CHECK(j.get("ts") && j.get("ts")->isStr() && !j.get("ts")->getValue().empty());
		TH_CHECK(j.get("tool") && j.get("tool")->getValue() == "capture_image");
		TH_CHECK(j.get("turn") && j.get("turn")->getInt() == 2);
		TH_CHECK(j.get("ok") && j.get("ok")->getBool());
		TH_CHECK(j.get("ms") && j.get("ms")->getInt() == 43);
		TH_CHECK(j.get("bytes") && j.get("bytes")->getInt() == 64);
		TH_CHECK(j.get("image_bytes") && j.get("image_bytes")->getInt() == 1024);
		TH_CHECK(j.get("image_fp") && j.get("image_fp")->isStr());
		if (firstSession.empty()) { firstSession = j.get("session")->getValue(); }
		else { TH_CHECK(j.get("session")->getValue() == firstSession); }
		/* 图片数据本体绝不落盘：这是审计模块的隐私与体积红线 */
		TH_CHECK(line.find("base64") == std::string::npos);
	}
	TH_CHECK(lines == 2);
}

TH_TEST(agentaudit_logs_failures_and_masks_run_command_args) {
	fx::TempDir tmp("auditfail");
	const std::string path = (tmp.path() / "audit.jsonl").string();
	bot::agent::AuditLog log;
	std::string err;
	TH_CHECK_MSG(log.open(path, err), err);

	bot::Json args = bot::JsonObject();
	/* 命令原文的遮蔽发生在派发点（DispatchGate::run，见 agentdispatch），记账层只负责
	 * 如实落盘——这里按派发点产出的形态给参（遮蔽本身由上面的用例钉住）。 */
	args.put("command", bot::JsonString(
		bot::agent::maskSecretsInText("BOT4CJ_LLM_KEY=sk-real curl http://x")));
	args.put("timeout_seconds", bot::JsonInt(10));
	bot::agent::AuditEntry e;
	e.turn = 0;
	e.tool = "run_command";
	e.args = args;
	e.ok = false;
	e.error = "命令执行失败: fork 失败";
	e.ms = 5;
	e.bytes = 40;
	e.exitCode = 1;
	log.write(e);

	const bot::Json j = bot::parseJson(slurp(path));
	TH_CHECK(j.isObj());
	/* 失败也要记（ok=false + error），且命令里的敏感值已被遮蔽 */
	TH_CHECK(j.get("ok") && !j.get("ok")->getBool());
	TH_CHECK(j.get("error") && j.get("error")->getValue().find("fork") != std::string::npos);
	TH_CHECK(j.get("exit_code") && j.get("exit_code")->getInt() == 1);
	const auto cmd = j.get("args");
	TH_CHECK(cmd && cmd->isObj() && cmd->get("command"));
	TH_CHECK(cmd->get("command")->getValue().find("BOT4CJ_LLM_KEY=***") != std::string::npos);
	TH_CHECK(cmd->get("command")->getValue().find("sk-real") == std::string::npos);
	/* 非敏感参数原样保留 */
	TH_CHECK(cmd->get("timeout_seconds") && cmd->get("timeout_seconds")->getInt() == 10);
}

TH_TEST(agentaudit_open_bad_path_fails_before_power_on) {
	bot::agent::AuditLog log;
	std::string err;
	TH_CHECK(!log.open("/nonexistent-dir-for-audit/audit.jsonl", err));
	TH_CHECK(!err.empty());		/* 人话报错（上电前失败，配置错误不碰真机） */
	TH_CHECK(!log.enabled());	/* 打开失败不得进入半开状态 */
}

TH_TEST(agentaudit_stderr_sink_is_enabled_and_session_is_stable) {
	bot::agent::AuditLog log;
	std::string err;
	TH_CHECK_MSG(log.open("-", err), err);
	TH_CHECK(log.enabled());
	TH_CHECK(log.sessionId().size() == 8);
	/* 双开拒绝：一个会话一个落点，静默换文件会让证据链断成两截 */
	TH_CHECK(!log.open("/tmp/another-audit.jsonl", err));
	TH_CHECK(!err.empty());
}

/* ============ SAN-9：会话边界与工具行记录 ============
 * 2026-10-01 批次 A（P1-6）：model 行与 session 的模型侧字段（driver/model/
 * endpoint/api_key_source/resumed）已随 agent 循环迁 Rust 退场——模型轮次的
 * 审计记进 agent 侧文件（agent/src/audit.rs，字段名同源），由 agent_e2e 断言。
 * 本用例钉 C++ 后端侧的活形态：会话头尾各一条 session 记录（只有 status/
 * error/ms/summary），工具行字段**一个不少**（加法演进）。 */
TH_TEST(agentaudit_session_and_tool_records_fields) {
	using namespace bot;
	using namespace bot::agent;
	fx::TempDir tmp("audit-session");
	const std::string path = (tmp.path() / "audit.jsonl").string();

	AuditLog log;
	std::string err;
	TH_CHECK(log.open(path, err));

	/* ① 会话头（start）——由外壳写，这里直接调底层 write 验证形态 */
	{
		AuditEntry e;
		e.kind = "session";
		e.status = "start";
		log.write(e);
	}
	/* ② 既有工具行（字段一个不少） */
	{
		AuditEntry e;
		e.kind = "tool";
		e.turn = 0;
		e.tool = "list_hardware";
		e.ok = true;
		e.ms = 3;
		e.bytes = 64;
		log.write(e);
	}
	/* ③ 会话尾（error） */
	{
		AuditEntry e;
		e.kind = "session";
		e.status = "error";
		e.error = "请求已取消（宿主收到停止信号）";
		log.write(e);
	}

	const std::string raw = slurp(path);
	std::istringstream ss(raw);
	std::string line;
	int nSession = 0, nTool = 0;
	while (std::getline(ss, line)) {
		if (line.empty()) { continue; }
		Json d = parseJson(line);
		const Json* kind = d.find("kind");
		TH_CHECK(kind != nullptr && kind->isStr());	/* 每行都有 kind */
		const std::string k = kind->getValue();
		if (k == "session") {
			++nSession;
			TH_CHECK(d.find("status") != nullptr);
			/* 会话记录**不带**工具字段（避免 fake 语义：tool 为空串），
			 * 也不带已迁 Rust 的模型侧字段（它们不该再出现） */
			TH_CHECK(d.find("tool") == nullptr);
			TH_CHECK(d.find("driver") == nullptr);
			TH_CHECK(d.find("endpoint") == nullptr);
			TH_CHECK(d.find("api_key_source") == nullptr);
			TH_CHECK(d.find("resumed") == nullptr);
		} else if (k == "tool") {
			++nTool;
			/* 既有工具行字段一个不少 */
			TH_CHECK(d.find("turn") != nullptr);
			TH_CHECK(d.find("tool") != nullptr);
			TH_CHECK(d.find("ok") != nullptr);
			TH_CHECK(d.find("ms") != nullptr);
			TH_CHECK(d.find("bytes") != nullptr);
		} else {
			TH_CHECK_MSG(false, "未知 kind: " + k);
		}
	}
	TH_CHECK(nSession == 2);
	TH_CHECK(nTool == 1);
}

/* SAN-9 兼容性钉子：老消费方按工具字段过滤，结果必须与"没有新记录类型"时一致。
 * 判据是**过滤器语义不变**：`tool == "x"` 只会命中工具行，不会误命中 session
 * 记录（它的 tool 字段根本不出现）。 */
TH_TEST(agentaudit_legacy_tool_filter_still_selects_only_tool_rows) {
	using namespace bot;
	using namespace bot::agent;
	fx::TempDir tmp("audit-compat");
	const std::string path = (tmp.path() / "audit.jsonl").string();
	AuditLog log;
	std::string err;
	TH_CHECK(log.open(path, err));

	AuditEntry s;
	s.kind = "session";
	s.status = "start";
	log.write(s);
	AuditEntry t;
	t.kind = "tool";
	t.tool = "run_command";
	t.exitCode = 0;
	log.write(t);

	/* 模拟老消费方的过滤表达式语义：只看带 tool 字段且值匹配的行 */
	std::istringstream ss(slurp(path));
	std::string line;
	int matched = 0, parsed = 0;
	while (std::getline(ss, line)) {
		if (line.empty()) { continue; }
		Json d = parseJson(line);
		++parsed;
		const Json* tool = d.find("tool");
		if (tool != nullptr && tool->isStr() && tool->getValue() == "run_command") { ++matched; }
	}
	TH_CHECK(parsed == 2);
	TH_CHECK_MSG(matched == 1, "老过滤表达式只应命中那一条工具行，实际 " + std::to_string(matched));
}

TH_TEST(agentaudit_tool_request_id_is_additive_opt_in) {
	using namespace bot;
	using namespace bot::agent;
	fx::TempDir tmp("audit-request-id");
	const std::string path = (tmp.path() / "audit.jsonl").string();
	AuditLog log;
	std::string err;
	TH_CHECK(log.open(path, err));

	AuditEntry withId;
	withId.tool = "list_hardware";
	withId.requestId = "mcp-42";
	log.write(withId);
	AuditEntry without;
	without.tool = "query_sql";
	log.write(without);

	std::istringstream ss(slurp(path));
	std::string line;
	int idx = 0;
	while (std::getline(ss, line)) {
		if (line.empty()) { continue; }
		Json d = parseJson(line);
		if (idx == 0) {
			const Json* id = d.find("requestId");
			TH_CHECK(id != nullptr && id->isStr());
			if (id != nullptr) { TH_CHECK(id->getValue() == "mcp-42"); }
		} else {
			TH_CHECK(d.find("requestId") == nullptr);
		}
		++idx;
	}
	TH_CHECK(idx == 2);
}

/* G2（2026-09-23）：工具自报的生效摘要落进工具行的 summary 字段（apply_sql 等
 * 热插/高危操作靠它对账"这次到底改了什么"）。只做加法：不给 summary 的老工具
 * 行不出现该键，既有消费方逐字节不变。 */
TH_TEST(agentaudit_tool_summary_is_additive_opt_in) {
	using namespace bot;
	using namespace bot::agent;
	fx::TempDir tmp("audit-summary");
	const std::string path = (tmp.path() / "audit.jsonl").string();
	AuditLog log;
	std::string err;
	TH_CHECK(log.open(path, err));

	AuditEntry withSummary;
	withSummary.tool = "apply_sql";
	withSummary.summary = "已生效：新增硬件变量 1 个，既有表追加 1 行";
	log.write(withSummary);

	AuditEntry without;
	without.tool = "list_hardware";
	log.write(without);

	std::istringstream ss(slurp(path));
	std::string line;
	int idx = 0;
	while (std::getline(ss, line)) {
		if (line.empty()) { continue; }
		Json d = parseJson(line);
		if (idx == 0) {
			const Json* s = d.find("summary");
			TH_CHECK_MSG(s != nullptr && s->isStr(), "apply_sql 行应带 summary");
			TH_CHECK(s->getValue().find("已生效") != std::string::npos);
		} else {
			TH_CHECK_MSG(d.find("summary") == nullptr, "无摘要的工具行不应出现 summary 键");
		}
		++idx;
	}
	TH_CHECK(idx == 2);
}
