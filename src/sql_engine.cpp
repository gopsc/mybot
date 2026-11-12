#include "sql_engine.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include <sqlite3.h>

#include "scriptlimit.hpp"
#include "util_except.hpp"
#include "util_num.hpp"
#include "util_str.hpp"

namespace bot {
namespace {

struct Column {
	std::string name;
	std::string type;	// String / Number
};

struct Table {
	std::string name;
	std::vector<Column> columns;
};

std::string upper(std::string text) {
	std::transform(text.begin(), text.end(), text.begin(),
		[](unsigned char c) { return static_cast<char>(std::toupper(c)); });
	return text;
}

bool isIdentStart(char c) {
	return std::isalpha(static_cast<unsigned char>(c)) != 0 || c == '_';
}

bool isIdentChar(char c) {
	return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '_';
}

std::string quoteSql(const std::string& text) {
	std::string out = "'";
	for (char c : text) {
		if (c == '\'') { out.push_back('\''); }
		out.push_back(c);
	}
	out.push_back('\'');
	return out;
}

std::string quoteIdent(const std::string& text) {
	std::string out = "\"";
	for (char c : text) {
		if (c == '"') { out.push_back('"'); }
		out.push_back(c);
	}
	out.push_back('"');
	return out;
}

void skipSpaceComments(const std::string& text, std::size_t& pos) {
	while (pos < text.size()) {
		const char c = text[pos];
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
			++pos;
			continue;
		}
		if (c == '-' && pos + 1 < text.size() && text[pos + 1] == '-') {
			pos += 2;
			while (pos < text.size() && text[pos] != '\n') { ++pos; }
			continue;
		}
		if (c == '/' && pos + 1 < text.size() && text[pos + 1] == '*') {
			pos += 2;
			while (pos + 1 < text.size()
					&& !(text[pos] == '*' && text[pos + 1] == '/')) {
				++pos;
			}
			pos = std::min(text.size(), pos + 2);
			continue;
		}
		break;
	}
}

bool isBlank(const std::string& text) {
	std::size_t pos = 0;
	skipSpaceComments(text, pos);
	return pos >= text.size();
}

std::string readIdentifier(const std::string& text, std::size_t& pos, const char* what) {
	skipSpaceComments(text, pos);
	if (pos >= text.size()) {
		throw IllegalArgumentException(std::string("SQL: expected ") + what);
	}
	if (text[pos] == '"') {
		++pos;
		std::string out;
		while (pos < text.size()) {
			if (text[pos] == '"') {
				if (pos + 1 < text.size() && text[pos + 1] == '"') {
					out.push_back('"');
					pos += 2;
					continue;
				}
				++pos;
				return out;
			}
			out.push_back(text[pos++]);
		}
		throw IllegalArgumentException(std::string("SQL: unterminated quoted ") + what);
	}
	if (!isIdentStart(text[pos])) {
		throw IllegalArgumentException(std::string("SQL: expected ") + what);
	}
	const std::size_t begin = pos;
	++pos;
	while (pos < text.size() && isIdentChar(text[pos])) { ++pos; }
	return text.substr(begin, pos - begin);
}

std::string stripComments(const std::string& text) {
	std::string out;
	std::size_t pos = 0;
	while (pos < text.size()) {
		const char c = text[pos];
		if (c == '\'' || c == '"') {
			const char quote = c;
			out.push_back(c);
			++pos;
			while (pos < text.size()) {
				out.push_back(text[pos]);
				if (text[pos] == quote) {
					if (pos + 1 < text.size() && text[pos + 1] == quote) {
						out.push_back(text[pos + 1]);
						pos += 2;
						continue;
					}
					++pos;
					break;
				}
				++pos;
			}
			continue;
		}
		if (c == '-' && pos + 1 < text.size() && text[pos + 1] == '-') {
			pos += 2;
			while (pos < text.size() && text[pos] != '\n') { ++pos; }
			out.push_back(' ');
			continue;
		}
		if (c == '/' && pos + 1 < text.size() && text[pos + 1] == '*') {
			pos += 2;
			while (pos + 1 < text.size()
					&& !(text[pos] == '*' && text[pos + 1] == '/')) {
				++pos;
			}
			pos = std::min(text.size(), pos + 2);
			out.push_back(' ');
			continue;
		}
		out.push_back(c);
		++pos;
	}
	return out;
}

std::size_t findMatchingParen(const std::string& text, std::size_t open) {
	int depth = 0;
	std::size_t pos = open;
	while (pos < text.size()) {
		const char c = text[pos];
		if (c == '\'' || c == '"') {
			const char quote = c;
			++pos;
			while (pos < text.size()) {
				if (text[pos] == quote) {
					if (pos + 1 < text.size() && text[pos + 1] == quote) {
						pos += 2;
						continue;
					}
					++pos;
					break;
				}
				++pos;
			}
			continue;
		}
		if (c == '(') { ++depth; }
		else if (c == ')') {
			--depth;
			if (depth == 0) { return pos; }
		}
		++pos;
	}
	throw IllegalArgumentException("SQL: unbalanced parentheses");
}

std::vector<std::string> splitTopLevel(const std::string& text, char separator) {
	std::vector<std::string> out;
	std::size_t start = 0;
	int depth = 0;
	std::size_t pos = 0;
	while (pos < text.size()) {
		const char c = text[pos];
		if (c == '\'' || c == '"') {
			const char quote = c;
			++pos;
			while (pos < text.size()) {
				if (text[pos] == quote) {
					if (pos + 1 < text.size() && text[pos + 1] == quote) {
						pos += 2;
						continue;
					}
					++pos;
					break;
				}
				++pos;
			}
			continue;
		}
		if (c == '(') { ++depth; }
		else if (c == ')') { --depth; }
		else if (c == separator && depth == 0) {
			out.push_back(text.substr(start, pos - start));
			start = pos + 1;
		}
		++pos;
	}
	out.push_back(text.substr(start));
	return out;
}

std::string normalizeValue(const std::string& raw) {
	const std::string token = trim(stripComments(raw));
	if (token.empty()) {
		throw IllegalArgumentException("SQL: empty value in INSERT");
	}
	const char first = token.front();
	if (first == '\'' || first == '"') {
		const char quote = first;
		if (token.size() < 2 || token.back() != quote) {
			throw IllegalArgumentException("SQL: unterminated string literal");
		}
		std::string content;
		for (std::size_t i = 1; i + 1 < token.size(); ++i) {
			if (token[i] == quote) {
				if (i + 2 < token.size() && token[i + 1] == quote) {
					content.push_back(quote);
					++i;
					continue;
				}
				throw IllegalArgumentException("SQL: invalid string literal");
			}
			content.push_back(token[i]);
		}
		return quoteSql(content);
	}
	/* $var / $(expr) / - / 裸词 / 数字：一律按文本驻留，保留原始拼写
	 * （0x40 不能变成 64、1.00 不能变成 1.0）。 */
	return quoteSql(token);
}

std::string processInsert(const std::string& statement) {
	const std::string commentsRemoved = stripComments(statement);
	const std::string upperText = upper(commentsRemoved);
	const std::size_t valuesPos = upperText.find("VALUES");
	if (valuesPos == std::string::npos) {
		throw IllegalArgumentException("SQL: INSERT requires VALUES");
	}
	const std::size_t open = commentsRemoved.find('(', valuesPos);
	if (open == std::string::npos) {
		throw IllegalArgumentException("SQL: INSERT requires a value list");
	}
	const std::size_t close = findMatchingParen(commentsRemoved, open);
	const std::string body = commentsRemoved.substr(open + 1, close - open - 1);
	const std::vector<std::string> values = splitTopLevel(body, ',');
	std::string joined;
	for (std::size_t i = 0; i < values.size(); ++i) {
		if (i != 0) { joined += ", "; }
		joined += normalizeValue(values[i]);
	}
	return commentsRemoved.substr(0, open + 1) + joined + commentsRemoved.substr(close);
}

void validateInsert(const std::string& statement, const std::vector<Table>& schema) {
	const std::string text = stripComments(statement);
	std::size_t pos = 0;
	skipSpaceComments(text, pos);
	if (pos + 6 > text.size() || upper(text.substr(pos, 6)) != "INSERT") {
		throw IllegalArgumentException("SQL: expected INSERT");
	}
	pos += 6;
	skipSpaceComments(text, pos);
	if (pos + 4 > text.size() || upper(text.substr(pos, 4)) != "INTO") {
		throw IllegalArgumentException("SQL: expected INTO");
	}
	pos += 4;
	const std::string tableName = readIdentifier(text, pos, "table name");
	skipSpaceComments(text, pos);
	if (pos >= text.size() || text[pos] != '(') {
		throw IllegalArgumentException("SQL: INSERT requires a column list");
	}
	const std::size_t close = findMatchingParen(text, pos);
	const std::string columnsText = text.substr(pos + 1, close - pos - 1);
	std::vector<std::string> columns;
	for (const std::string& raw : splitTopLevel(columnsText, ',')) {
		std::size_t columnPos = 0;
		columns.push_back(readIdentifier(raw, columnPos, "column name"));
	}

	const Table* table = nullptr;
	for (const Table& candidate : schema) {
		if (candidate.name == tableName) { table = &candidate; break; }
	}
	if (table == nullptr) {
		if (schema.empty()) {
			throw IllegalArgumentException("SQL: No table created yet");
		}
		throw IllegalArgumentException("SQL: table is not defined: " + tableName);
	}

	std::set<std::string> seen;
	for (const std::string& column : columns) {
		if (!seen.insert(column).second) {
			throw IllegalArgumentException("SQL: column '" + column + "' listed twice");
		}
		bool found = false;
		for (const Column& declared : table->columns) {
			if (declared.name == column) { found = true; break; }
		}
		if (!found) {
			throw IllegalArgumentException("SQL: no such column: " + column);
		}
	}
	for (const Column& declared : table->columns) {
		if (seen.count(declared.name) == 0) {
			throw IllegalArgumentException("SQL: missing value for column '" + declared.name + "'");
		}
	}
}

Table processCreate(const std::string& statement) {
	std::size_t pos = 0;
	skipSpaceComments(statement, pos);
	if (pos + 6 > statement.size() || upper(statement.substr(pos, 6)) != "CREATE") {
		throw IllegalArgumentException("SQL: expected CREATE");
	}
	pos += 6;
	skipSpaceComments(statement, pos);
	if (pos + 5 > statement.size() || upper(statement.substr(pos, 5)) != "TABLE") {
		throw IllegalArgumentException("SQL: expected TABLE");
	}
	pos += 5;
	Table table;
	table.name = readIdentifier(statement, pos, "table name");
	skipSpaceComments(statement, pos);
	if (pos >= statement.size() || statement[pos] != '(') {
		throw IllegalArgumentException("SQL: expected '(' after table name");
	}
	const std::size_t close = findMatchingParen(statement, pos);
	const std::string body = statement.substr(pos + 1, close - pos - 1);
	for (const std::string& raw : splitTopLevel(body, ',')) {
		const std::string definition = trim(stripComments(raw));
		if (definition.empty()) {
			throw IllegalArgumentException("SQL: empty column definition");
		}
		std::size_t colPos = 0;
		Column column;
		column.name = readIdentifier(definition, colPos, "column name");
		skipSpaceComments(definition, colPos);
		const std::size_t typeBegin = colPos;
		while (colPos < definition.size() && isIdentChar(definition[colPos])) { ++colPos; }
		if (typeBegin == colPos) {
			throw IllegalArgumentException("SQL: missing column type for '" + column.name + "'");
		}
		const std::string typeText = upper(definition.substr(typeBegin, colPos - typeBegin));
		if (typeText != "STRING" && typeText != "NUMBER") {
			throw IllegalArgumentException("SQL: column type must be String or Number for '"
				+ column.name + "'");
		}
		column.type = typeText == "STRING" ? "String" : "Number";
		skipSpaceComments(definition, colPos);
		if (colPos < definition.size()) {
			throw IllegalArgumentException("SQL: unexpected text after column type for '"
				+ column.name + "'");
		}
		for (const Column& existing : table.columns) {
			if (existing.name == column.name) {
				throw IllegalArgumentException("SQL: duplicate column '" + column.name + "'");
			}
		}
		table.columns.push_back(std::move(column));
	}
	return table;
}

std::string normalizedCreate(const Table& table) {
	std::string out = "CREATE TABLE " + quoteIdent(table.name) + " (";
	for (std::size_t i = 0; i < table.columns.size(); ++i) {
		if (i != 0) { out += ", "; }
		out += quoteIdent(table.columns[i].name) + " TEXT NOT NULL";
	}
	out += ");";
	return out;
}

void execute(sqlite3* db, const std::string& sql) {
	char* error = nullptr;
	const int rc = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &error);
	if (rc != SQLITE_OK) {
		std::string message = error != nullptr ? error : sqlite3_errmsg(db);
		sqlite3_free(error);
		throw IllegalArgumentException("SQL: " + message);
	}
}

void validateNumberColumn(const std::string& table, const Column& column,
		const std::string& value) {
	if (column.type != "Number") { return; }
	const std::string text = trim(value);
	if (text.size() >= 3 && text.rfind("$(", 0) == 0 && text.back() == ')') {
		return;  // 表达式在运行期求值，解析期只校验语法（由表达式层负责）
	}
	if (!isNumericLiteral(text)) {
		throw IllegalArgumentException("Column '" + column.name + "' of table '"
			+ table + "' is declared Number: invalid value '" + text + "'");
	}
}

std::deque<mt::MatrixObject> readTables(sqlite3* db, const std::vector<Table>& schema) {
	std::deque<mt::MatrixObject> tables;
	for (const Table& table : schema) {
		const std::string sql = "SELECT * FROM " + quoteIdent(table.name) + " ORDER BY rowid";
		sqlite3_stmt* stmt = nullptr;
		if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
			throw IllegalArgumentException("SQL: cannot read table '" + table.name + "': "
				+ std::string(sqlite3_errmsg(db)));
		}
		mt::MatrixBuilder builder;
		builder.name(table.name);
		for (const Column& column : table.columns) { builder.item(column.name); }
		builder.line(1);
		std::int64_t rowNumber = 1;
		while (sqlite3_step(stmt) == SQLITE_ROW) {
			++rowNumber;
			for (int index = 0; index < sqlite3_column_count(stmt); ++index) {
				const unsigned char* text = sqlite3_column_text(stmt, index);
				if (text == nullptr) {
					sqlite3_finalize(stmt);
					throw IllegalArgumentException("SQL: NULL value in table '" + table.name + "'");
				}
				const std::string value = reinterpret_cast<const char*>(text);
				if (index < static_cast<int>(table.columns.size())) {
					validateNumberColumn(table.name, table.columns[index], value);
				}
				builder.item(value);
			}
			builder.line(rowNumber);
		}
		sqlite3_finalize(stmt);
		tables.push_back(builder.take());
	}
	return tables;
}

std::string readAll(Reader& input) {
	std::string text;
	int c = 0;
	while ((c = input.read()) >= 0) {
		text.push_back(static_cast<char>(c));
		if (text.size() > kMaxScriptBytes) {
			throw ScriptTooLarge(kMaxScriptBytes, "structure script");
		}
	}
	return text;
}

} // namespace

std::deque<mt::MatrixObject> SqlEngine::loadStructure(Reader& input) {
	return loadStructure(readAll(input));
}

std::deque<mt::MatrixObject> SqlEngine::loadStructure(const std::string& text) {
	if (text.find('\0') != std::string::npos) {
		throw IllegalArgumentException("SQL input contains a NUL character");
	}
	sqlite3* db = nullptr;
	if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
		throw IllegalArgumentException("SQL: cannot open in-memory database");
	}
	std::vector<Table> schema;
	try {
		std::size_t start = 0;
		while (start < text.size()) {
			std::size_t end = std::string::npos;
			std::string buffer;
			for (std::size_t i = start; i < text.size(); ++i) {
				buffer.push_back(text[i]);
				if (text[i] == ';' && sqlite3_complete(buffer.c_str()) != 0) {
					end = i + 1;
					break;
				}
			}
			if (end == std::string::npos) {
				if (isBlank(text.substr(start))) { break; }
				throw IllegalArgumentException(
					"SQL: unexpected end of script (statements must end with ';')");
			}
			const std::string statement = text.substr(start, end - start);
			start = end;
			if (isBlank(statement)) { continue; }
			std::size_t keywordPos = 0;
			skipSpaceComments(statement, keywordPos);
			const std::size_t keywordBegin = keywordPos;
			while (keywordPos < statement.size()
					&& std::isalpha(static_cast<unsigned char>(statement[keywordPos])) != 0) {
				++keywordPos;
			}
			const std::string keyword = upper(statement.substr(
				keywordBegin, keywordPos - keywordBegin));
			if (keyword == "CREATE") {
				Table table = processCreate(statement);
				for (const Table& existing : schema) {
					if (existing.name == table.name) {
						throw IllegalArgumentException("SQL: duplicate CREATE TABLE '"
							+ table.name + "'");
					}
				}
				execute(db, normalizedCreate(table));
				schema.push_back(std::move(table));
			} else if (keyword == "INSERT") {
				validateInsert(statement, schema);
				execute(db, processInsert(statement));
			} else {
				if (keyword.empty()) {
					throw IllegalArgumentException("SQL: unexpected ';'");
				}
				throw IllegalArgumentException("SQL: " + keyword
					+ " cannot appear in a structure script; only CREATE TABLE and"
					" INSERT INTO are allowed");
			}
		}
		/* 按 CREATE 声明序返回；schema 保留原始 String/Number 类型
		 * （SQLite 侧统一建为 TEXT 以保留字面拼写）。 */
		auto tables = readTables(db, schema);
		sqlite3_close(db);
		return tables;
	} catch (...) {
		sqlite3_close(db);
		throw;
	}
}

} // namespace bot
