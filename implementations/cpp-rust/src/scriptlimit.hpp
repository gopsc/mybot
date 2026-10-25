#pragma once
/* scriptlimit.hpp —— 脚本输入的字节上限（限流原语的叶子头）
 *
 * 2026-10-04 自 actionsource.hpp 析出（行为保持，纯搬迁）：上限常量、超限异常、
 * 整段受限读取与逐字节受限包装器四样是**同一个关注点**（「输入多大、进程就吃多大
 * 内存」这条护栏），而它们的消费方里有离线矩阵工具（mtmerge / mtinclude）与 agent
 * 工具层（agenttools）——这些 TU 一样都用不到动作输入源与 CliOptions，此前却为了
 * 拿一个上限常量把整个 CLI/动作源域头（连带 <sys/socket.h>、TCP 读取器声明）拉了
 * 进来。析出后它们只引本头。
 *
 * 全部定义都在头内（inline / constexpr）：mtmerge 目标不链接 actionsource.cpp，
 * 只复用头内定义。 */

#include <cstddef>
#include <istream>
#include <memory>
#include <string>
#include <utility>

#include "util_except.hpp"	/* IllegalArgumentException 根异常；Reader 基类 */

namespace bot {

/* 脚本单次输入的字节上限：动作脚本（.mt）与结构脚本（.sql）统一适用。
 * run()/readSQL() 会把输入整体驻留后再装配（@Alias 必须先于 @Action 生效、
 * 矩阵一次性建表），不设上限即等于「输入多大、进程就吃多大内存」；
 * 实测 100MB 动作输入 → RSS 4.2GB。真实脚本为 KB 级，8MiB 已留三个数量级余量。
 * 与 jsonparse.hpp 的 kJsonMaxBytes 同值但**不可合并**——那个是跨进程契约的一环
 * （理由与评估记录见该处注释）。 */
inline constexpr std::size_t kMaxScriptBytes = 8u << 20;

/* 脚本字节数超限。kind 指明输入类别（"action script" / "structure script"）。
 * 重构计划 2.5：直接继承单一根异常 bot::IllegalArgumentException——此前
 * 挂 mt::MatrixParseExcept 让纯 I/O 层倒挂依赖解析层。原文保留性质不变：
 * 抛出点（整段读取 / LimitedReader::read）都在 MatrixParser::parse() 的
 * try 之外，不经其「带行号包装」路径；即便未来 read() 移进 try，IAE 分支
 * 也是包装保留原文而非降级。 */
class ScriptTooLarge : public bot::IllegalArgumentException {
public:
	explicit ScriptTooLarge(std::size_t cap, const std::string& kind = "action script")
		: IllegalArgumentException(kind + " exceeds the byte limit of " + std::to_string(cap)
			+ ". Real bot4cj scripts are KB-sized; a larger input almost certainly means a runaway"
			+ " or malicious producer (the whole script is buffered before playback).") {}
};

/* 整段受限读取：分块累计，超过 cap 立即抛 ScriptTooLarge（inline：mtmerge
 * 目标不链接 actionsource.cpp，只复用头内定义——与 kMaxScriptBytes/ScriptTooLarge
 * 同一惯例）。mtmerge 文件输入与动作 stdin 通道共用；此前两份手写循环
 * 且超限处理不一致（mtmerge 抛、stdin 打印后放弃）——同一上限不该有
 * 两种用户可见行为。先整读再判上限对超大输入形同虚设（限流之前就把
 * 全部字节吃进内存），故块读过程中即时拒绝。 */
inline std::string readAllLimited(std::istream& in, std::size_t cap,
		const std::string& kind = "action script") {
	std::string data;
	char buf[65536];
	for (;;) {
		in.read(buf, static_cast<std::streamsize>(sizeof buf));
		std::streamsize got = in.gcount();
		if (got <= 0) { break; }
		data.append(buf, static_cast<std::size_t>(got));
		if (data.size() > cap) { throw ScriptTooLarge(cap, kind); }
	}
	return data;
}

/* 字节数上限包装器：所有脚本输入通道统一限流（见 openActionSource 与 main.cpp） */
class LimitedReader : public Reader {
	std::unique_ptr<Reader> inner_;
	std::size_t cap_;
	std::string kind_;
	std::size_t seen_ = 0;

public:
	LimitedReader(std::unique_ptr<Reader> inner, std::size_t cap,
			std::string kind = "action script")
		: inner_(std::move(inner)), cap_(cap), kind_(std::move(kind)) {}

	int read() override {
		int c = inner_->read();
		if (c >= 0 && ++seen_ > cap_) { throw ScriptTooLarge(cap_, kind_); }
		return c;
	}
};

} // namespace bot
