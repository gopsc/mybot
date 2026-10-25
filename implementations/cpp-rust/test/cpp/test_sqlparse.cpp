/* test_sqlparse.cpp —— 结构脚本词法/语法分析（SQL4cj 移植）
 *
 * 覆盖两条只在负路径上才显形的契约：
 *   C2  连续分隔符不得走 return next(sr) 尾递归（--tcp 下可被远程输入打爆栈）
 *   引号语义  值里的 "--"、块注释起始符、";"、"," 是数据而非注释或语句边界
 * 以及 Parser 的报错形态：一律「Token <词元>」指出出问题的位置；
 * F5-1 起词元带 1 起行列，报错追加「 (line N, column M)」（既有子串锚点不受影响），
 * 引号态跨越 EOF 报「Unterminated string」并给开引号落点（旧实现静默放行半截串）。
 * 唯一的例外是语句首词元为删除/改写类语句（DROP/DELETE/UPDATE）时报
 * 「Unsupported statement …」——词元级消息在那三句上答不了「是不支持还是写错了」。
 *
 * 2026-10-01 TU 拆分（行为保持）：SELECT/WHERE/AND/DROP/UPDATE/SHOW 查询
 * 方言 → test_sqlparse_query.cpp；events 事件流助手上收 fixtures.hpp。
 */

#include <cstddef>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "sqlparse.hpp"
#include "util_except.hpp"

using sql4cj::Event;
using sql4cj::EventType;
using sql4cj::Token;
using sql4cj::TokenType;
using sql4cj::VarType;

using fx::events;

/* ---------------- Token::parse ---------------- */

TH_TEST(token_keyword_matching_is_ascii_case_insensitive) {
	TH_CHECK(Token::parse("CREATE").type == TokenType::CREATE);
	TH_CHECK(Token::parse("create").type == TokenType::CREATE);
	TH_CHECK(Token::parse("cReAtE").type == TokenType::CREATE);
	TH_CHECK(Token::parse("String").type == TokenType::STRING);
	TH_CHECK(Token::parse("STRING").type == TokenType::STRING);
	TH_CHECK(Token::parse("Number").type == TokenType::NUMBER);
	TH_CHECK(Token::parse("NUMBER").type == TokenType::NUMBER);
	TH_CHECK(Token::parse("nUmBeR").type == TokenType::NUMBER);
	TH_CHECK(Token::parse("VALUES").type == TokenType::VALUES);
	/* 长度不同即不是关键字：不能被前缀匹配误判 */
	TH_CHECK(Token::parse("Strings").type == TokenType::NAME);
	TH_CHECK(Token::parse("Numbers").type == TokenType::NAME);
	TH_CHECK(Token::parse("Createx").type == TokenType::NAME);
	TH_CHECK(Token::parse("Relay").type == TokenType::NAME);
	TH_CHECK(Token::parse("Relay").name == "Relay");
}

TH_TEST(token_name_strips_quotes) {
	TH_CHECK(Token::parse("'r0'").name == "r0");
	TH_CHECK(Token::parse("\"r0\"").name == "r0");
	/* 只有首尾成对的引号才剥；中间引号属数据 */
	TH_CHECK(Token::parse("a'b").name == "a'b");
	/* serialize() 的 NAME 形态带 `name '...'` 前缀，便于日志定位 */
	TH_CHECK(Token::parse("'r0'").serialize() == "name 'r0'");
	TH_CHECK(Token::parse(";").serialize() == ";");
	TH_CHECK(Token::parse("CREATE").serialize() == "CREATE");
}

/* ---------------- Lexer ---------------- */

TH_TEST(lexer_create_table_token_stream) {
	std::vector<Token> ts = fx::tokens("CREATE TABLE Relay ( name String, note String );");
	/* 尾随逗号延后一拍产出：先词元本身，再 COMMA（见 Lexer::next 的 comma_ 挂起） */
	TH_CHECK(fx::fingerprint(ts)
		== "CREATE TABLE name 'Relay' ( name 'name' STRING , name 'note' STRING ) ;");
}

TH_TEST(lexer_insert_token_stream) {
	std::vector<Token> ts = fx::tokens(
		"INSERT INTO Relay ( name, note ) VALUES ( 'r0', 'hello' );");
	TH_CHECK(fx::fingerprint(ts) ==
		"INSERT INTO name 'Relay' ( name 'name' , name 'note' ) VALUES ( name 'r0' , name 'hello' ) ;");
}

TH_TEST(lexer_quoted_dashes_are_data_not_comment) {
	/* 引号内的 "--" 曾被当行注释，吞掉同一值之后的全部词元 */
	std::vector<Token> ts = fx::tokens(
		"INSERT INTO Alias ( name, alias ) VALUES ( 'x', 'a--b' );");
	TH_CHECK(ts.size() == 15);
	TH_CHECK(ts[12].type == TokenType::NAME && ts[12].name == "a--b");
	/* 引号内的 "--" 没有吃掉后面的 ')' 与 ';' */
	TH_CHECK(ts[13].type == TokenType::RGHT);
	TH_CHECK(ts[14].type == TokenType::END);
}

TH_TEST(lexer_quoted_block_comment_marker_is_data) {
	std::vector<Token> ts = fx::tokens("INSERT INTO T ( v ) VALUES ( 'a/*b' );");
	bool found = false;
	for (const Token& t : ts) {
		if (t.type == TokenType::NAME && t.name == "a/*b") { found = true; }
	}
	TH_CHECK(found);
}

TH_TEST(lexer_quoted_semicolon_and_comma_are_data) {
	std::vector<Token> ts = fx::tokens("INSERT INTO T ( v ) VALUES ( 'a;b,c' );");
	bool found = false;
	std::size_t ends = 0;
	for (const Token& t : ts) {
		if (t.type == TokenType::NAME && t.name == "a;b,c") { found = true; }
		if (t.type == TokenType::END) { ++ends; }
	}
	TH_CHECK(found);
	/* 引号里的 ';' 不得提前收尾：整句只应有末尾一个 END */
	TH_CHECK(ends == 1);
}

/* 评估 2026-09-20：括号是分隔符，与空白无关——此前 '(' 只在「token 起始」
 * 有分支、')' 只在「token 非空」有分支，于是紧跟标识符的 '(' 被并进名字，
 * `INSERT INTO T(a,b) VALUES(1,2)` 解析失败（`Token ,`）。SQL 空白不敏感是
 * 常识，仓内夹具恰好一律写成 `T (a, b)` 故从未暴露。以下两条断言在修复前
 * 必失败（前者指纹里出现 `name 'Relay(name'`，后者直接抛异常）。 */
TH_TEST(lexer_parens_without_surrounding_space_are_delimiters) {
	std::vector<Token> ts = fx::tokens("INSERT INTO Relay(name, delay) VALUES('r0', 200);");
	TH_CHECK(fx::fingerprint(ts) ==
		"INSERT INTO name 'Relay' ( name 'name' , name 'delay' ) VALUES ( name 'r0' , name '200' ) ;");
}

TH_TEST(lexer_parens_token_stream_matches_spaced_form) {
	/* 同一句话两种写法（紧凑 / 留白）必须产出逐字节相同的词元流 */
	std::vector<Token> compact = fx::tokens("CREATE TABLE T(a Number);INSERT INTO T(a) VALUES(1);");
	std::vector<Token> spaced = fx::tokens("CREATE TABLE T ( a Number ); INSERT INTO T ( a ) VALUES ( 1 );");
	TH_CHECK(fx::fingerprint(compact) == fx::fingerprint(spaced));
	TH_CHECK(fx::fingerprint(compact) ==
		"CREATE TABLE name 'T' ( name 'a' NUMBER ) ; INSERT INTO name 'T' ( name 'a' ) VALUES ( name '1' ) ;");
}

TH_TEST(lexer_lone_parens_before_space) {
	/* 修复前 `String )` 里的 ')' 会被当成名字（name ')'）；现在与 `String)` 同流 */
	std::vector<Token> ts = fx::tokens("CREATE TABLE T ( a Number );");
	TH_CHECK(ts.size() == 8);
	TH_CHECK(ts[4].type == TokenType::NAME && ts[4].name == "a");
	TH_CHECK(ts[5].type == TokenType::NUMBER);
	TH_CHECK(ts[6].type == TokenType::RGHT);
	TH_CHECK(ts[7].type == TokenType::END);
}

TH_TEST(lexer_quote_state_is_incremental_on_large_values) {
	/* F-02：旧实现每追加一个字符就重扫整个 token（insideQuotes O(长度)），
	 * 100 KB 引号值实测 4.84 s 纯 CPU；1 MB 按平方标度需 ~8 分钟，会把
	 * run_all.sh 的 60 s 单测超时打红。增量引号态后线性通过，
	 * 同时钉住大值逐字节保真。 */
	const std::size_t n = 1u << 20;
	std::string sql = "INSERT INTO T ( v ) VALUES ( '";
	sql.append(n, 'x');
	sql += "' );";
	std::vector<Token> ts = fx::tokens(sql);
	const Token* val = nullptr;
	for (const Token& t : ts) {
		if (t.type == TokenType::NAME && t.name.size() == n) { val = &t; }
	}
	TH_CHECK(val != nullptr);
	if (val != nullptr) {
		TH_CHECK(val->name.front() == 'x' && val->name.back() == 'x');
	}
	TH_CHECK(ts.back().type == TokenType::END);
}

TH_TEST(lexer_quote_state_matches_legacy_semantics) {
	/* 增量状态与旧 insideQuotes 的逐字符等价性回归（三处易错点）：
	 *   1) 引号内的空白是数据，不得断词；
	 *   2) 只有打开引号态的那一种引号字符能闭合——'a"b' 里的 " 是数据；
	 *   3) 引号闭合后同 token 续写（'a'b）仍是一个 NAME，name 只剥首尾引号。 */
	auto nameOf = [](const std::string& text, const std::string& want) {
		for (const Token& t : fx::tokens(text)) {
			if (t.type == TokenType::NAME && t.name == want) { return true; }
		}
		return false;
	};
	TH_CHECK(nameOf("INSERT INTO T ( v ) VALUES ( 'a b c' );", "a b c"));
	TH_CHECK(nameOf("INSERT INTO T ( v ) VALUES ( 'a\"b' );", "a\"b"));
	TH_CHECK(nameOf("INSERT INTO T ( v ) VALUES ( 'a'b );", "a'b"));
	/* SQL 标准 '' 双写转义（#33，2026-09-24）：连续两个同种引号 = 一个字面
	 * 引号。修复前此处为「双写转义不实现、原样保留」（值 it''s）；现按标准
	 * 转义为 it's——本断言已随行为变更同步更新。 */
	TH_CHECK(nameOf("INSERT INTO T ( v ) VALUES ( 'it''s' );", "it's"));
}

TH_TEST(lexer_comments_outside_quotes_are_skipped) {
	std::vector<Token> a = fx::tokens("CREATE TABLE T ( -- 行注释\n name String );");
	std::vector<Token> b = fx::tokens("CREATE TABLE T ( name String );");
	TH_CHECK(fx::fingerprint(a) == fx::fingerprint(b));

	std::vector<Token> c = fx::tokens("CREATE /* 块\n注释 */ TABLE T ( name String );");
	TH_CHECK(fx::fingerprint(c) == fx::fingerprint(b));
}

TH_TEST(lexer_comment_start_flushes_pending_token) {
	/* C3-x：注释起始须先提交挂起 token——"50--c\n60" 曾被静默拼成 "5060"，
	 * 通过 Number 列校验产出错误数值。注释等价于空白，两侧 token 必须分开。 */
	std::vector<Token> a = fx::tokens("INSERT INTO T ( v ) VALUES ( 50--c\n60 );");
	/* 注释等价于空白：基准不带逗号（逗号是分隔符词元，注释不产出词元） */
	std::vector<Token> b = fx::tokens("INSERT INTO T ( v ) VALUES ( 50 60 );");
	TH_CHECK(fx::fingerprint(a) == fx::fingerprint(b));
	/* 块注释同族缺陷同修 */
	std::vector<Token> c = fx::tokens("INSERT INTO T ( v ) VALUES ( 50/*c*/60 );");
	TH_CHECK(fx::fingerprint(c) == fx::fingerprint(b));
}

TH_TEST(lexer_trailing_line_comment_terminates_cleanly) {
	std::vector<Token> ts = fx::tokens("CREATE TABLE T ( name String ); -- 收尾注释\n");
	TH_CHECK(!ts.empty());
	TH_CHECK(ts.back().type == TokenType::END);
	TH_CHECK(ts.back().serialize() == ";");
}

TH_TEST(lexer_repeated_delimiters_do_not_recurse) {
	/* C2 防线：8 个连续逗号 + 分号必须平铺产出，而不是 9 层真实递归 */
	std::vector<Token> ts = fx::tokens(",,,,,,,,;");
	TH_CHECK(ts.size() == 9);
	std::size_t commas = 0;
	for (const Token& t : ts) {
		if (t.type == TokenType::COMMA) { ++commas; }
	}
	TH_CHECK(commas == 8);
	TH_CHECK(ts.back().type == TokenType::END);
	/* F5-1 语义变更：未闭合的引号不再一路吃到 EOF 后剥引号放行（值被无声
	 * 截断），而是报「Unterminated string」并给开引号落点（此处第 1 行第 1 列） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Unterminated string starting at line 1, column 1",
		fx::tokens("'unterminated"));
}

TH_TEST(lexer_statement_end_flag_emits_one_semicolon) {
	/* "a;"：分号挂在词元上延后一拍产出，保证 INSERT ...; 后仍有 END 收尾 */
	std::vector<Token> ts = fx::tokens("name;");
	TH_CHECK(ts.size() == 2);
	TH_CHECK(ts[0].type == TokenType::NAME);
	TH_CHECK(ts[1].type == TokenType::END);
}

/* ---------------- Parser ---------------- */

TH_TEST(parser_create_table_event) {
	std::vector<Event> eves = events("CREATE TABLE Relay ( name String, controller String );");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::CREATE_TABLE);
	TH_CHECK(eves[0].create.tableName == "Relay");
	TH_CHECK(eves[0].create.tableColumns.size() == 2);
	TH_CHECK(eves[0].create.tableColumns[0].name == "name");
	TH_CHECK(eves[0].create.tableColumns[1].name == "controller");
}

TH_TEST(parser_insert_event_pairs_names_with_values) {
	std::vector<Event> eves = events(
		"CREATE TABLE Relay ( name String );\n"
		"INSERT INTO Relay ( name ) VALUES ( 'r0' );\n"
		"INSERT INTO Relay ( name ) VALUES ( 'r1' );\n");
	TH_CHECK(eves.size() == 3);
	TH_CHECK(eves[1].type == EventType::INSERT_TABLE);
	TH_CHECK(eves[1].insert.targetTabName == "Relay");
	TH_CHECK(eves[1].insert.tableRows.size() == 1);
	TH_CHECK(eves[1].insert.tableRows[0][0].columnName == "name");
	TH_CHECK(eves[1].insert.tableRows[0][0].value == "r0");
	TH_CHECK(eves[2].insert.tableRows[0][0].value == "r1");
}

TH_TEST(lexer_doubled_quote_escape_is_literal_quote) {
	/* #33：SQL 标准 '' 双写转义——'it''s' 应产出单个值 "it's"，
	 * 而不是被拆成 'it' 与 's' 两个 token（旧行为：每个同种引号都翻转引号态）。 */
	std::vector<Token> ts = fx::tokens("INSERT INTO T ( v ) VALUES ( 'it''s' );");
	TH_CHECK(fx::fingerprint(ts) ==
		"INSERT INTO name 'T' ( name 'v' ) VALUES ( name 'it's' ) ;");
	/* 双写后的引号是数据：不产生额外 token，整句仍只有一个 END */
	std::size_t ends = 0;
	for (const Token& t : ts) { if (t.type == TokenType::END) { ++ends; } }
	TH_CHECK(ends == 1);
}

TH_TEST(lexer_doubled_quote_empty_and_lone_quote) {
	/* '' = 空串（开即闭，与旧行为一致）；'''' = 一个字面引号（双写转义） */
	std::vector<Token> ts = fx::tokens("INSERT INTO T ( v ) VALUES ( '', '''' );");
	TH_CHECK(fx::fingerprint(ts) ==
		"INSERT INTO name 'T' ( name 'v' ) VALUES ( name '' , name ''' ) ;");
}

TH_TEST(parser_doubled_quote_escape_value) {
	/* #33：Parser 级验证转义值落到事件载荷 */
	std::vector<Event> eves = events(
		"CREATE TABLE Relay ( name String, note String );\n"
		"INSERT INTO Relay ( name, note ) VALUES ( 'r0', 'it''s' );\n");
	TH_CHECK(eves.size() == 2);
	TH_CHECK(eves[1].type == EventType::INSERT_TABLE);
	TH_CHECK(eves[1].insert.tableRows[0][0].value == "r0");
	TH_CHECK(eves[1].insert.tableRows[0][1].value == "it's");
}

TH_TEST(parser_create_table_records_number_column_type) {
	std::vector<Event> eves = events("CREATE TABLE T ( a String, b Number, c Number );");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].create.tableColumns.size() == 3);
	TH_CHECK(eves[0].create.tableColumns[0].type_ == VarType::String_);
	TH_CHECK(eves[0].create.tableColumns[1].type_ == VarType::Number);
	TH_CHECK(eves[0].create.tableColumns[2].type_ == VarType::Number);
}

TH_TEST(parser_number_column_accepts_numeric_values) {
	/* Integer / 小数 / 带符号 / 引号包裹的数值字面量都算数值；
	 * 值仍按文本驻留（本层不做类型转换）。 */
	std::vector<Event> eves = events(
		"CREATE TABLE T ( v Number );\n"
		"INSERT INTO T ( v ) VALUES ( 42 );\n"
		"INSERT INTO T ( v ) VALUES ( -1.5 );\n"
		"INSERT INTO T ( v ) VALUES ( +2e3 );\n"
		"INSERT INTO T ( v ) VALUES ( '7' );\n");
	TH_CHECK(eves.size() == 5);
	TH_CHECK(eves[1].insert.tableRows[0][0].value == "42");
	TH_CHECK(eves[2].insert.tableRows[0][0].value == "-1.5");
	TH_CHECK(eves[3].insert.tableRows[0][0].value == "+2e3");
	TH_CHECK(eves[4].insert.tableRows[0][0].value == "7");
}

TH_TEST(parser_number_column_rejects_non_numeric_value) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "declared Number",
		events("CREATE TABLE T ( v Number );\nINSERT INTO T ( v ) VALUES ( abc );"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not numeric",
		events("CREATE TABLE T ( v Number );\nINSERT INTO T ( v ) VALUES ( 'x1' );"));
	/* 空值与 nan/inf 字面量同样拒绝（与动作矩阵数值语义一致） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not numeric",
		events("CREATE TABLE T ( v Number );\nINSERT INTO T ( v ) VALUES ( '' );"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not numeric",
		events("CREATE TABLE T ( v Number );\nINSERT INTO T ( v ) VALUES ( nan );"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not numeric",
		events("CREATE TABLE T ( v Number );\nINSERT INTO T ( v ) VALUES ( inf );"));
}

TH_TEST(parser_number_check_is_by_column_name_only) {
	/* String 列的自由文本不受影响；Number 校验按列名匹配，不误伤同表其它列 */
	const std::vector<Event> eves = events(
		"CREATE TABLE T ( name String, v Number );\n"
		"INSERT INTO T ( name, v ) VALUES ( abc, 12 );\n");
	TH_CHECK(eves[1].insert.tableRows[0][0].value == "abc");
	TH_CHECK(eves[1].insert.tableRows[0][1].value == "12");

	/* 表未在本脚本中 CREATE 时无从校验（消费方负责「表未定义」报错） */
	const std::vector<Event> other = events("INSERT INTO Other ( v ) VALUES ( abc );");
	TH_CHECK(other[0].insert.tableRows[0][0].value == "abc");
}

TH_TEST(parser_rejects_multi_row_values_tuple) {
	/* 本方言一条 INSERT 只允许一组值：多组必须在解析期报错，
	 * 绝不能静默只取第一组（那会让结构脚本少装硬件而无声）。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token ,",
		events("INSERT INTO Relay ( name, note ) VALUES ( 'a', 'b' ), ( 'c', 'd' );"));
}

TH_TEST(parser_keywords_do_not_misfire_on_quoted_identifiers) {
	/* UPDATE / DROP / SET 现均为关键字，作为标识符（表名/列名/值）须带引号
	 * （引号在词法层剥，仍是合法 NAME）——裸写的同名标识符按关键字处理，
	 * 这是关键字语言的既有口径（同 from/where/values）。 */
	const std::vector<Event> made = events(
		"CREATE TABLE 'Update' ( 'drop' String, 'set' String );");
	TH_CHECK(made[0].create.tableName == "Update");
	TH_CHECK(made[0].create.tableColumns[0].name == "drop");
	TH_CHECK(made[0].create.tableColumns[1].name == "set");
	const std::vector<Event> ins = events(
		"INSERT INTO 'Update' ( 'drop' ) VALUES ( 'DROP' );");
	TH_CHECK(ins[0].insert.targetTabName == "Update");
	TH_CHECK(ins[0].insert.tableRows[0][0].value == "DROP");
	/* 值位的裸 SET 是关键字冲突：报错点名词元而不是被当成名字吞掉 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token SET",
		events("INSERT INTO T ( a ) VALUES ( SET );"));
}

TH_TEST(parser_reports_the_offending_token) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token ;",
		events(";"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token )",
		events("CREATE TABLE T ( name );"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'x'",
		events("CREATE x TABLE T ( name String );"));
}

TH_TEST(parser_error_carries_token_position) {
	/* F5-1：报错带词元 1 起行列——跨过行注释、块注释后仍须正确（列按字节计，
	 * 测试用 ASCII 注释避免多字节偏移干扰断言）。
	 * 第 3 行块注释收尾后的 CREATE x：x 落在第 3 行第 19 列（前两行被注释态消费）。
	 * 完整形态断言（非子串）：定位段必须是「 (line N, column M)」。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Token name 'x' (line 3, column 19)",
		events("-- line one comment\n/* block\ncomment */ CREATE x;\n"));
	/* 空词元分隔符：位置即字符落点 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Token SELECT (line 1, column 8)",
		events("CREATE SELECT ;"));
	/* 挂起分隔符（非空词元后的 ';' 挂到下一次 next() 产出）：落点须跟随
	 * 分隔符字符本身，而不是被消费时的读取位置 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Token ; (line 1, column 8)",
		events("INSERT ;"));
	/* 多行脚本：第二行的错误词元行号正确、列从行首重计 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Token ; (line 2, column 1)",
		events("CREATE TABLE T ( name String );\n;\n"));
}

TH_TEST(lexer_reports_unterminated_string_position) {
	/* F5-1：引号态跨越 EOF 必须报错并给出开引号落点——旧实现把 'abc
	 * 剥引号后当名字 abc 静默放行，值被无声截断。开引号在第 2 行第 33 列。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Unterminated string starting at line 2, column 33",
		events("CREATE TABLE T ( name String );\nINSERT INTO T ( name ) VALUES ( 'abc"));
	/* 双引号同型（" 在第 1 行第 33 列） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Unterminated string starting at line 1, column 33",
		events("CREATE TABLE T ( name String ); \"oops"));
}

TH_TEST(parser_reports_unexpected_end_of_script) {
	/* 截断的结构脚本必须报「脚本意外结束」，而不是拿空事件继续装配 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("CREATE TABLE"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("CREATE TABLE T ( name"));
}

TH_TEST(parser_rejects_param_value_count_mismatch) {
	/* fix-plan 3-4：数量不匹配报错必须带表名与两侧列数，便于定位拼写/漏列 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Insert into table 'T' has 1 column(s) but 2 value(s).",
		events("INSERT INTO T ( name ) VALUES ( 'a', 'b' );"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"Insert into table 'T' has 2 column(s) but 1 value(s).",
		events("INSERT INTO T ( name, note ) VALUES ( 'a' );"));
}

TH_TEST(parser_next_after_last_event_returns_end) {
	std::vector<Token> ts = fx::tokens("CREATE TABLE T ( name String );");
	sql4cj::Parser parser(ts);
	TH_CHECK(parser.next().type == EventType::CREATE_TABLE);
	/* 幂等：END 之后反复调用仍返回 END（readSQL 的循环靠这个收敛） */
	for (int k = 0; k < 3; ++k) {
		TH_CHECK(parser.next().type == EventType::END);
	}
}

/* ---------------- M-1 深层输入不得栈溢出 ---------------- */

TH_TEST(parser_deep_column_list_is_iterative) {
	/* M-1：列段原为按元素互递归，3 万列即打爆 8MB 栈（Release 实测 SIGSEGV）。
	 * 迭代化后必须在常量栈上解析出完整事件。 */
	const int n = 60000;
	std::string sql = "CREATE TABLE T (";
	for (int k = 0; k < n; ++k) {
		if (k) { sql += ", "; }
		sql += "c" + std::to_string(k) + " String";
	}
	sql += ");";
	std::vector<Event> eves = events(sql);
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::CREATE_TABLE);
	TH_CHECK(static_cast<int>(eves[0].create.tableColumns.size()) == n);
	TH_CHECK(eves[0].create.tableColumns[n - 1].name == "c" + std::to_string(n - 1));
}

TH_TEST(parser_deep_param_list_is_iterative) {
	/* M-1 同款：INSERT 参数/值段原为互递归，8 万参数实测栈溢出。 */
	const int n = 60000;
	std::string sql = "CREATE TABLE T ( name String );\nINSERT INTO T (";
	for (int k = 0; k < n; ++k) {
		if (k) { sql += ", "; }
		sql += "p" + std::to_string(k);
	}
	sql += ") VALUES (";
	for (int k = 0; k < n; ++k) {
		if (k) { sql += ", "; }
		sql += "v" + std::to_string(k);
	}
	sql += ");";
	std::vector<Event> eves = events(sql);
	TH_CHECK(eves.size() == 2);
	TH_CHECK(eves[1].type == EventType::INSERT_TABLE);
	TH_CHECK(eves[1].insert.tableRows.size() == 1);
	TH_CHECK(static_cast<int>(eves[1].insert.tableRows[0].size()) == n);
	TH_CHECK(eves[1].insert.tableRows[0][n - 1].columnName == "p" + std::to_string(n - 1));
	TH_CHECK(eves[1].insert.tableRows[0][n - 1].value == "v" + std::to_string(n - 1));
}


/* ---- 关键字单表的往返钉（2026-10-10：Token::parse 的 if 链与 serialize 的
 * switch 收敛为 kKeywords 一张表）----
 * 逐项钉 parse(规范名).type 与 serialize(type)==规范名：双表漂移（同键两处维护，
 * 加关键字漏改一处即「能解析但回显错名」或反向）在此变红。规范名 = serialize
 * 的回显名（大写）；parse 的大小写不敏感另以混合大小写抽查一条。 */
TH_TEST(token_keyword_table_roundtrip) {
	static const struct {
		const char* text;
		TokenType type;
	} kWords[] = {
		{"SELECT", TokenType::SELECT}, {"FROM", TokenType::FROM},
		{"CREATE", TokenType::CREATE}, {"TABLE", TokenType::TABLE},
		{"STRING", TokenType::STRING}, {"NUMBER", TokenType::NUMBER},
		{"INSERT", TokenType::INSERT}, {"INTO", TokenType::INTO},
		{"VALUES", TokenType::VALUES}, {"WHERE", TokenType::WHERE},
		{"DELETE", TokenType::DELETE}, {"DROP", TokenType::DROP},
		{"UPDATE", TokenType::UPDATE}, {"SET", TokenType::SET},
		{"AND", TokenType::AND}, {"SHOW", TokenType::SHOW},
		{"TABLES", TokenType::TABLES},
	};
	for (const auto& w : kWords) {
		Token t = Token::parse(w.text);
		TH_CHECK_MSG(t.type == w.type,
			std::string("parse(\"") + w.text + "\") 落错种类");
		TH_CHECK_MSG(t.serialize() == w.text,
			std::string("serialize 回显漂移: ") + w.text);
	}
	/* 大小写不敏感抽查（equalWithoutCase 判据，不逐项展开） */
	TH_CHECK(Token::parse("SeLeCt").type == TokenType::SELECT);
	TH_CHECK(Token::parse("select").type == TokenType::SELECT);
	/* 表外的词元（标点/NAME）不查关键字表，行为不变 */
	TH_CHECK(Token::parse(";").type == TokenType::END);
	TH_CHECK(Token::parse("name_x").type == TokenType::NAME);
}
