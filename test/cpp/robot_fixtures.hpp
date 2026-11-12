#pragma once
/* robot_fixtures.hpp —— test_robot* 系列单测共用的构造/观测助手
 *
 * 2026-10-01 test_robot.cpp 按 TU 拆分时，九个跨域 helper（SQL 夹具、
 * 结构装配器、矩阵取格、探针落痕、热 SQL 报错）随迁于此——与 fixtures.hpp
 * 同一形态：只放「把字符串变成被测对象/可观测证据」的样板，不放断言逻辑，
 * 全部直走生产代码公开接口。各 TU 以 using 声明按需引名，用例体零改动。
 */

#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>

#include "matrix.hpp"
#include "robot.hpp"
#include "util_except.hpp"

namespace fs = std::filesystem;

namespace rfx {

const char* const kBasicSql =
	"/* 结构脚本自检夹具\n"
	"   多行块注释里出现 ; , ( ) 都不应影响解析 */\n"
	"CREATE TABLE Timer (\n"
	"\tname String\n"
	");\n"
	"INSERT INTO Timer (name) VALUES ('timer-0'); -- 行注释\n"
	"\n"
	"CREATE TABLE Relay (\n"
	"\tname       String,\n"
	"\tcontroller String,\n"
	"\tnote       String\n"
	");\n"
	"INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');\n";

/* 只做结构脚本装配，返回报错文本（无异常返回空串） */
inline std::string sqlError(const std::string& sql) {
	try {
		bot::MemoryReader reader(sql);
		bot::RobotStruct robot(reader);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

/* 跑一遍「结构脚本 + 动作脚本」，返回报错文本（无异常返回空串） */
inline std::string runTexts(const std::string& sql, const std::string& mt) {
	try {
		bot::MemoryReader sr(sql);
		bot::RobotStruct robot(sr);
		bot::MemoryReader mr(mt);
		robot.run(mr);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

/* 同上，但把 injectVars 透传给 run() 的会话别名注入口（#34 条件反射的工具侧
 * 「函数实参」入口）——脚本里的 $(键) 就地取注入值。 */
inline std::string runTexts(const std::string& sql, const std::string& mt,
		const std::map<std::string, std::string>& injectVars) {
	try {
		bot::MemoryReader sr(sql);
		bot::RobotStruct robot(sr);
		bot::MemoryReader mr(mt);
		robot.run(mr, injectVars);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

/* 只做 SQL → 矩阵对象（不经硬件装配），用于断言 INSERT 落位 */
inline std::deque<mt::MatrixObject> loadMatrices(const std::string& sql) {
	std::deque<mt::MatrixObject> out;
	bot::MemoryReader reader(sql);
	bot::ScriptLoader::readSQL(reader, out);
	return out;
}

/* 显式 size_t 下标：MatrixObject 同时有 size_t 与 int64_t 两个 operator()，
 * 字面量实参会在两个整型转换间产生歧义 */
inline std::string cell(const mt::MatrixObject& m, std::size_t r, std::size_t c) { return m(r, c); }

inline std::string markerOf(const fs::path& p) {
	std::ifstream f(p, std::ios::binary);
	if (!f) { return std::string(); }
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

inline std::string probeSql(const fs::path& marker) {
	return "CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n";
}

/* applySql 的报错文本（无异常返回空串） */
inline std::string hotSqlError(bot::RobotStruct& robot, const std::string& sql) {
	try {
		robot.applySql(sql);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

} // namespace rfx
