#pragma once
/* fixtures.hpp —— 单测共用的最小构造助手
 *
 * 只放「把字符串变成被测对象」这一类样板，不放断言逻辑；
 * 每个 helper 都直接走生产代码路径（MatrixParser / Lexer / RobotStruct 构造函数），
 * 不自己拼装内部状态，这样测试与实现的耦合点保持在公开接口上。
 */

#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "hardware.hpp"
#include "matrix.hpp"
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include <filesystem>
#include <fstream>
#include <string>

#include "sqlparse.hpp"
#include "util_except.hpp"

namespace fx {

/* 测试用 lambda 硬件变量：play 委托给注入的函数对象（基类已是纯虚接口，
 * 测试不能再直接 new MatrixVars_Hardware(lambda)） */
class LambdaHw : public bot::MatrixVars_Hardware {
	std::function<bot::Json(const bot::Json&)> fn_;
public:
	explicit LambdaHw(std::function<bot::Json(const bot::Json&)> fn) : fn_(std::move(fn)) {}
	bot::Json play(const bot::Json& in) override { return fn_(in); }
	const char* kindName() const override { return "test-lambda"; }
};

/* 什么都不做的硬件变量（play 回 JsonNull）：注册表与派发用例里最常见的填充物。
 * 原为 test_robot_dispatch.cpp 的局部 helper，2026-10-04 随 HwRegistry 门面单测
 * 拆出 test_hw_registry.cpp 后上收——两个文件共用一份，避免各留一个同名包装。 */
inline std::unique_ptr<bot::MatrixVars_Hardware> dummyHw() {
	return std::unique_ptr<bot::MatrixVars_Hardware>(new LambdaHw(
		[](const bot::Json&) { return bot::JsonNull(); }));
}

/* 解析出恰好一个矩阵对象；解析失败或多解都视为用例前置条件不成立 */
inline mt::MatrixObject oneMatrix(const std::string& text) {
	bot::MemoryReader reader(text);
	mt::MatrixParser parser(reader);
	auto mat = parser.parse();
	if (!mat) { throw std::runtime_error("前置条件失败：parse() 未产出矩阵（输入格式有误）"); }
	if (parser.parse()) {
		throw std::runtime_error("前置条件失败：输入含多个矩阵，请改用 manyMatrices()");
	}
	return std::move(*mat);
}

/* 按声明序解析出全部矩阵对象（等价 RobotStruct::readMatrix 的公开等价物） */
inline std::vector<mt::MatrixObject> manyMatrices(const std::string& text) {
	bot::MemoryReader reader(text);
	mt::MatrixParser parser(reader);
	std::vector<mt::MatrixObject> out;
	while (auto mat = parser.parse()) { out.push_back(std::move(*mat)); }
	return out;
}

/* 结构脚本词元序列（Lexer::parseAll 是 readSQL 的前半段，本身即被测面） */
inline std::vector<sql4cj::Token> tokens(const std::string& text) {
	bot::MemoryReader reader(text);
	return sql4cj::Lexer::parseAll(reader);
}

/* 词元类型序列的可读指纹，便于一次性比对整条 token 流 */
inline std::string fingerprint(const std::vector<sql4cj::Token>& ts) {
	std::string out;
	for (const auto& t : ts) {
		if (!out.empty()) { out += ' '; }
		out += t.serialize();
	}
	return out;
}

/* 语法分析器事件流（Parser::next 的完整序列，词法→语法两段测试共用；
 * 2026-10-01 自 test_sqlparse.cpp 上收，fx::tokens 的姊妹件） */
inline std::vector<sql4cj::Event> events(const std::string& text) {
	std::vector<sql4cj::Token> ts = fx::tokens(text);
	sql4cj::Parser parser(ts);
	std::vector<sql4cj::Event> out;
	for (;;) {
		sql4cj::Event e = parser.next();
		if (e.type == sql4cj::EventType::END) { break; }
		out.push_back(std::move(e));
	}
	return out;
}

/* 单元格取值的窄化助手
 * MatrixObject::operator() 同时提供 (size_t,size_t) 与 (int64_t,int64_t) 两个重载，
 * 传字面量 int 会命中「两条同为整型转换」的二义性；测试里统一走这两个
 * 显式 int64_t 形参的包装，顺带让「负下标防线」在调用点读起来就是负数。 */
inline const std::string& cell(const mt::MatrixObject& m, std::int64_t row, std::int64_t col) {
	return m(row, col);
}

/* 同上，走 "-" 前向填充视图 */
inline const std::string& inh(const mt::MatrixObject& m, std::int64_t row, std::int64_t col) {
	return m.inherited(row, col);
}


/* ---- 共享测试基建（阶段 4：自 test_llmconfig/test_agenttools 上收）---- */

/* 临时目录：构造即建，析构即清（getpid 隔离并行进程） */
class TempDir {
	std::filesystem::path dir_;

public:
	explicit TempDir(const std::string& tag) {
		dir_ = std::filesystem::temp_directory_path()
			/ ("mybot_test_" + tag + "_" + std::to_string(::getpid()));
		std::error_code ec;
		std::filesystem::remove_all(dir_, ec);
		std::filesystem::create_directories(dir_);
	}
	~TempDir() {
		std::error_code ec;
		std::filesystem::remove_all(dir_, ec);
	}
	TempDir(const TempDir&) = delete;
	TempDir& operator=(const TempDir&) = delete;
	const std::filesystem::path& path() const { return dir_; }
};

/* 环境变量守卫：析构恢复原值，用例之间不得互相污染 */
class EnvVar {
	std::string name_;
	std::string old_;
	bool had_ = false;

public:
	EnvVar(const std::string& name, const char* value) : name_(name) {
		const char* v = std::getenv(name.c_str());
		had_ = v != nullptr;
		if (had_) { old_ = v; }
		/* value=nullptr 表示「清掉该变量」——NoKeyEnv 等用例依赖此语义 */
		if (value == nullptr) { ::unsetenv(name.c_str()); }
		else { ::setenv(name.c_str(), value, 1); }
	}
	~EnvVar() {
		if (had_) { ::setenv(name_.c_str(), old_.c_str(), 1); }
		else { ::unsetenv(name_.c_str()); }
	}
	EnvVar(const EnvVar&) = delete;
	EnvVar& operator=(const EnvVar&) = delete;
};

/* 模块路径守卫：让驱动解析路径同时看到真模块树与测试夹具目录
 * （modules 在前，与生产语义一致：同名以 modules 为准）。退出时还原，
 * 避免影响其它用例。2026-10-01 自 test_agenttools 上收（test_robot 系
 * 原有一份 const char* 构造的同名类，robot_fixtures.hpp 侧同步改用本类）。 */
class ModulePathGuard {
	std::string old_;
	bool had_ = false;

public:
	explicit ModulePathGuard(const std::string& path) {
		const char* v = std::getenv("BOT4CJ_MODULE_PATH");
		had_ = v != nullptr;
		if (had_) { old_ = v; }
		::setenv("BOT4CJ_MODULE_PATH", path.c_str(), 1);
	}
	~ModulePathGuard() {
		if (had_) { ::setenv("BOT4CJ_MODULE_PATH", old_.c_str(), 1); }
		else { ::unsetenv("BOT4CJ_MODULE_PATH"); }
	}
	ModulePathGuard(const ModulePathGuard&) = delete;
	ModulePathGuard& operator=(const ModulePathGuard&) = delete;
};

} // namespace fx
