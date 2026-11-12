/* cliargs.cpp —— 扁平 CLI 的解析、校验与帮助文本（CLI11） */

#include "cliargs.hpp"

#include <CLI/CLI.hpp>

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "util_cli.hpp"
#include "util_num.hpp"
#include "util_str.hpp"

namespace bot {
namespace {

constexpr double kActionTimeoutMaxSec = 3600.0;

std::string usageError(const std::string& message) {
	return "参数错误：" + message + "；用 --help 查看支持的参数";
}

bool parseTimeout(const std::string& raw, double& out) {
	try {
		std::size_t used = 0;
		double value = std::stod(raw, &used);
		if (used != raw.size() || !std::isfinite(value)
				|| value <= 0 || value > kActionTimeoutMaxSec) {
			return false;
		}
		out = value;
		return true;
	} catch (const std::exception&) {
		return false;
	}
}

} // namespace

ParsedArgs parseArgs(int argc, char** argv) {
	ParsedArgs parsed;
	CliOptions& opts = parsed.opts;

	CLI::App app{"mybot robot controller (Linux, LuaJIT drivers)"};
	app.allow_extras(false);
	app.set_help_flag("--help,-h", "打印帮助");

	std::string robot;
	std::string input;
	app.add_option("--robot", robot, "结构脚本 .sql 路径（必选）");
	app.add_option("--input", input, "动作脚本 .mt 路径；不给则读 stdin");
	app.add_option("--timeout", opts.actionTimeoutSec,
		"动作脚本墙钟预算（秒，>0 且 <=3600，缺省 180）")
		->default_val("180");
	app.add_option("--daemon-grace-ms", opts.daemonGraceMs,
		"守护线程停机宽限（毫秒，0..300000）");

	app.add_option("--var", opts.varSpecs, "会话别名 NAME=VALUE（可重复）")
		->expected(1);
	app.add_option("--var-env", opts.varEnvSpecs, "会话别名 NAME=ENVVAR（可重复）")
		->expected(1);

	try {
		app.parse(argc, argv);
	} catch (const CLI::CallForHelp&) {
		parsed.help = true;
		return parsed;
	} catch (const CLI::ParseError& e) {
		parsed.errorCode = 2;
		parsed.error = usageError(e.what());
		return parsed;
	}

	if (!robot.empty()) { opts.robot = robot; }
	if (!input.empty()) { opts.input = input; }
	return parsed;
}

int validateOptions(CliOptions& opts) {
	if (!opts.actionTimeoutSec.empty()) {
		double timeout = 0;
		if (!parseTimeout(opts.actionTimeoutSec, timeout)) {
			std::cerr << usageError("--timeout 必须是 0.." +
				std::to_string(static_cast<int>(kActionTimeoutMaxSec)) +
				" 秒之间的正数，实际是 '" + opts.actionTimeoutSec + "'") << std::endl;
			return 2;
		}
	}

	if (!opts.daemonGraceMs.empty()
			&& !parseBoundedLong(opts.daemonGraceMs,
				daemon_limits::kGraceMsMin, daemon_limits::kGraceMsMax)) {
		std::cerr << rangeErrorText("选项 --daemon-grace-ms",
			daemon_limits::kGraceMsMin, daemon_limits::kGraceMsMax,
			opts.daemonGraceMs) << std::endl;
		return 2;
	}

	std::map<std::string, std::string> bindings;
	auto bind = [&](const std::string& name, const std::string& value) -> bool {
		if (!isSafeIdent(name)) {
			std::cerr << usageError("变量名 '" + name + "' 不是安全标识符") << std::endl;
			return false;
		}
		if (bindings.count(name) != 0) {
			std::cerr << usageError("--var/--var-env 变量名重复：'" + name + "'")
				<< std::endl;
			return false;
		}
		bindings[name] = value;
		return true;
	};
	for (const std::string& spec : opts.varSpecs) {
		const std::size_t eq = spec.find('=');
		if (eq == std::string::npos) {
			std::cerr << usageError("--var 需要 NAME=VALUE，实际是 '" + spec + "'")
				<< std::endl;
			return 2;
		}
		if (!bind(spec.substr(0, eq), spec.substr(eq + 1))) { return 2; }
	}
	for (const std::string& spec : opts.varEnvSpecs) {
		const std::size_t eq = spec.find('=');
		if (eq == std::string::npos || eq + 1 == spec.size()) {
			std::cerr << usageError("--var-env 需要 NAME=ENVVAR，实际是 '" + spec + "'")
				<< std::endl;
			return 2;
		}
		const std::string name = spec.substr(0, eq);
		const std::string envName = spec.substr(eq + 1);
		const char* value = std::getenv(envName.c_str());
		if (value == nullptr) {
			std::cerr << usageError("--var-env " + name + "：环境变量 '" + envName
				+ "' 未设置") << std::endl;
			return 2;
		}
		if (!bind(name, value)) { return 2; }
	}
	opts.injectVars = std::move(bindings);
	return 0;
}

std::string helpText() {
	return
		"用法:\n"
		"  mybot --robot <结构脚本.sql> [--input <动作脚本.mt>] [选项]\n"
		"  cat action.mt | mybot --robot <结构脚本.sql> [选项]\n"
		"\n"
		"输入源优先级：--input > stdin。\n"
		"\n"
		"选项:\n"
		"  --robot <path>              结构脚本 .sql（必选）\n"
		"  --input <path>              动作脚本 .mt；不给则读 stdin\n"
		"  --timeout <sec>             动作脚本墙钟预算（>0 且 <=3600，缺省 180）\n"
		"  --daemon-grace-ms <ms>      守护线程停机宽限（0..300000，缺省 30000）\n"
		"  --var NAME=VALUE            会话别名注入（可重复）\n"
		"  --var-env NAME=ENVVAR       从环境变量读取会话别名（可重复）\n"
		"  --help, -h                  打印帮助\n"
		"\n"
		"示例:\n"
		"  mybot --robot robots/relay-test.sql --input scripts/relay-test.mt\n";
}

} // namespace bot
