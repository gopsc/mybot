/* test_sqlparse_query.cpp —— 结构脚本查询方言（SELECT/WHERE/AND/DROP/UPDATE/SHOW）
 *
 * 自 test_sqlparse.cpp 拆出（2026-10-01，行为保持）：语句级方言面——
 * SELECT 投影、WHERE 等值条件、AND 多条件（热删除同步扩展）、DROP TABLE
 * 整表撤下、UPDATE 断电重建、SHOW TABLES 只读清单；事件流助手
 * fx::events（fixtures.hpp，2026-10-01 自 test_sqlparse.cpp 上收）。
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

/* ---------------- SELECT（/sql 查询命令）---------------- */

TH_TEST(parser_select_star_from_table_event) {
	std::vector<Event> eves = events("SELECT * FROM Vars;");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::SELECT_TABLE);
	TH_CHECK(eves[0].select.sourceTableName == "Vars");
}

TH_TEST(parser_select_accepts_mixed_case) {
	/* 关键字大小写不敏感（沿用词法既约行为）；* 与 FROM 需空白分隔，
	 * 否则「*」会并进 FROM 前的标识符（* 不是词法分隔符）。
	 * 语句须以 ; 收尾：EOF 处词法产出 UNEXPECTED_END（对 CREATE 同样如此）。 */
	std::vector<Event> a = events("select * from Relay;");
	std::vector<Event> b = events("SeLeCt * FrOm Relay;");
	TH_CHECK(a.size() == 1 && a[0].type == EventType::SELECT_TABLE
		&& a[0].select.sourceTableName == "Relay");
	TH_CHECK(a[0].select.sourceTableName == b[0].select.sourceTableName);
}

TH_TEST(parser_select_can_follow_structure_statements) {
	std::vector<Event> eves = events(
		"CREATE TABLE Vars ( k String );\nINSERT INTO Vars ( k ) VALUES ( 'v0' );\n"
		"SELECT * FROM Vars;");
	TH_CHECK(eves.size() == 3);
	TH_CHECK(eves[2].type == EventType::SELECT_TABLE);
	TH_CHECK(eves[2].select.sourceTableName == "Vars");
}

TH_TEST(parser_select_rejects_non_star_and_missing_parts) {
	/* 只支持 `SELECT * FROM t`：非星号列 / 缺 FROM / 缺表名一律解析期报错 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "SELECT supports only",
		events("SELECT a FROM T;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "name 'T'",
		events("SELECT * T;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("SELECT * FROM"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("SELECT *"));
}

/* ---------------- WHERE 等值条件（2026-09-23）---------------- */

TH_TEST(lexer_where_and_eq_token_stream) {
	/* '=' 是第五个分隔词元（同 ; , ( ) 的「空直返/非空挂起」模式）；
	 * WHERE 是大小写不敏感的关键字。 */
	std::vector<Token> ts = fx::tokens("SELECT * FROM Vars WHERE name = 'v1';");
	TH_CHECK(fx::fingerprint(ts)
		== "SELECT name '*' FROM name 'Vars' WHERE name 'name' = name 'v1' ;");
}

TH_TEST(lexer_eq_compact_form_matches_spaced_form) {
	/* col=value 紧贴写法靠 eq_ 挂起标志切分，与留白写法词元流逐字节相同
	 * （取向同 lexer_parens_token_stream_matches_spaced_form）。 */
	std::vector<Token> compact = fx::tokens("SELECT * FROM T WHERE k='v';");
	std::vector<Token> spaced = fx::tokens("SELECT * FROM T WHERE k = 'v' ;");
	TH_CHECK(fx::fingerprint(compact) == fx::fingerprint(spaced));
	TH_CHECK(fx::fingerprint(compact)
		== "SELECT name '*' FROM name 'T' WHERE name 'k' = name 'v' ;");
}

TH_TEST(lexer_quoted_eq_is_data) {
	/* 引号内的 '=' 是数据（既有规则）：值 'a=b' 仍是一个 NAME 词元 */
	std::vector<Token> ts = fx::tokens("INSERT INTO T ( v ) VALUES ( 'a=b' );");
	bool found = false;
	for (const Token& t : ts) {
		if (t.type == TokenType::NAME && t.name == "a=b") { found = true; }
	}
	TH_CHECK(found);
}

TH_TEST(parser_select_where_event_payload) {
	std::vector<Event> eves = events("SELECT * FROM Servo WHERE name = 's1';");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::SELECT_TABLE);
	TH_CHECK(eves[0].select.sourceTableName == "Servo");
	TH_CHECK(eves[0].select.where.has_value());
	TH_CHECK(eves[0].select.where->conds.size() == 1);
	TH_CHECK(eves[0].select.where->conds[0].column == "name");
	TH_CHECK(eves[0].select.where->conds[0].value == "s1");
	/* 裸值（数字/标识符）与引号值等价：值一律按文本驻留 */
	std::vector<Event> bare = events("SELECT * FROM Servo WHERE channel = 0;");
	TH_CHECK(bare[0].select.where.has_value());
	TH_CHECK(bare[0].select.where->conds[0].column == "channel");
	TH_CHECK(bare[0].select.where->conds[0].value == "0");
}

TH_TEST(parser_select_without_where_has_no_condition) {
	std::vector<Event> eves = events("SELECT * FROM Vars;");
	TH_CHECK(!eves[0].select.where.has_value());
}

TH_TEST(parser_select_where_accepts_mixed_case) {
	std::vector<Event> a = events("select * from T where K = 'v';");
	TH_CHECK(a[0].select.where.has_value());
	TH_CHECK(a[0].select.where->conds[0].column == "K");
	TH_CHECK(a[0].select.where->conds[0].value == "v");
}

TH_TEST(parser_select_where_rejects_malformed_conditions) {
	/* 三个位置（列名/等号/值）共用一句用法级报错，报错锚点稳定 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("SELECT * FROM T WHERE = 'x';"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("SELECT * FROM T WHERE a 'x';"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("SELECT * FROM T WHERE a = ;"));
	/* `WHERE;` 收到的是 END 词元（用法级报错点名它）；EOF 才是 unexpected end */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("SELECT * FROM T WHERE;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("SELECT * FROM T WHERE"));
	/* OR 不在方言：多写词元由 nextEnd 的词元级报错兜住 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'OR'",
		events("SELECT * FROM T WHERE a = 'x' OR b = 'y';"));
	/* AND 后面必须还有一个完整条件——悬空 AND 落到 expect 的脚本结束报错 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("SELECT * FROM T WHERE a = 'x' AND"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("SELECT * FROM T WHERE a = 'x' AND = 'y';"));
}

/* ---------------- AND 多条件（2026-09-23 热删除同步扩展）---------------- */

TH_TEST(lexer_and_is_a_keyword_case_insensitively) {
	TH_CHECK(Token::parse("AND").type == TokenType::AND);
	TH_CHECK(Token::parse("and").type == TokenType::AND);
	TH_CHECK(Token::parse("aNd").type == TokenType::AND);
	TH_CHECK(Token::parse("AND").serialize() == "AND");
	/* 长度不同即不是关键字：前缀匹配不得命中（同 Strings/Numbers 既有判据） */
	TH_CHECK(Token::parse("Andy").type == TokenType::NAME);
	TH_CHECK(Token::parse("AND1").type == TokenType::NAME);
	/* 关键回归：'and' 作为**引用值**时是数据。仓内 144 个 .sql 里唯一的
	 * 两处 `and` 都在引号值内（robots/test/sqlquote.sql），词法引号态在
	 * 分隔符/关键字判定之前消费字符，故把它们变成关键字是安全的——
	 * 本断言就是这条安全性的守门。 */
	std::vector<Token> ts = fx::tokens(
		"INSERT INTO T ( v ) VALUES ( 'tag,with (parens) and space' );");
	bool found = false;
	for (const Token& t : ts) {
		if (t.type == TokenType::NAME && t.name == "tag,with (parens) and space") { found = true; }
	}
	TH_CHECK(found);
}

TH_TEST(parser_delete_where_accepts_multiple_and_conditions) {
	std::vector<Event> eves = events(
		"DELETE FROM Servo WHERE controller = 'dummy-0' AND channel = '6';");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::DELETE_TABLE);
	TH_CHECK(eves[0].del.targetTabName == "Servo");
	TH_CHECK(eves[0].del.where.has_value());
	TH_CHECK(eves[0].del.where->conds.size() == 2);
	TH_CHECK(eves[0].del.where->conds[0].column == "controller");
	TH_CHECK(eves[0].del.where->conds[0].value == "dummy-0");
	TH_CHECK(eves[0].del.where->conds[1].column == "channel");
	TH_CHECK(eves[0].del.where->conds[1].value == "6");
	/* 三个条件（AND 是循环而非二元特例） */
	std::vector<Event> three = events("DELETE FROM T WHERE a = 1 AND b = 2 AND c = 3;");
	TH_CHECK(three[0].del.where->conds.size() == 3);
	TH_CHECK(three[0].del.where->conds[2].column == "c");
	/* 小写 and / 关键字大小写不敏感 */
	std::vector<Event> lower = events("delete from T where a = 1 and b = 2;");
	TH_CHECK(lower[0].type == EventType::DELETE_TABLE);
	TH_CHECK(lower[0].del.targetTabName == "T");
	TH_CHECK(lower[0].del.where->conds.size() == 2);
}

TH_TEST(lexer_and_compact_form_matches_spaced_form) {
	/* AND 两侧不需要留白（既是关键字也是天然分隔符）：两种写法词元流逐字节
	 * 相同，取向同 parens/eq 的紧凑写法用例。 */
	std::vector<Token> compact = fx::tokens("DELETE FROM T WHERE a=1 AND b='x';");
	std::vector<Token> spaced = fx::tokens("DELETE FROM T WHERE a = 1 AND b = 'x' ;");
	TH_CHECK(fx::fingerprint(compact) == fx::fingerprint(spaced));
	TH_CHECK(fx::fingerprint(compact)
		== "DELETE FROM name 'T' WHERE name 'a' = name '1' AND name 'b' = name 'x' ;");
}

TH_TEST(parser_select_accepts_multiple_and_conditions) {
	/* SELECT 与 DELETE 共用条件列表解析：同一条多条件语法在两条语句上都成立 */
	std::vector<Event> eves = events("SELECT * FROM Servo WHERE controller = 'c0' AND channel = 1;");
	TH_CHECK(eves[0].type == EventType::SELECT_TABLE);
	TH_CHECK(eves[0].select.where->conds.size() == 2);
	TH_CHECK(eves[0].select.where->conds[1].column == "channel");
}

TH_TEST(parser_delete_without_where_deletes_all_rows) {
	/* 无条件 = 删全表（SQL 语义）：事件层以「where 无值」表达，不另设标志位 */
	std::vector<Event> eves = events("DELETE FROM Timer;");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::DELETE_TABLE);
	TH_CHECK(eves[0].del.targetTabName == "Timer");
	TH_CHECK(!eves[0].del.where.has_value());
}

TH_TEST(parser_delete_rejects_malformed_statements) {
	/* 缺 FROM / 缺表名 / 悬空条件一律解析期报错，且报错带词元定位 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'T'",
		events("DELETE T WHERE a = 1;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("DELETE FROM"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("DELETE FROM T WHERE;"));
}

/* ---------------- DROP TABLE（2026-09-23 整表撤下）----------------
 * DROP 是 DDL，作用于**整张表**：`DROP TABLE 表名`，**不带 WHERE**（WHERE 是 DML
 * 的行级筛选，加在这里会「长得像在筛行、实际却整表删」）。误写 WHERE 由 nextEnd
 * 的词元级报错兜住。解析层只产出事件，不查表、不碰活体——表存在性与断电/撤注册
 * 在消费方（readSQL / applySql）。本组钉住：词法、事件载荷、报错形态与定位。 */

TH_TEST(lexer_drop_is_a_keyword_case_insensitively) {
	TH_CHECK(Token::parse("DROP").type == TokenType::DROP);
	TH_CHECK(Token::parse("drop").type == TokenType::DROP);
	TH_CHECK(Token::parse("dRoP").type == TokenType::DROP);
	TH_CHECK(Token::parse("DROP").serialize() == "DROP");
	/* 长度不同即不是关键字：前缀匹配不得命中（同 Strings/Numbers 既有判据） */
	TH_CHECK(Token::parse("Dropx").type == TokenType::NAME);
	TH_CHECK(Token::parse("DROPS").type == TokenType::NAME);
}

TH_TEST(lexer_drop_token_stream) {
	std::vector<Token> ts = fx::tokens("DROP TABLE Timer;");
	TH_CHECK(fx::fingerprint(ts) == "DROP TABLE name 'Timer' ;");
	/* 无 FROM、无 WHERE：两个词元（DROP/TABLE）之后直接是表名 */
	std::vector<Token> compact = fx::tokens("DROP TABLE T;");
	TH_CHECK(fx::fingerprint(compact) == "DROP TABLE name 'T' ;");
}

TH_TEST(parser_drop_targets_the_whole_table) {
	std::vector<Event> eves = events("DROP TABLE Timer;");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::DROP_TABLE);
	TH_CHECK(eves[0].drop.targetTabName == "Timer");
}

TH_TEST(parser_drop_accepts_mixed_case) {
	std::vector<Event> a = events("drop table T;");
	TH_CHECK(a.size() == 1);
	TH_CHECK(a[0].type == EventType::DROP_TABLE);
	TH_CHECK(a[0].drop.targetTabName == "T");
}

TH_TEST(parser_drop_rejects_malformed_statements) {
	/* 缺 TABLE / 缺表名一律解析期报错，且报错带词元定位 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'T'",
		events("DROP T;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("DROP TABLE"));
	/* 表名位的 DROP 是关键字冲突（不再是合法 NAME）：报错点名该词元，
	 * 与「写错语法」可区分 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token DROP",
		events("DROP TABLE DROP;"));
}

TH_TEST(parser_drop_rejects_a_where_clause) {
	/* DROP 不带 WHERE（DDL 作用于整张表）：误写的 WHERE 由 nextEnd 词元级报错
	 * 兜住，自带行列定位——而不是被静默当作「守卫条件」接受。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token WHERE",
		events("DROP TABLE T WHERE a = 1;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token WHERE",
		events("DROP TABLE T where name = 'x';"));
	/* 悬空 WHERE 同型（词元级，不是用法级） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token WHERE",
		events("DROP TABLE T WHERE;"));
	/* 其它尾随词元同族：DROP 之后只能有分号 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'x'",
		events("DROP TABLE T x;"));
}

/* ---------------- UPDATE（2026-09-23 改写行：断电重建）----------------
 * `UPDATE t SET col = value [, ...] [WHERE col = value [AND ...]]`。
 * 解析层只产出事件：语义（命中行按「断电摘除 + 重新装配上电」改写）与边界
 * （被引用拒改、批内独占）都在消费方（readSQL / applySql），本组钉住词法、
 * 事件载荷、WHERE 复用与报错形态。 */

TH_TEST(lexer_update_and_set_are_keywords_case_insensitively) {
	TH_CHECK(Token::parse("UPDATE").type == TokenType::UPDATE);
	TH_CHECK(Token::parse("update").type == TokenType::UPDATE);
	TH_CHECK(Token::parse("UpDaTe").type == TokenType::UPDATE);
	TH_CHECK(Token::parse("UPDATE").serialize() == "UPDATE");
	TH_CHECK(Token::parse("SET").type == TokenType::SET);
	TH_CHECK(Token::parse("set").type == TokenType::SET);
	TH_CHECK(Token::parse("Set").serialize() == "SET");
	/* 长度不同即不是关键字：前缀匹配不得命中（同 DROP 既有判据） */
	TH_CHECK(Token::parse("Updates").type == TokenType::NAME);
	TH_CHECK(Token::parse("sets").type == TokenType::NAME);
}

TH_TEST(parser_update_parses_single_assignment) {
	std::vector<Event> eves = events("UPDATE Timer SET delay = 50;");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::UPDATE_TABLE);
	TH_CHECK(eves[0].update.targetTabName == "Timer");
	TH_CHECK(eves[0].update.assignments.size() == 1);
	TH_CHECK(eves[0].update.assignments[0].columnName == "delay");
	TH_CHECK(eves[0].update.assignments[0].value == "50");
	/* 无 WHERE = 改写全部数据行（事件层以「where 无值」表达，与 DELETE 同口径） */
	TH_CHECK(!eves[0].update.where.has_value());
}

TH_TEST(parser_update_accepts_multiple_assignments_and_where) {
	std::vector<Event> eves = events(
		"UPDATE Servo SET angle = 90, offset = '-4' WHERE name = 's1' AND channel = '0';");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::UPDATE_TABLE);
	TH_CHECK(eves[0].update.assignments.size() == 2);
	TH_CHECK(eves[0].update.assignments[1].columnName == "offset");
	TH_CHECK(eves[0].update.assignments[1].value == "-4");
	TH_CHECK(eves[0].update.where.has_value());
	TH_CHECK(eves[0].update.where->conds.size() == 2);
	TH_CHECK(eves[0].update.where->conds[0].column == "name");
	TH_CHECK(eves[0].update.where->conds[1].value == "0");
	/* 小写 / 关键字大小写不敏感 */
	std::vector<Event> lower = events("update t set a = 1 where b = 2;");
	TH_CHECK(lower[0].type == EventType::UPDATE_TABLE);
	TH_CHECK(lower[0].update.targetTabName == "t");
	TH_CHECK(lower[0].update.where->conds.size() == 1);
	/* 紧贴写法（= 不留白，靠词法器的挂起等号切分）与留白写法词元流一致 */
	std::vector<Token> compact = fx::tokens("UPDATE T SET a=1;");
	std::vector<Token> spaced = fx::tokens("UPDATE T SET a = 1 ;");
	TH_CHECK(fx::fingerprint(compact) == fx::fingerprint(spaced));
	TH_CHECK(fx::fingerprint(compact) == "UPDATE name 'T' SET name 'a' = name '1' ;");
}

TH_TEST(parser_update_validates_number_columns) {
	/* 与 INSERT 同一判据单点（validateNumberValues）：同脚本 CREATE 过的表，
	 * Number 列的 SET 值必须是数值字面量或 $(表达式)；String 列不受限 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is declared Number, but value 'abc'",
		events("CREATE TABLE T ( name String, delay Number );"
		       "UPDATE T SET delay = 'abc' WHERE name = 'x';"));
	std::vector<Event> ok = events(
		"CREATE TABLE T ( name String, delay Number );"
		"UPDATE T SET delay = 50, name = 'x';");
	TH_CHECK(ok[1].update.assignments[0].value == "50");
	/* $(表达式) 合法（语法在此早校验）；表达式值须带引号——词法器把 '(' 当
	 * 分隔符，不带引号会在 '$' 后切开（与 INSERT 的 VALUES 同一既有口径） */
	std::vector<Event> expr = events(
		"CREATE TABLE T ( name String, delay Number );"
		"UPDATE T SET delay = '$(1 + 2)';");
	TH_CHECK(expr[1].update.assignments[0].value == "$(1 + 2)");
	/* 表未在本脚本 CREATE 则无从校验（消费方负责） */
	std::vector<Event> other = events("UPDATE Other SET v = abc;");
	TH_CHECK(other[0].update.assignments[0].value == "abc");
}

TH_TEST(parser_update_rejects_malformed_statements) {
	/* 缺 SET / 缺表名 / 赋值缺等号 / 悬空逗号 / 尾随词元一律解析期报错；
	 * SET 用法级报错与 WHERE 同风格（从「Token ,」反推语法对模型太绕） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token WHERE",
		events("UPDATE T WHERE a = 1;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("UPDATE T SET"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "SET supports only",
		events("UPDATE T SET a 1;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "SET supports only",
		events("UPDATE T SET a = ;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("UPDATE T SET a = 1,"));
	/* 用 AND 连接赋值是错的写法：终止判据只认逗号，AND 留给 nextEnd 词元级报错
	 * （取向同 WHERE 的 OR——「还能写什么」交给既有的定位报错，不在本函数里猜） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token AND",
		events("UPDATE T SET a = 1 AND b = 2;"));
	/* WHERE 的用法级报错与 SELECT/DELETE 同一入口（三语句不会漂移的既有判据） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "WHERE supports only",
		events("UPDATE T SET a = 1 WHERE b;"));
	/* 尾随词元（含误写的 OR——它不是关键字，落成 NAME）由 nextEnd 兜住 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'OR'",
		events("UPDATE T SET a = 1 WHERE b = 2 OR c = 3;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'x'",
		events("UPDATE T SET a = 1 x;"));
}

/* ---------------- SHOW TABLES（只读：列出全部表）----------------
 * `SHOW TABLES;`——无载荷的只读语句，解析层只认「TABLES 关键字 + 分号」，不带
 * WHERE/LIKE（过滤交给 SELECT * FROM 表 WHERE）。表名清单与数据行数在消费方
 * （agenttools 的 renderShowTables）枚举运行时矩阵得到，本组只钉词法/语法/报错。 */

TH_TEST(lexer_show_and_tables_are_keywords_case_insensitively) {
	TH_CHECK(Token::parse("SHOW").type == TokenType::SHOW);
	TH_CHECK(Token::parse("show").type == TokenType::SHOW);
	TH_CHECK(Token::parse("ShOw").type == TokenType::SHOW);
	TH_CHECK(Token::parse("SHOW").serialize() == "SHOW");
	TH_CHECK(Token::parse("TABLES").type == TokenType::TABLES);
	TH_CHECK(Token::parse("tables").type == TokenType::TABLES);
	TH_CHECK(Token::parse("Tables").type == TokenType::TABLES);
	TH_CHECK(Token::parse("TABLES").serialize() == "TABLES");
	/* 长度不同即不是关键字：前缀匹配不得命中（同 Strings/Dropx 既有判据）。
	 * 关键：TABLES(6) 不会误命中既有关键字 TABLE(5)，二者是不同词元。 */
	TH_CHECK(Token::parse("Showx").type == TokenType::NAME);
	TH_CHECK(Token::parse("SHOWS").type == TokenType::NAME);
	TH_CHECK(Token::parse("Tablesx").type == TokenType::NAME);
	TH_CHECK(Token::parse("TABLE").type == TokenType::TABLE);
}

TH_TEST(lexer_show_tables_token_stream) {
	std::vector<Token> ts = fx::tokens("SHOW TABLES;");
	TH_CHECK(fx::fingerprint(ts) == "SHOW TABLES ;");
}

TH_TEST(parser_show_tables_event) {
	std::vector<Event> eves = events("SHOW TABLES;");
	TH_CHECK(eves.size() == 1);
	TH_CHECK(eves[0].type == EventType::SHOW_TABLES);
	/* 关键字大小写不敏感（沿用词法既约行为） */
	std::vector<Event> lower = events("show tables;");
	TH_CHECK(lower.size() == 1 && lower[0].type == EventType::SHOW_TABLES);
	/* 可跟在结构语句之后（与 SELECT 同一「只读语句可混排」取向） */
	std::vector<Event> seq = events(
		"CREATE TABLE Vars ( k String );\nINSERT INTO Vars ( k ) VALUES ( 'v0' );\n"
		"SHOW TABLES;");
	TH_CHECK(seq.size() == 3);
	TH_CHECK(seq[2].type == EventType::SHOW_TABLES);
}

TH_TEST(parser_show_tables_rejects_malformed) {
	/* 漏 S 的 `SHOW TABLE;`：TABLES 位收到 TABLE 关键字，expectType 词元级报错带定位 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token TABLE",
		events("SHOW TABLE;"));
	/* 缺 TABLES：`SHOW;` 收到 END 词元 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token ;",
		events("SHOW;"));
	/* 缺分号：EOF 处词法产出 UNEXPECTED_END，nextEnd 报脚本结束 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected end of script",
		events("SHOW TABLES"));
	/* 不带 LIKE：尾随词元由 nextEnd 的词元级报错兜住（LIKE 不是关键字，落成 NAME） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Token name 'LIKE'",
		events("SHOW TABLES LIKE 'x';"));
}
