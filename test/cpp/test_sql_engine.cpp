/* test_sql_engine.cpp —— SQLite3 结构加载器与旧 ScriptLoader 的差分回归
 *
 * 生产结构加载走 SqlEngine（SQLite3 + DSL 归一化）；旧 ScriptLoader 仍服务
 * 热 SQL。两边必须对同一结构脚本产出逐格一致的 MatrixObject 表。
 */

#include <algorithm>
#include <deque>
#include <fstream>
#include <iterator>
#include <string>

#include "fixtures.hpp"
#include "harness.hpp"
#include "script_loader.hpp"
#include "sql_engine.hpp"
#include "util_except.hpp"

namespace {

std::deque<mt::MatrixObject> viaEngine(const std::string& sql) {
	bot::SqlEngine engine;
	return engine.loadStructure(sql);
}

std::deque<mt::MatrixObject> viaLegacy(const std::string& sql) {
	std::deque<mt::MatrixObject> tables;
	bot::MemoryReader reader(sql);
	bot::ScriptLoader::readSQL(reader, tables);
	return tables;
}

void requireSame(const std::deque<mt::MatrixObject>& left,
		const std::deque<mt::MatrixObject>& right) {
	TH_CHECK(left.size() == right.size());
	if (left.size() != right.size()) { return; }
	for (std::size_t t = 0; t < left.size(); ++t) {
		const mt::MatrixObject& a = left[t];
		const mt::MatrixObject& b = right[t];
		TH_CHECK(a.getName() == b.getName());
		TH_CHECK(a.rows() == b.rows());
		TH_CHECK(a.cols() == b.cols());
		const std::int64_t rows = std::min<std::int64_t>(a.rows(), b.rows());
		const std::int64_t cols = std::min<std::int64_t>(a.cols(), b.cols());
		for (std::int64_t r = 0; r < rows; ++r) {
			for (std::int64_t c = 0; c < cols; ++c) {
				TH_CHECK_MSG(a(r, c) == b(r, c),
					"table " + a.getName() + " row " + std::to_string(r)
						+ " col " + std::to_string(c) + ": '" + a(r, c)
						+ "' != '" + b(r, c) + "'");
			}
		}
	}
}

std::string readAll(const std::string& path) {
	std::ifstream stream(path);
	if (!stream) { throw std::runtime_error("fixture not found: " + path); }
	return std::string((std::istreambuf_iterator<char>(stream)),
		std::istreambuf_iterator<char>());
}

} // namespace

TH_TEST(sql_engine_matches_legacy_on_basic_structure) {
	const std::string sql =
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Relay (name String, controller String, note String);\n"
		"INSERT INTO Relay (name, controller, note) VALUES ('r0', 't0', 'hello world');\n";
	requireSame(viaEngine(sql), viaLegacy(sql));
}

TH_TEST(sql_engine_matches_legacy_on_dsl_values) {
	const std::string sql =
		"CREATE TABLE Vars (name String, value String);\n"
		"INSERT INTO Vars (name, value) VALUES ('n', '$(1+2*3)');\n"
		"CREATE TABLE I2C (name String, path String);\n"
		"INSERT INTO I2C (name, path) VALUES ('bus', '/dev/i2c-1');\n"
		"CREATE TABLE SHT3X (name String, I2C String, address String);\n"
		"INSERT INTO SHT3X (name, I2C, address) VALUES ('s0', '$bus', '0x44');\n"
		"INSERT INTO SHT3X (name, I2C, address) VALUES ('s1', '-', '-');\n";
	requireSame(viaEngine(sql), viaLegacy(sql));
}

TH_TEST(sql_engine_matches_legacy_when_insert_column_order_differs) {
	const std::string sql =
		"CREATE TABLE T (name String, a String, b String);\n"
		"INSERT INTO T (b, name, a) VALUES ('B', 'n0', 'A');\n";
	requireSame(viaEngine(sql), viaLegacy(sql));
}

TH_TEST(sql_engine_matches_legacy_on_quoted_punctuation) {
	const std::string sql =
		"CREATE TABLE T (name String, note String);\n"
		"INSERT INTO T (name, note) VALUES ('n0', 'a;b#c, d');\n";
	requireSame(viaEngine(sql), viaLegacy(sql));
}

TH_TEST(sql_engine_matches_legacy_on_a_real_virt_fixture) {
	const std::string sql = readAll("robots/test/ads1015_virt.sql");
	requireSame(viaEngine(sql), viaLegacy(sql));
}

TH_TEST(sql_engine_rejects_missing_unknown_and_duplicate_insert_columns) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "missing value for column",
		viaEngine("CREATE TABLE T (name String, v Number);"
			"INSERT INTO T (name) VALUES ('x');"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no such column",
		viaEngine("CREATE TABLE T (name String);"
			"INSERT INTO T (nome) VALUES ('x');"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "listed twice",
		viaEngine("CREATE TABLE T (name String);"
			"INSERT INTO T (name, name) VALUES ('x', 'y');"));
}

TH_TEST(sql_engine_rejects_nul_and_script_time_mutations) {
	std::string withNul = "CREATE TABLE T (name String);";
	withNul.push_back('\0');
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "NUL", viaEngine(withNul));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot appear in a structure script",
		viaEngine("CREATE TABLE T (name String); DROP TABLE T;"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot appear in a structure script",
		viaEngine("CREATE TABLE T (name String); UPDATE T SET name='x';"));
}
