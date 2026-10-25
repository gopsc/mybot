#pragma once
/* agenttools_fixtures.hpp —— test_agenttools* 系列单测共用的构造助手
 *
 * 2026-10-01 test_agenttools.cpp 按 TU 拆分时，四个跨域 helper 随迁于此
 * （与 fixtures.hpp / robot_fixtures.hpp 同一形态：只放「把字符串变成被测
 * 对象」的样板，全部直走生产代码公开接口）。各 TU 以 using 声明按需引名，
 * 用例体零改动；模块路径守卫用 fx::ModulePathGuard（fixtures.hpp 单点）。
 */

#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

#include "agenttools.hpp"
#include "robot.hpp"

namespace fs = std::filesystem;

namespace afx {

inline std::string readAll(const std::string& path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) { throw std::runtime_error("测试夹具不可读: " + path); }
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

/* 无硬件自检机器人（relay-test）：结构脚本与动作脚本都在仓库里，
 * agent 工具的真实执行路径可以完全离线跑通 */
inline std::unique_ptr<bot::RobotStruct> makeRelayRobot() {
	std::string sql = readAll("robots/relay-test.sql");
	bot::MemoryReader reader(std::move(sql));
	auto robot = std::make_unique<bot::RobotStruct>(reader);
	robot->active();
	return robot;
}

inline void writeFile(const fs::path& p, const std::string& content) {
	fs::create_directories(p.parent_path());
	std::ofstream f(p, std::ios::binary);
	f << content;
}

/* 绝大多数工具只回文本；测试里只关心文本时用这个薄封装 */
inline std::string execText(const bot::agent::AgentToolRegistry& reg, const std::string& name,
		const bot::Json& args) {
	return reg.execute(name, args).text;
}

} // namespace afx
