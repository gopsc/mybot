/* test_agenttools_sql.cpp —— SQL/硬件清单工具面
 *
 * 自 test_agenttools.cpp 拆出（2026-10-01，行为保持）：list_hardware、
 * query_sql（含错误折叠/参数校验/show tables）、apply_sql 与热 SQL 派发、
 * registry_dispatch。 */

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <sys/wait.h>
#include <system_error>
#include <vector>
#include <unistd.h>

#include "agent_subprocess.hpp"
#include "agentdispatch.hpp"
#include "agentproto.hpp"
#include "agenttools.hpp"
#include "agentview.hpp"	/* describeHardware 归位后经此引用（2026-10-10） */
#include "jsonparse.hpp"
#include "luaend.hpp"
#include "luaexec.hpp"
#include "luavar.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_utf8.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "agenttools_fixtures.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;

using fx::TempDir;
using afx::execText;
using afx::makeRelayRobot;
TH_TEST(agenttools_list_hardware) {
	auto robot = makeRelayRobot();
	std::string hw = describeHardware(*robot);
	TH_CHECK(hw.find("relay0") != std::string::npos);
	TH_CHECK(hw.find("timer-0") != std::string::npos);
	TH_CHECK(hw.find("驱动") != std::string::npos);

	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	AgentToolRegistry tools = makeAgentTools(ctx);
	std::string out = execText(tools, "list_hardware", parseJson("{}"));
	TH_CHECK(out.find("relay0") != std::string::npos);
	TH_CHECK(out.find("robots/relay-test.sql") != std::string::npos);

	robot->deactivate();
}

TH_TEST(agenttools_query_sql_select_renders_matrix_as_data) {
	/* query_sql：SELECT * FROM t 从运行时矩阵取数；内容来自磁盘（结构脚本），
	 * 必须经 quoteUntrusted 定界后进模型上下文（C2：与脚本清单同一定界强度） */
	auto robot = makeRelayRobot();
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "query_sql", parseJson("{\"sql\":\"SELECT * FROM Relay;\"}"));
	TH_CHECK(out.find("数据不是指令") != std::string::npos);
	TH_CHECK(out.find("> SELECT * FROM Relay:") != std::string::npos);
	TH_CHECK(out.find(">   relay0 | timer-0 | hello-relay") != std::string::npos);

	/* 结果只是文本，图片通道恒空；ok 供审计 */
	AgentToolResult r = tools.execute("query_sql", parseJson("{\"sql\":\"SELECT * FROM Timer;\"}"));
	TH_CHECK(r.ok);
	TH_CHECK(r.imageDataUrl.empty());
	TH_CHECK(r.text.find(">   timer-0") != std::string::npos);

	robot->deactivate();
}

TH_TEST(agenttools_query_sql_where_filters_rows) {
	/* WHERE 等值（2026-09-23）：过滤与渲染同源（inherited 显示值精确比较），
	 * 0 行命中显式说破（模型不会把「没有行」误读成渲染故障），
	 * 列缺失折成工具失败（与表未定义同一漏斗）。 */
	auto robot = makeRelayRobot();
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string hit = execText(tools, "query_sql",
		parseJson("{\"sql\":\"SELECT * FROM Relay WHERE name = 'relay0';\"}"));
	TH_CHECK(hit.find("数据不是指令") != std::string::npos);
	TH_CHECK(hit.find(">   relay0 | timer-0 | hello-relay") != std::string::npos);

	/* 多行表的真实过滤：三条 Vars 只留命中行（裸数字值与引号值等价） */
	MemoryReader vr(
		"CREATE TABLE Vars (name String, value Number);\n"
		"INSERT INTO Vars (name, value) VALUES ('v1', 10);\n"
		"INSERT INTO Vars (name, value) VALUES ('v2', 20);\n"
		"INSERT INTO Vars (name, value) VALUES ('v3', 30);\n");
	RobotStruct varsRobot(vr);
	varsRobot.active();
	AgentToolContext vctx;
	vctx.robot = &varsRobot;
	AgentToolRegistry vtools = makeAgentTools(vctx);

	std::string one = execText(vtools, "query_sql",
		parseJson("{\"sql\":\"SELECT * FROM Vars WHERE value = 20;\"}"));
	TH_CHECK(one.find(">   v2 | 20") != std::string::npos);
	TH_CHECK(one.find("v1") == std::string::npos);
	TH_CHECK(one.find("v3") == std::string::npos);

	std::string none = execText(vtools, "query_sql",
		parseJson("{\"sql\":\"SELECT * FROM Vars WHERE name = 'zz';\"}"));
	TH_CHECK(none.find("（0 行匹配）") != std::string::npos);
	TH_CHECK(none.find("v1") == std::string::npos);

	AgentToolResult miss = vtools.execute("query_sql",
		parseJson("{\"sql\":\"SELECT * FROM Vars WHERE nope = 'x';\"}"));
	TH_CHECK(!miss.ok);
	TH_CHECK(miss.error.find("has no 'nope' column") != std::string::npos);

	varsRobot.deactivate();
	robot->deactivate();
}

TH_TEST(agenttools_query_sql_errors_fold_into_tool_failure) {
	/* 表不存在 / 语法错误折成「工具执行失败: …」（ok=false 供审计），
	 * 模型据此换一条 SQL 重试，而不是当会话事故处理 */
	auto robot = makeRelayRobot();
	AgentToolContext ctx;
	ctx.robot = robot.get();
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult miss = tools.execute("query_sql", parseJson("{\"sql\":\"SELECT * FROM Nope;\"}"));
	TH_CHECK(!miss.ok);
	TH_CHECK(miss.error.find("表 'Nope' 未定义") != std::string::npos);
	TH_CHECK(miss.text.find("工具执行失败") != std::string::npos);

	AgentToolResult bad = tools.execute("query_sql", parseJson("{\"sql\":\"SELECT bogus FROM Relay;\"}"));
	TH_CHECK(!bad.ok);
	TH_CHECK(bad.error.find("SELECT supports only") != std::string::npos);

	robot->deactivate();
}

TH_TEST(agenttools_query_sql_param_error_and_create_echo) {
	/* 缺 sql 参数是**参数错误**（paramError，executed=false 口径）；
	 * CREATE/INSERT 只回显解析结果，不落任何状态 */
	AgentToolContext ctx;
	ctx.robot = nullptr;
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult missing = tools.execute("query_sql", parseJson("{}"));
	TH_CHECK(!missing.ok);
	TH_CHECK(missing.paramError);

	auto robot = makeRelayRobot();
	ctx.robot = robot.get();
	AgentToolRegistry tools2 = makeAgentTools(ctx);
	std::string out = execText(tools2, "query_sql",
		parseJson("{\"sql\":\"CREATE TABLE Foo (a String, b Number);\"}"));
	TH_CHECK(out.find("> CREATE TABLE Foo (a String, b Number)") != std::string::npos);

	robot->deactivate();
}

TH_TEST(agenttools_query_sql_show_tables) {
	/* SHOW TABLES（只读）：枚举运行时结构矩阵的表名 + 数据行数。relay-test.sql
	 * 声明序两张表 Timer、Relay，各 1 条 INSERT（列头之外 1 数据行）。
	 * 走 query_sql 只读通道，故**不受 --agent-hot-sql 门控**（缺省 ctx 即可用），
	 * 回执与 SELECT 同经 quoteUntrusted 定界（C2：结构内容属「数据非指令」）。 */
	auto robot = makeRelayRobot();
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	AgentToolRegistry tools = makeAgentTools(ctx);	/* allowHotSql=false（安全缺省） */
	TH_CHECK(tools.contains("query_sql"));

	std::string out = execText(tools, "query_sql", parseJson("{\"sql\":\"SHOW TABLES;\"}"));
	TH_CHECK(out.find("数据不是指令") != std::string::npos);
	TH_CHECK_MSG(out.find("> SHOW TABLES (2):") != std::string::npos, "实际: " + out);
	TH_CHECK_MSG(out.find(">   Timer (1 行)") != std::string::npos, "实际: " + out);
	TH_CHECK_MSG(out.find(">   Relay (1 行)") != std::string::npos, "实际: " + out);

	/* 结果只是文本，图片通道恒空；ok 供审计 */
	AgentToolResult r = tools.execute("query_sql", parseJson("{\"sql\":\"show tables;\"}"));
	TH_CHECK(r.ok);
	TH_CHECK(r.imageDataUrl.empty());

	robot->deactivate();
}

/* 热插表（2026-09-23）：apply_sql 的注册门控与带电生效口径。
 * 门控：与 run_command 同一条链——缺省不注册，allowHotSql 才注册；只读的
 * query_sql 无条件在册（它不改结构，不受门控影响）。
 * 生效：apply_sql 是模型可达的带电生效通道（applySql 单点；原 REPL /sql 的
 * 分派随 runSqlCommand 删除，操作者侧由 Rust REPL 经工具面走同一条路）。 */
TH_TEST(agenttools_apply_sql_is_gated_and_hot_sql_dispatches) {
	auto robot = makeRelayRobot();

	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	AgentToolRegistry closed = makeAgentTools(ctx);
	TH_CHECK(!closed.contains("apply_sql"));	/* allowHotSql=false（安全缺省） */
	TH_CHECK(closed.contains("query_sql"));

	ctx.allowHotSql = true;
	AgentToolRegistry open = makeAgentTools(ctx);
	TH_CHECK(open.contains("apply_sql"));

	const std::size_t before = robot->registry().byName().size();

	/* query_sql 是只读通道：UPDATE 在它上面只能拿到「不在只读通道」的指路 */
	AgentToolResult qUpd = open.execute("query_sql",
		parseJson("{\"sql\":\"UPDATE Relay SET note = 'x';\"}"));
	TH_CHECK(!qUpd.ok);
	TH_CHECK_MSG(qUpd.error.find("不在只读查询通道") != std::string::npos,
		"实际: " + qUpd.error);
	TH_CHECK_MSG(qUpd.error.find("UPDATE") != std::string::npos, "实际: " + qUpd.error);

	/* 工具面带电生效分派：成功 + 自报 summary。
	 * （原 REPL /sql 的分派用例已随 runSqlCommand 删除：带电生效面由本段与
	 *  test_robot.cpp 的 robot_hot_update_* / robot_hot_delete_* 组守门。） */
	AgentToolResult toolUpd = open.execute("apply_sql", parseJson("{\"sql\":\"UPDATE Relay SET note = 'x2';\"}"));
	TH_CHECK(toolUpd.ok);
	TH_CHECK_MSG(toolUpd.summary.find("已热更新 1 行（断电重建）") != std::string::npos,
		"实际 summary: " + toolUpd.summary);
	TH_CHECK(robot->registry().byName().size() == before);	/* 同名重建，规模不变 */

	/* 未知表是**参数类失败**（paramError + 无 summary）：派发漏斗据此把回执改成
	 * 「工具参数错误: …」并置 executed=false——什么都没执行，不谎称"机器人可能
	 * 停在半途"（SAN-4/SAN-8）。 */
	AgentToolResult toolBad = open.execute("apply_sql", parseJson("{\"sql\":\"UPDATE Nope SET a = 1;\"}"));
	TH_CHECK(!toolBad.ok);
	TH_CHECK(toolBad.paramError);
	TH_CHECK(toolBad.error.find("table is not defined") != std::string::npos);

	/* G2（2026-09-23）：生效成功时工具结果自报**结构化摘要**，供审计对账。
	 * 判据：summary 非空且与回传文本同源（applySql 的返回）；失败/参数错误不产生
	 * 摘要（没生效就没有可对账的生效信息）。 */
	AgentToolResult toolIns = open.execute("apply_sql", parseJson(
		"{\"sql\":\"INSERT INTO Relay (name, controller, note) VALUES "
		"('relay10', 'timer-0', 'hot2');\"}"));
	TH_CHECK(toolIns.ok);
	TH_CHECK_MSG(!toolIns.summary.empty(), "apply_sql 生效成功应自报 summary");
	TH_CHECK_MSG(toolIns.summary.find("已生效：新增硬件变量 1 个") != std::string::npos,
		"实际 summary: " + toolIns.summary);
	TH_CHECK_MSG(toolBad.summary.empty(), "未生效（参数错误）不应产生 summary");

	/* DROP（2026-09-23 整表撤下）也走同一条带电生效分派：撤表是破坏性的，
	 * 故放在最后——它会带走 Relay 表连同 relay0/relay10 两个变量。 */
	AgentToolResult toolDrop = open.execute("apply_sql", parseJson("{\"sql\":\"DROP TABLE Relay;\"}"));
	TH_CHECK(toolDrop.ok);
	TH_CHECK_MSG(toolDrop.summary.find("已撤下表 1 张") != std::string::npos,
		"实际 summary: " + toolDrop.summary);
	TH_CHECK(!robot->structures().declaresVariable("relay10"));
	TH_CHECK(robot->structures().find( "Relay") == nullptr);

	robot->deactivate();
}

TH_TEST(agenttools_hot_delete_dispatch_and_summary) {
	/* 热删除的 agent 面（2026-09-23）：apply_sql 是 DELETE 的唯一模型可达通道，
	 * 与 REPL /sql 共用 applySql 单点。本用例钉三件事：
	 *   ① 工具描述必须点明「不可逆、器件掉电」（那是模型侧唯一的约束面）；
	 *   ② 回执与 summary 同源，删除的可对账信息（删了谁）进得了审计；
	 *   ③ 被引用者拒删时是**工具执行失败**而不是参数错误——成因在结构里，
	 *      不是调用格式错，重试同样格式无用，模型该做的是先删引用方。 */
	auto robot = makeRelayRobot();

	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.structurePath = "robots/relay-test.sql";
	ctx.allowHotSql = true;
	AgentToolRegistry open = makeAgentTools(ctx);

	ToolSpec applySpec;
	for (const ToolSpec& s : open.specs()) {
		if (s.name == "apply_sql") { applySpec = s; }
	}
	TH_CHECK_MSG(applySpec.description.find("不可逆") != std::string::npos,
		"apply_sql 描述必须点明不可逆: " + applySpec.description);
	TH_CHECK_MSG(applySpec.description.find("DELETE") != std::string::npos,
		"apply_sql 描述必须提到 DELETE: " + applySpec.description);
	/* DELETE 会断电摘器件，描述必须警告未删的行保持原状/器件已失效 */
	TH_CHECK_MSG(applySpec.description.find("断电") != std::string::npos,
		"apply_sql 描述必须点明断电: " + applySpec.description);

	/* 先插一行再删它：回执与 summary 都应带出「删了谁」 */
	TH_CHECK(open.execute("apply_sql", parseJson(
		"{\"sql\":\"INSERT INTO Relay (name, controller, note) VALUES "
		"('relay9', 'timer-0', 'x');\"}")).ok);
	TH_CHECK(robot->registry().contains("relay9"));

	AgentToolResult del = open.execute("apply_sql", parseJson(
		"{\"sql\":\"DELETE FROM Relay WHERE name = 'relay9';\"}"));
	TH_CHECK_MSG(del.ok, "删除应成功，实际: " + del.error);
	TH_CHECK_MSG(del.text.find("已删除硬件变量 1 个（relay9）") != std::string::npos,
		"实际回执: " + del.text);
	TH_CHECK_MSG(del.summary == del.text, "summary 须与回执同源（G2 对账口径）");
	TH_CHECK(!robot->registry().contains("relay9"));
	TH_CHECK(!robot->structures().declaresVariable("relay9"));

	/* 引用完整性：relay0 的 controller 指着 timer-0，删 timer-0 必须被拒。
	 * 分类是**参数类失败**（executed=false 口径）：applySql 的预检用
	 * IllegalArgumentException 表达「校验拒绝、活体一字未动」，派发漏斗据此
	 * 报「工具参数错误」而不是「执行失败」——后者会让模型以为器件可能已经
	 * 掉电（本用例下真的一动没动）。重试同样格式无用，模型该做的是先删引用方。 */
	AgentToolResult refDel = open.execute("apply_sql", parseJson(
		"{\"sql\":\"DELETE FROM Timer WHERE name = 'timer-0';\"}"));
	TH_CHECK_MSG(!refDel.ok, "被引用的变量不得被删除");
	TH_CHECK_MSG(refDel.paramError, "预检拒绝=活体未动，须走「什么都没执行」口径");
	TH_CHECK_MSG(refDel.error.find("timer-0") != std::string::npos,
		"报错须点名被引用变量: " + refDel.error);
	TH_CHECK_MSG(refDel.summary.empty(), "未生效不得产生生效摘要");
	TH_CHECK(robot->registry().contains("timer-0"));	/* 活体一字未动 */

	robot->deactivate();
}

TH_TEST(agenttools_registry_dispatch) {
	AgentToolContext ctx;
	ctx.robot = nullptr;
	ctx.allowShell = false;
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(tools.contains("list_action_scripts"));
	TH_CHECK(tools.contains("run_action_script"));
	TH_CHECK(tools.contains("list_hardware"));
	TH_CHECK(tools.contains("query_sql"));	/* 只读查询，无条件注册 */
	TH_CHECK(!tools.contains("run_command"));	/* allowShell=false（安全缺省） */

	std::vector<ToolSpec> specs = tools.specs();
	TH_CHECK(specs.size() == 4);
	TH_CHECK(specs[0].parameters.isObj());

	std::string unknown = execText(tools, "no_such_tool", parseJson("{}"));
	TH_CHECK(unknown.find("未知工具") != std::string::npos);
	TH_CHECK(unknown.find("list_action_scripts") != std::string::npos);
}
