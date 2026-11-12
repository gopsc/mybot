/* test_llmconfig.cpp —— 配置文件解析层：LlmFileConfig 字段白名单/类型/值域
 *
 * 2026-10-04 按域拆分（行为保持）：原 test_llmconfig.cpp 918 行累积了三个不
 * 相关的域，现拆成三个 TU（断言与正文逐字保持，仅搬迁）——
 *   本文件：loadLlmConfigFile 纯解析层（字段白名单、类型、值域、坏文件、
 *           H1 camera_src_dir 白名单根）；
 *   test_llmconfig_assembly.cpp：buildAgentConfig 的优先级合并、工具门控、
 *           MCP 后端策略要求、--llm-config 查找链；
 *   test_llmconfig_surface.cpp：可观测/安全面（摘要脱敏、磁盘内容定界、
 *           超限报错归因、on-disconnect 预检、动作脚本超时往返、模板自检）。
 * 共用的 writeFile/NoKeyEnv/baseOptions 原为本文件匿名命名空间私有件，
 * 三个 TU 各留一份（搬迁不新增跨 TU 契约，与 harness 系列拆分同惯例）。
 */
#include "fixtures.hpp"
#include "harness.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>
#include <unistd.h>

#include "agentmode.hpp"
#include "llmconfig.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;
using fx::TempDir;
using fx::EnvVar;

namespace {

void writeFile(const fs::path& p, const std::string& content, fs::perms mode) {
	std::ofstream f(p, std::ios::binary);
	f << content;
	f.close();
	std::error_code ec;
	fs::permissions(p, mode, ec);
}

/* 清空整条密钥链，让「密钥来自哪里」在用例里是确定的 */
struct NoKeyEnv {
	EnvVar a{"BOT4CJ_LLM_KEY", nullptr};
	EnvVar b{"ROBOT_AGENT_API_KEY", nullptr};
	EnvVar c{"DEEPSEEK_API_KEY", nullptr};
	EnvVar d{"BOT4CJ_LLM_CONFIG", nullptr};
	EnvVar e{"BOT4CJ_LLM_ENDPOINT", nullptr};
	EnvVar f{"BOT4CJ_LLM_MODEL", nullptr};
};

CliOptions baseOptions(const std::string& configPath) {
	CliOptions o;
	o.agent.enabled = true;
	o.robot = std::string("./robots/relay-test.sql");
	o.agent.llmConfig = configPath;
	return o;
}

} // namespace

TH_TEST(llmconfig_parses_all_fields) {
	/* 批次 2（2026-10-01）：模型侧字段（driver/var/endpoint/model/api_key/采样/
	 * 预算/重试/提示词包/会话）只经白名单**不解析**——本结构只落后端消费面。
	 * fixture 同时含两端键：模型侧键必须不拒（两端共用一份文件），本侧消费的
	 * 键必须照常解析。 */
	TempDir tmp("all");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({
	  "driver": "LlmDeepSeek",
	  "var": "brain",
	  "endpoint": "https://api.deepseek.com/chat/completions",
	  "model": "deepseek-chat",
	  "api_key": "sk-inline",
	  "api_key_file": "/tmp/ignored.key",
	  "timeout": 42,
	  "max_tokens": 2048,
	  "temperature": 0.3,
	  "top_p": 0.8,
	  "reasoning_effort": "low",
	  "thinking": "disabled",
	  "max_turns": 12,
	  "max_task_seconds": 1234,
	  "max_history_bytes": 8388608,
	  "max_calls_per_round": 32,
	  "max_retries": 6,
	  "retry_backoff_ms": 0,
	  "prompt_files": ["prompts/a"],
	  "stream": false,
	  "history_summary": true,
	  "max_summary_bytes": 4096,
	  "scripts_dir": "scripts/test",
	  "allow_shell": false,
	  "run_command_timeout_sec": 30,
	  "run_command_max_timeout_sec": 120,
	  "action_script_timeout_sec": 0
	})", fs::perms::owner_read | fs::perms::owner_write);

	LlmFileConfig c;
	std::string err;
	TH_CHECK(loadLlmConfigFile(cfg.string(), c, err));
	TH_CHECK(err.empty());
	/* 后端消费面照常解析 */
	TH_CHECK(c.scriptsDir && *c.scriptsDir == "scripts/test");
	TH_CHECK(c.allowShell && !*c.allowShell);
	TH_CHECK(c.runCommandTimeoutSec && *c.runCommandTimeoutSec == 30);
	TH_CHECK(c.runCommandMaxTimeoutSec && *c.runCommandMaxTimeoutSec == 120);
	TH_CHECK(c.actionScriptTimeoutSec && *c.actionScriptTimeoutSec == 0);
}

/* 批次 2（2026-10-01）：模型侧字段的类型/值域由 mybot-agent 的 config.rs 校验，
 * C++ 侧只经白名单——同一份文件里有（Rust 会拒的）坏值时，后端不得拒绝加载
 * （拒绝它的权限在 agent 那侧，不在后端）。「未知字段仍拒」的拼错防线不受影响。 */
TH_TEST(llmconfig_model_side_fields_pass_through_unchecked) {
	struct Case { const char* json; };
	const Case ok[] = {
		{R"({"max_history_bytes":-1})"},
		{R"({"max_history_bytes":99999999999})"},
		{R"({"max_task_image_bytes":1.5})"},
		{R"({"max_task_tool_result_bytes":true})"},
		{R"({"max_calls_per_round":0})"},
		{R"({"max_calls_per_round":1025})"},
		{R"({"max_retries":-1})"},
		{R"({"retry_backoff_ms":1.5})"},
		{R"({"endpoint":123})"},
		{R"({"timeout":"30"})"},
		{R"({"temperature":3})"},
		{R"({"temperature":"0.5"})"},
		{R"({"max_turns":0})"},
		{R"({"thinking":{}})"},
		{R"({"api_key_file":7})"},
		{R"({"prompt_files":"prompts/a"})"},
		{R"({"prompt_files":[1]})"},
		{R"({"max_tokens":1e300})"},
	};
	int n = 0;
	for (const auto& cse : ok) {
		TempDir d("passthrough");
		fs::path p = d.path() / ("m" + std::to_string(n++) + ".json");
		writeFile(p, cse.json, fs::perms::owner_all);
		LlmFileConfig c;
		std::string err;
		TH_CHECK_MSG(loadLlmConfigFile(p.string(), c, err),
			std::string(cse.json) + " 应只登记不校验，却拒了: " + err);
	}
	/* 拼错的名字仍按未知字段拒绝——白名单不覆盖拼错形态 */
	TempDir d2("passthrough-typo");
	fs::path typo = d2.path() / "typo.json";
	writeFile(typo, R"({"max_retry":3})", fs::perms::owner_all);
	LlmFileConfig c2;
	std::string e2;
	TH_CHECK(!loadLlmConfigFile(typo.string(), c2, e2));
	TH_CHECK(e2.find("未知字段") != std::string::npos);
}

TH_TEST(llmconfig_runtime_fields_parse_and_reject) {
	/* 后端消费的工具层数值：合法值全收；越界/非整数一律拒并点名 */
	TempDir tmp("runtime");
	fs::path cfg = tmp.path() / "ok.json";
	writeFile(cfg, R"({
	  "run_command_timeout_sec": 30,
	  "run_command_max_timeout_sec": 120,
	  "action_script_timeout_sec": 0
	})", fs::perms::owner_all);
	LlmFileConfig c;
	std::string err;
	TH_CHECK_MSG(loadLlmConfigFile(cfg.string(), c, err), err);
	TH_CHECK(c.runCommandTimeoutSec && *c.runCommandTimeoutSec == 30);
	TH_CHECK(c.runCommandMaxTimeoutSec && *c.runCommandMaxTimeoutSec == 120);
	TH_CHECK(c.actionScriptTimeoutSec && *c.actionScriptTimeoutSec == 0);

	struct Case { const char* json; const char* field; };
	const Case bad[] = {
		{R"({"run_command_timeout_sec":0})", "run_command_timeout_sec"},
		{R"({"run_command_timeout_sec":601})", "run_command_timeout_sec"},
		{R"({"run_command_max_timeout_sec":3601})", "run_command_max_timeout_sec"},
		{R"({"run_command_max_timeout_sec":true})", "run_command_max_timeout_sec"},
		{R"({"action_script_timeout_sec":-1})", "action_script_timeout_sec"},
		{R"({"action_script_timeout_sec":3601})", "action_script_timeout_sec"},
	};
	int n = 0;
	for (const auto& b : bad) {
		fs::path p = tmp.path() / ("bad" + std::to_string(n++) + ".json");
		writeFile(p, b.json, fs::perms::owner_all);
		LlmFileConfig o;
		std::string e;
		TH_CHECK(!loadLlmConfigFile(p.string(), o, e));
		TH_CHECK_MSG(e.find(b.field) != std::string::npos, b.json);
	}
}

/* ================= H1：capture_image 白名单根的配置面 =================
 * camera_src_dir 决定"能读哪个目录"，等价于放宽读权限，故与 allow_shell 同判据：
 * **只能命令行给**，配置文件写它一律拒绝加载并指名原因。camera_src 本身仍可由
 * 配置文件给，但它不再参与推导根（来源标记为 false），否则一份落在 CWD 的
 * ./mybot.llm.json 就能把任意文件 base64 读进模型上下文。 */
TH_TEST(agentconfig_camera_src_dir_is_cli_only) {
	NoKeyEnv nokey;
	EnvVar key{"BOT4CJ_LLM_KEY", "test-key"};
	TempDir tmp("camdir");

	/* 1) 配置文件写 camera_src_dir → 拒绝加载，报错点名命令行选项 */
	{
		fs::path cfg = tmp.path() / "cam.json";
		writeFile(cfg, R"({"api_key":"k","camera_src_dir":"/etc"})", fs::perms::owner_all);
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(baseOptions(cfg.string()), out, err));
		TH_CHECK_MSG(err.find("camera_src_dir") != std::string::npos,
			"报错应点名字段: " + err);
		TH_CHECK_MSG(err.find("--camera-src-dir") != std::string::npos,
			"报错应给出正确入口: " + err);
	}
	/* 2) 命令行给 → 落到 cameraSrcDir */
	{
		CliOptions o = baseOptions("none");
		o.agent.cameraSrcDir = "/opt/pics";
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
		TH_CHECK(out.cameraSrcDir == "/opt/pics");
	}
	/* 3) 来源标记：命令行给的 camera_src 才允许推导根 */
	{
		CliOptions o = baseOptions("none");
		o.agent.cameraSrc = "/opt/pics/a.jpg";
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
		TH_CHECK(out.cameraSrc == "/opt/pics/a.jpg");
		TH_CHECK_MSG(out.cameraSrcFromCli, "命令行来源应标记为 true");
	}
	{
		fs::path cfg = tmp.path() / "src.json";
		writeFile(cfg, R"({"api_key":"k","camera_src":"/etc/shadow"})", fs::perms::owner_all);
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(baseOptions(cfg.string()), out, err), err);
		TH_CHECK(out.cameraSrc == "/etc/shadow");
		TH_CHECK_MSG(!out.cameraSrcFromCli,
			"配置文件来源必须是 false（否则白名单根会被它自己推导出来 = H1）");
		TH_CHECK_MSG(out.cameraSrcDir.empty(), "没有命令行就不该有显式根");
	}
}

TH_TEST(llmconfig_partial_file_leaves_fields_unset) {
	TempDir tmp("partial");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"scripts_dir":"myscripts"})", fs::perms::owner_all);

	LlmFileConfig c;
	std::string err;
	TH_CHECK(loadLlmConfigFile(cfg.string(), c, err));
	TH_CHECK(c.scriptsDir && *c.scriptsDir == "myscripts");
	TH_CHECK(!c.auditLog);		/* 未配置 = 交给下一层 */
	TH_CHECK(!c.agentPolicy);
	TH_CHECK(!c.allowShell);
	TH_CHECK(!c.runCommandTimeoutSec);
}

TH_TEST(llmconfig_empty_strings_mean_unset) {
	TempDir tmp("empty");
	fs::path cfg = tmp.path() / "llm.json";
	/* 示例配置常留空占位：空串必须按「未配置」处理，否则 audit_log 会被压成
	 * 空落点（空串本来表示"不记录"）、camera_device 会变成「空设备名」 */
	writeFile(cfg, R"({
	  "scripts_dir": "", "audit_log": "", "agent_policy": "",
	  "camera_var": "", "camera_device": "", "camera_src": ""
	})", fs::perms::owner_all);

	LlmFileConfig c;
	std::string err;
	TH_CHECK(loadLlmConfigFile(cfg.string(), c, err));
	TH_CHECK(!c.scriptsDir);
	TH_CHECK(!c.auditLog);
	TH_CHECK(!c.agentPolicy);
	TH_CHECK(!c.cameraVar);
	TH_CHECK(!c.cameraDevice);
	TH_CHECK(!c.cameraSrc);
}

TH_TEST(llmconfig_rejects_unknown_field) {
	TempDir tmp("unknown");
	fs::path cfg = tmp.path() / "llm.json";
	/* 拼错一个键而静默走缺省，会让人以为配置生效了——与「未知 --key 退出 2」同口径 */
	writeFile(cfg, R"({"apikey":"typo"})", fs::perms::owner_all);
	LlmFileConfig c;
	std::string err;
	TH_CHECK(!loadLlmConfigFile(cfg.string(), c, err));
	TH_CHECK(err.find("未知字段") != std::string::npos);
	TH_CHECK(err.find("apikey") != std::string::npos);
}

TH_TEST(llmconfig_rejects_wrong_types) {
	/* 类型错拒的防线只覆盖**本侧消费**字段；模型侧字段见 pass_through 用例 */
	TempDir tmp("types");
	struct Case { const char* json; const char* field; };
	const Case cases[] = {
		{R"({"allow_shell":"yes"})", "allow_shell"},
		{R"({"allow_hot_sql":1})", "allow_hot_sql"},
		{R"({"allow_camera":"yes"})", "allow_camera"},
		{R"({"scripts_dir":["d"]})", "scripts_dir"},
		{R"({"camera_var":7})", "camera_var"},
		{R"({"audit_log":false})", "audit_log"},
		{R"({"read_vars":"relay0"})", "read_vars"},
		{R"({"read_vars":[1]})", "read_vars"},
		{R"({"run_command_timeout_sec":"30"})", "run_command_timeout_sec"},
	};
	int n = 0;
	for (const auto& c : cases) {
		fs::path cfg = tmp.path() / ("t" + std::to_string(n++) + ".json");
		writeFile(cfg, c.json, fs::perms::owner_all);
		LlmFileConfig out;
		std::string err;
		bool ok = loadLlmConfigFile(cfg.string(), out, err);
		TH_CHECK(!ok);
		TH_CHECK(err.find(c.field) != std::string::npos);
	}
}

TH_TEST(llmconfig_rejects_out_of_range) {
	/* 值域拒的防线只覆盖**本侧消费**字段（run_command/action_script 超时）；
	 * 模型侧字段见 pass_through 用例。 */
	TempDir tmp("range");
	struct Case { const char* json; const char* field; };
	const Case cases[] = {
		{R"({"run_command_timeout_sec":0})", "run_command_timeout_sec"},
		{R"({"run_command_timeout_sec":601})", "run_command_timeout_sec"},
		{R"({"run_command_max_timeout_sec":0})", "run_command_max_timeout_sec"},
		{R"({"run_command_max_timeout_sec":3601})", "run_command_max_timeout_sec"},
		{R"({"action_script_timeout_sec":-1})", "action_script_timeout_sec"},
		{R"({"action_script_timeout_sec":3601})", "action_script_timeout_sec"},
		/* P1-5 防线：非有限/超出 int64 的浮点曾直接进 static_cast（UB）。
		 * 现在必须在范围判定处就被拒，绝不能走到转换。 */
		{R"({"run_command_timeout_sec":1e300})", "run_command_timeout_sec"},
	};
	int n = 0;
	for (const auto& c : cases) {
		fs::path cfg = tmp.path() / ("r" + std::to_string(n++) + ".json");
		writeFile(cfg, c.json, fs::perms::owner_all);
		LlmFileConfig out;
		std::string err;
		TH_CHECK(!loadLlmConfigFile(cfg.string(), out, err));
		TH_CHECK(err.find(c.field) != std::string::npos);
	}
}

TH_TEST(llmconfig_rejects_bad_files) {
	LlmFileConfig c;
	std::string err;

	TH_CHECK(!loadLlmConfigFile("/no/such/llm.json", c, err));
	TH_CHECK(err.find("无法打开") != std::string::npos);

	TempDir tmp("bad");
	fs::path empty = tmp.path() / "empty.json";
	writeFile(empty, "", fs::perms::owner_all);
	err.clear();
	TH_CHECK(!loadLlmConfigFile(empty.string(), c, err));
	TH_CHECK(err.find("为空") != std::string::npos);

	fs::path bad = tmp.path() / "bad.json";
	writeFile(bad, "{\"api_key\": }", fs::perms::owner_all);
	err.clear();
	TH_CHECK(!loadLlmConfigFile(bad.string(), c, err));
	TH_CHECK(err.find("不是合法 JSON") != std::string::npos);

	fs::path arr = tmp.path() / "arr.json";
	writeFile(arr, "[1,2]", fs::perms::owner_all);
	err.clear();
	TH_CHECK(!loadLlmConfigFile(arr.string(), c, err));
	TH_CHECK(err.find("顶层必须是 JSON 对象") != std::string::npos);
}

TH_TEST(llmconfig_prompt_files_pass_through) {
	/* 批次 2（2026-10-01）：prompt_files 是模型侧字段——提示词拼装已迁 Rust
	 * （agent/src/prompt.rs），本侧只经白名单不解析（坏形态见 pass_through 用例）。 */
	TempDir tmp("pfcfg");
	fs::path cfg = tmp.path() / "llm.json";
	/* 任意形态都放行（校验在 Rust 侧）；空数组/合法数组只是其中两种 */
	for (const char* body : {
		R"({"prompt_files":["prompts/a","prompts/b"]})",
		R"({"prompt_files":[]})",
		R"({"prompt_files":"prompts/a"})",
	}) {
		writeFile(cfg, body, fs::perms::owner_all);
		LlmFileConfig c;
		std::string err;
		TH_CHECK_MSG(loadLlmConfigFile(cfg.string(), c, err),
			std::string(body) + " 应只登记不校验，却拒了: " + err);
	}
}

TH_TEST(llmconfig_oversized_file_reports_the_limit_not_json) {
	/* ==================== 超限配置文件必须报「过大」而非「不是合法 JSON」
	 * （2026-09-20 重构阶段 0/4.1）====================
	 * 缺陷实证：readWholeFile 读满 cap 就返回、不检查是否还有剩余，把超限文件
	 * 静默截断后交给 JSON 解析器，于是用户看到「不是合法 JSON」——真实成因
	 * （文件过大 / 被截断）完全丢失；api_key_file 同样被静默截断，表现为
	 * 「密钥错误」这种最难查的形态。promptpack 同场景已给出正确范式（响亮拒绝）。
	 * 契约：超过上限时以「上限」类报错拒绝，且不得伪装成 JSON 语法错误。
	 */
	TempDir tmp("oversize");
	fs::path big = tmp.path() / "big.json";
	/* 64 KiB 上限 +1：截断后必然不是合法 JSON，从而暴露旧实现的错误归因 */
	std::string content = "{\"api_key\":\"" + std::string(70 * 1024, 'a') + "\"}";
	writeFile(big, content, fs::perms::owner_all);

	LlmFileConfig c;
	std::string err;
	TH_CHECK(!loadLlmConfigFile(big.string(), c, err));
	TH_CHECK(err.find("不是合法 JSON") == std::string::npos);
	TH_CHECK(err.find("上限") != std::string::npos);
}

TH_TEST(llmconfig_example_template_loads_strictly) {
	/* 模板必须能被自家严格解析器加载：曾含 // 注释导致 `cp example mybot.llm.json`
	 * 首启即「不是合法 JSON」（2026-09-30 审计 P1）。JSON 无注释语法，说明文字
	 * 一律放 docs/agent.md 字段表，本用例钉住模板永不回漂。
	 * 批次 2 后校验面只剩本侧消费字段：模板里全部键（含模型侧）都过白名单，
	 * allow_shell 仍须为 false（只许命令行开）。 */
	NoKeyEnv nokey;
	LlmFileConfig c;
	std::string err;
	TH_CHECK_MSG(loadLlmConfigFile("mybot.llm.json.example", c, err), err);
	/* allow_shell 只许命令行给：模板必须保持 false */
	TH_CHECK(c.allowShell && !*c.allowShell);
}
