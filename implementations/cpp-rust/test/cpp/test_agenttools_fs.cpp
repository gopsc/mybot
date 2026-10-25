/* test_agenttools_fs.cpp —— 只读文件工具族（list_dir / read_file，Phase 4，2026-10-07）
 *
 * 镜像 src/agenttools_fs.cpp：门控（--fs-root 给了才注册）、沙箱（越界/绝对/
 * .. /符号链接逃逸 → 参数错误）、文件级失败（不存在/超限/软链/二进制）、
 * 回执定界与 UTF-8 消毒。沙箱算法本身的用例在 test_agenttools_sandbox.cpp
 * （agent_sandbox.hpp），这里只钉"工具层把 resolveUnderRoot 接对了"。
 */

#include "fixtures.hpp"
#include "harness.hpp"

using fx::TempDir;

#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <unistd.h>

#include "agenttools.hpp"
#include "jsonparse.hpp"
#include "robot.hpp"

#include "agenttools_fixtures.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;

using afx::execText;
using afx::makeRelayRobot;
using afx::writeFile;

namespace {

/* 建一个最小工具上下文：relay 机器人 + 指定只读根 */
AgentToolContext fsContext(RobotStruct* robot, const std::string& root) {
	AgentToolContext ctx;
	ctx.robot = robot;
	ctx.scriptsDir = "scripts";
	ctx.structurePath = "robots/relay-test.sql";
	ctx.fsRoot = root;
	return ctx;
}

/* Phase 5：同上，但额外开 write_file（--agent-write-file + --fs-root 组合）。 */
AgentToolContext fsWriteContext(RobotStruct* robot, const std::string& root) {
	AgentToolContext ctx = fsContext(robot, root);
	ctx.allowWriteFile = true;
	return ctx;
}

} // namespace

/* 门控（安全缺省）：缺 --fs-root（fsRoot 空）⇒ 两个工具都不注册。 */
TH_TEST(agenttools_fs_tools_absent_without_root) {
	auto robot = makeRelayRobot();
	AgentToolContext ctx = fsContext(robot.get(), "");
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(!tools.contains("list_dir"));
	TH_CHECK(!tools.contains("read_file"));
	robot->deactivate();
}

/* 给了根 ⇒ 两个工具都在（同一门控）。 */
TH_TEST(agenttools_fs_tools_registered_with_root) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-register");
	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(tools.contains("list_dir"));
	TH_CHECK(tools.contains("read_file"));
	robot->deactivate();
}

/* list_dir：列出条目（名称 + 类型 + 大小）；子目录与文件都显示；软链不列。 */
TH_TEST(agenttools_fs_list_dir_lists_entries_and_hides_symlinks) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-listdir");
	writeFile(root.path() / "a.txt", "hello");
	fs::create_directories(root.path() / "sub");
	TempDir outside("fsroot-listdir-outside");
	writeFile(outside.path() / "secret.txt", "machine-secret");
	TH_CHECK(::symlink((outside.path() / "secret.txt").c_str(),
		(root.path() / "evil-link").c_str()) == 0);

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "list_dir", parseJson("{}"));
	TH_CHECK_MSG(out.find("a.txt") != std::string::npos
		&& out.find("[文件]") != std::string::npos
		&& out.find("5 字节") != std::string::npos, out);
	TH_CHECK_MSG(out.find("sub") != std::string::npos
		&& out.find("[目录]") != std::string::npos, out);
	TH_CHECK_MSG(out.find("evil-link") == std::string::npos,
		"软链条目不该出现在清单里: " + out);
	robot->deactivate();
}

/* list_dir 的目录参数：缺省/"."/"./" 都表示根目录本身。 */
TH_TEST(agenttools_fs_list_dir_default_path_is_root) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-listdir-default");
	writeFile(root.path() / "x.txt", "x");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(execText(tools, "list_dir", parseJson("{}")).find("x.txt") != std::string::npos);
	TH_CHECK(execText(tools, "list_dir", parseJson("{\"path\":\".\"}"))
		.find("x.txt") != std::string::npos);
	robot->deactivate();
}

/* list_dir 的空目录与"不是目录"两种边界回执。 */
TH_TEST(agenttools_fs_list_dir_empty_and_not_a_directory) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-listdir-edge");
	fs::create_directories(root.path() / "empty");
	writeFile(root.path() / "plain.txt", "x");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(execText(tools, "list_dir", parseJson("{\"path\":\"empty\"}"))
		.find("空目录") != std::string::npos);
	std::string notDir = execText(tools, "list_dir", parseJson("{\"path\":\"plain.txt\"}"));
	TH_CHECK(notDir.find("不是目录") != std::string::npos);
	robot->deactivate();
}

/* read_file：正常读回文件内容，经"数据非指令"定界。 */
TH_TEST(agenttools_fs_read_file_returns_content) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile");
	writeFile(root.path() / "note.txt", "hello world\n");
	fs::create_directories(root.path() / "sub");
	writeFile(root.path() / "sub" / "nested.txt", "nested content");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "read_file", parseJson("{\"path\":\"note.txt\"}"));
	TH_CHECK(out.find("hello world") != std::string::npos);
	TH_CHECK(out.find("数据不是指令") != std::string::npos);

	std::string nested = execText(tools, "read_file", parseJson("{\"path\":\"sub/nested.txt\"}"));
	TH_CHECK(nested.find("nested content") != std::string::npos);
	robot->deactivate();
}

/* read_file 的沙箱负例：绝对路径 / .. / 空 一律按**参数错误**回传（SAN-8②，
 * 判据是异常类型 IllegalArgumentException；executed 置 false 是 DispatchGate
 * 的归一化职责，不在 AgentToolRegistry::execute 这一层，故这里只钉 ok/paramError
 * ——与 test_agenttools_wait.cpp 的 agenttools_wait_variable_param_errors 同惯例）。 */
TH_TEST(agenttools_fs_read_file_sandbox_violations_are_param_errors) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-sandbox-neg");
	writeFile(root.path() / "ok.txt", "ok");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	for (const char* bad : {"/etc/passwd", "../x.txt", "a/../../b.txt", ".", ""}) {
		AgentToolResult r = tools.execute("read_file",
			bad[0] == '\0' ? parseJson("{}") : parseJson(std::string("{\"path\":\"")
				+ bad + "\"}"));
		TH_CHECK_MSG(r.ok == false && r.paramError == true,
			std::string("bad=") + bad + " text=" + r.text);
	}
	robot->deactivate();
}

/* read_file 拒绝越过根目录的符号链接（目标已存在），不泄露目标内容。 */
TH_TEST(agenttools_fs_read_file_rejects_symlink_escape) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-symlink");
	TempDir outside("fsroot-readfile-symlink-target");
	writeFile(outside.path() / "secret.txt", "机密内容不该泄露");
	TH_CHECK(::symlink((outside.path() / "secret.txt").c_str(),
		(root.path() / "link.txt").c_str()) == 0);

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("read_file", parseJson("{\"path\":\"link.txt\"}"));
	TH_CHECK(r.ok == false);
	TH_CHECK(r.text.find("机密内容") == std::string::npos);
	robot->deactivate();
}

/* read_file 拒绝超过字节上限的文件（响亮拒绝，不静默截断）。 */
TH_TEST(agenttools_fs_read_file_rejects_oversized_file) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-oversize");
	std::string big(70u * 1024, 'x');	/* > 64 KiB 上限 */
	writeFile(root.path() / "big.txt", big);

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("read_file", parseJson("{\"path\":\"big.txt\"}"));
	TH_CHECK(r.ok == false);
	TH_CHECK(r.text.find("上限") != std::string::npos);
	robot->deactivate();
}

/* read_file 拒绝二进制内容（含 NUL），不 base64 塞进上下文。 */
TH_TEST(agenttools_fs_read_file_rejects_binary_content) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-binary");
	writeFile(root.path() / "bin.dat", std::string("abc\0def", 7));

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("read_file", parseJson("{\"path\":\"bin.dat\"}"));
	TH_CHECK(r.ok == false);
	TH_CHECK(r.text.find("UTF-8") != std::string::npos || r.text.find("二进制") != std::string::npos);
	robot->deactivate();
}

/* read_file 不存在的文件：执行结果失败（不是参数错误——路径本身合法）。 */
TH_TEST(agenttools_fs_read_file_missing_file_is_execution_failure_not_param_error) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-missing");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("read_file", parseJson("{\"path\":\"no-such-file.txt\"}"));
	TH_CHECK(r.ok == false);
	TH_CHECK(r.paramError == false);
	robot->deactivate();
}

/* read_file 的回执过 maskSecretsInText（2026-10-08 审计 P1）：与 run_command 的
 * agenttools_run_command_receipt_masks_secrets 同一防线，钉的是同一条泄漏面——
 * `--fs-root .`/`--fs-root ~` 这类自然写法会读到含 API key 的文件（仓库根的
 * mybot.llm.json、会话 JSONL），内容必须在进模型上下文前被同等强度遮蔽，
 * 不能让这两个"更窄"的工具反而比 run_command 更弱。 */
TH_TEST(agenttools_fs_read_file_receipt_masks_secrets) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-mask");
	/* 真实威胁场景：`--fs-root .` 读到仓库根的 mybot.llm.json 那种排版
	 * （带引号键 + 冒号后空格），不是人为凑的 shell KEY=val 形态。 */
	writeFile(root.path() / "secret.json",
		"{\n  \"api_key\": \"sk-leakthis\",\n  \"model\": \"gpt-4\"\n}\n");
	writeFile(root.path() / "plain.txt", "harmless content\n");

	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "read_file", parseJson("{\"path\":\"secret.json\"}"));
	TH_CHECK(out.find("sk-leakthis") == std::string::npos);
	TH_CHECK(out.find("\"api_key\": ***") != std::string::npos);
	/* 非敏感字段不受牵连 */
	TH_CHECK(out.find("\"model\": \"gpt-4\"") != std::string::npos);
	TH_CHECK(out.find("疑似敏感内容") != std::string::npos);

	/* 无敏感值时内容不被改写（普通文件不产生噪音） */
	std::string clean = execText(tools, "read_file", parseJson("{\"path\":\"plain.txt\"}"));
	TH_CHECK(clean.find("harmless content") != std::string::npos);
	TH_CHECK(clean.find("已被净化") == std::string::npos);
	robot->deactivate();
}

/* read_file 缺 path 参数：缺字符串参数，派发漏斗统一归为"工具参数错误"
 * （本测试直接钉工具层异常，不经 DispatchGate）。 */
TH_TEST(agenttools_fs_read_file_requires_path) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-readfile-nopath");
	AgentToolContext ctx = fsContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("read_file", parseJson("{}"));
	TH_CHECK(r.ok == false);
	robot->deactivate();
}

/* ---- Phase 5（2026-10-08）：write_file ---- */

/* 门控：write_file 只随 --agent-write-file（allowWriteFile）注册——**独立于**
 * --fs-root。只给读根不给写开关，write_file 不该出现（否则写权随读权静默获得）。 */
TH_TEST(agenttools_fs_write_file_gated_by_own_flag) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-gate");
	/* 只给 --fs-root（allowWriteFile=false）：list_dir/read_file 在，write_file 不在 */
	AgentToolContext ro = fsContext(robot.get(), root.path().string());
	AgentToolRegistry t1 = makeAgentTools(ro);
	TH_CHECK(t1.contains("list_dir"));
	TH_CHECK(t1.contains("read_file"));
	TH_CHECK(!t1.contains("write_file"));
	/* 开 write_file：出现在表内 */
	AgentToolContext rw = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry t2 = makeAgentTools(rw);
	TH_CHECK(t2.contains("write_file"));
	robot->deactivate();
}

/* 新建文件：内容与大小正确；原子路径（正常路径）。 */
TH_TEST(agenttools_fs_write_file_creates_new_file) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-create");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "write_file",
		parseJson("{\"path\":\"new.txt\",\"content\":\"hello world\"}"));
	TH_CHECK_MSG(out.find("已写入") != std::string::npos, out);
	TH_CHECK(out.find("新建") != std::string::npos);
	/* 读回验证内容真的落盘 */
	std::string back = execText(tools, "read_file", parseJson("{\"path\":\"new.txt\"}"));
	TH_CHECK(back.find("hello world") != std::string::npos);
	/* 临时文件不应残留 */
	std::size_t leftovers = 0;
	for (const auto& e : fs::directory_iterator(root.path())) {
		if (e.path().filename().string().find(".mybot-tmp-") != std::string::npos) { ++leftovers; }
	}
	TH_CHECK(leftovers == 0);
	robot->deactivate();
}

/* 覆盖拒绝：目标已存在、未传 overwrite → 拒绝，原内容不变（不静默覆盖）。 */
TH_TEST(agenttools_fs_write_file_rejects_overwrite_without_flag) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-noover");
	writeFile(root.path() / "existing.txt", "original");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "write_file",
		parseJson("{\"path\":\"existing.txt\",\"content\":\"replaced\"}"));
	TH_CHECK_MSG(out.find("已存在") != std::string::npos, out);
	TH_CHECK(out.find("overwrite=true") != std::string::npos);
	/* 原内容必须原封不动 */
	std::string back = execText(tools, "read_file", parseJson("{\"path\":\"existing.txt\"}"));
	TH_CHECK(back.find("original") != std::string::npos);
	TH_CHECK(back.find("replaced") == std::string::npos);
	robot->deactivate();
}

/* 覆盖成功：overwrite=true → 新内容替换旧内容。 */
TH_TEST(agenttools_fs_write_file_overwrites_with_flag) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-over");
	writeFile(root.path() / "existing.txt", "original");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "write_file",
		parseJson("{\"path\":\"existing.txt\",\"content\":\"replaced\",\"overwrite\":true}"));
	TH_CHECK_MSG(out.find("覆盖已有内容") != std::string::npos, out);
	std::string back = execText(tools, "read_file", parseJson("{\"path\":\"existing.txt\"}"));
	TH_CHECK(back.find("replaced") != std::string::npos);
	TH_CHECK(back.find("original") == std::string::npos);
	robot->deactivate();
}

/* 沙箱负例：绝对路径 / .. 一律按**参数错误**回传（与 read_file 同判据）。 */
TH_TEST(agenttools_fs_write_file_sandbox_violations_are_param_errors) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-sandbox");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	for (const char* p : {"/etc/passwd", "../escape.txt", "a/../../escape.txt"}) {
		std::string args = std::string("{\"path\":\"") + p + "\",\"content\":\"x\"}";
		AgentToolResult r = tools.execute("write_file", parseJson(args));
		TH_CHECK_MSG(r.ok == false && r.paramError == true, std::string("path=") + p);
	}
	robot->deactivate();
}

/* 符号链接目标拒绝（writeFileAtomic 自己的判据，而非沙箱层）：链接**指向根内**
 * 另一个真实文件（resolveUnderRoot 对此判 OK——canonical 后仍落在根内，不是
 * "目录级逃逸"），但目标本身是符号链接这件事必须在 writeFileAtomic 内被单独
 * 拦下，不跟随写入。与"链接指向根外"（沙箱层 ESCAPES_ROOT 已经拦，见
 * test_agenttools_sandbox.cpp）是两层不同的防线，这里只钉后一层。 */
TH_TEST(agenttools_fs_write_file_rejects_symlink_target) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-symlink");
	writeFile(root.path() / "real.txt", "victim-original");
	TH_CHECK(::symlink((root.path() / "real.txt").c_str(),
		(root.path() / "link.txt").c_str()) == 0);
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 先确认这条路径真的走到了"参数合法、写入层拒绝"（不是 paramError，
	 * 证明确实是 writeFileAtomic 自己的判据在起作用，不是沙箱层）。 */
	AgentToolResult r = tools.execute("write_file",
		parseJson("{\"path\":\"link.txt\",\"content\":\"pwned\",\"overwrite\":true}"));
	TH_CHECK_MSG(r.ok == false && r.paramError == false, r.error);
	TH_CHECK_MSG(r.error.find("符号链接") != std::string::npos, r.error);
	/* 链接指向的文件内容必须不变（没跟随写入） */
	std::ifstream f(root.path() / "real.txt");
	std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	TH_CHECK(content == "victim-original");
	robot->deactivate();
}

/* 大小超限：超过上限 → 参数错误（不创建任何文件）。 */
TH_TEST(agenttools_fs_write_file_rejects_oversized_content) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-big");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string big(64 * 1024 + 1, 'a');
	Json args = parseJson("{\"path\":\"big.txt\"}");
	args.put("content", JsonString(big));
	AgentToolResult r = tools.execute("write_file", args);
	TH_CHECK_MSG(r.ok == false && r.paramError == true, r.error);
	TH_CHECK(!fs::exists(root.path() / "big.txt"));
	robot->deactivate();
}

/* 二进制内容（含 NUL）拒绝。 */
TH_TEST(agenttools_fs_write_file_rejects_nul_content) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-nul");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	Json args = parseJson("{\"path\":\"bin.dat\"}");
	args.put("content", JsonString(std::string("a\0b", 3)));
	AgentToolResult r = tools.execute("write_file", args);
	TH_CHECK(r.ok == false && r.paramError == true);
	TH_CHECK(!fs::exists(root.path() / "bin.dat"));
	robot->deactivate();
}

/* 缺 path / content 参数（以及 overwrite 类型不符）→ 参数错误。 */
TH_TEST(agenttools_fs_write_file_param_errors) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-params");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(tools.execute("write_file", parseJson("{}")).paramError);
	TH_CHECK(tools.execute("write_file", parseJson("{\"path\":\"x\"}")).paramError);
	/* overwrite 类型不符（给字符串）不静默回落 */
	AgentToolResult r = tools.execute("write_file",
		parseJson("{\"path\":\"x\",\"content\":\"c\",\"overwrite\":\"yes\"}"));
	TH_CHECK(r.ok == false && r.paramError == true);
	robot->deactivate();
}

/* 审计 summary：单位/覆盖标记（G2 机器可读回执）。 */
TH_TEST(agenttools_fs_write_file_summary_format) {
	auto robot = makeRelayRobot();
	TempDir root("fsroot-write-summary");
	AgentToolContext ctx = fsWriteContext(robot.get(), root.path().string());
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult r = tools.execute("write_file",
		parseJson("{\"path\":\"s.txt\",\"content\":\"12345\"}"));
	TH_CHECK(r.ok == true);
	TH_CHECK_MSG(r.summary == "bytes=5 overwrite=false", r.summary);
	AgentToolResult r2 = tools.execute("write_file",
		parseJson("{\"path\":\"s.txt\",\"content\":\"xy\",\"overwrite\":true}"));
	TH_CHECK(r2.ok == true);
	TH_CHECK_MSG(r2.summary == "bytes=2 overwrite=true", r2.summary);
	robot->deactivate();
}
