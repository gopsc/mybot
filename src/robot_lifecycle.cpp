/* robot_lifecycle.cpp —— RobotStruct 生命周期与资源安全边界 */

#include "robot.hpp"
#include "robot_internals.hpp"

#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include "util_env.hpp"

namespace bot {

/* 装配机械的定义见 robot_internals.hpp；本处只负责「先四域、后机械、再装载」
 * 的次序（注释在头文件构造函数声明处）。 */
RobotStruct::RobotStruct(bot::Reader& input)
	: internals_(std::make_unique<Internals>(structures_, registry_, metas_, daemons_)) {
	structures_.load(input);
}

void RobotStruct::active() {
	if (state_ == LifecycleState::Active || state_ == LifecycleState::Deactivating) {
		throw IllegalArgumentException("机器人生命周期状态不允许 active()：当前状态非 Loaded/Inactive");
	}

	/* 先标记为 Active：中途失败时析构仍会进入统一清理路径。 */
	state_ = LifecycleState::Active;
	deactivated_ = false;
	internals_->factory.createHardVars(structures_.all());
	metas_.validateAll();

	for (MatrixVars_Hardware* item : registry_.sequence()) {
		if (stopRequested()) {
			throw std::runtime_error("上电被中断（收到停止信号）：已装配的器件正在断电");
		}
		item->build();
	}
}

void RobotStruct::deactivate() {
	if (state_ == LifecycleState::Loaded || state_ == LifecycleState::Inactive) { return; }
	state_ = LifecycleState::Deactivating;

	daemons_.stopBarrier(deactivateGraceMs_, "Deactivate",
		"hardware de-init will race with them (they may touch the"
		" bus after de-init)");

	std::string lastWarn;
	std::size_t failed = 0;
	const auto& seq = registry_.sequence();
	for (auto it = seq.rbegin(); it != seq.rend(); ++it) {
		try {
			(*it)->destroy();
		} catch (const std::exception& e) {
			++failed;
			if (std::string(e.what()) != lastWarn) {
				std::cerr << "Deactive warning: " << e.what() << std::endl;
				lastWarn = e.what();
			}
		}
	}
	if (failed > 0) {
		std::cerr << "Deactivate: " << failed << " of " << seq.size()
			<< " hardware variable(s) failed to destroy (see warnings above)" << std::endl;
	}
	deactivated_ = true;
	state_ = LifecycleState::Inactive;
}

RobotStruct::~RobotStruct() {
	if (deactivated_) { return; }
	try {
		deactivate();
	} catch (...) {
		std::cerr << "Deactivate: failed during destruction"
			<< " (hardware may remain energized)" << std::endl;
	}
}

} // namespace bot
