#pragma once
/* robot_internals.hpp —— RobotStruct 私有装配体（门面内部件，2026-10-04）
 *
 * 装配机械（HwFactory / ActionRunner / HotSqlService）是门面的实现细节，不在
 * 公开面上：此前三个成员（factory_ / runner_ / hotSql_）直接住在 robot.hpp 里，
 * 消费者每包含一次门面就要连带解析 action_runner.hpp / hw_factory.hpp /
 * hotsql_service.hpp 三个内部头。现在整体收进 RobotStruct::Internals，门面头
 * 只剩「四个域门面 + 生命周期/执行方法」。
 *
 * 成员声明序与拆分前逐字同序（factory → runner → hotSql）：hotSql 依赖前两者
 * 与四个域门面，故排最后；构造序由声明序保证。
 *
 * 只被实现单元（robot_lifecycle.cpp / robot_actions.cpp / robot_hotsql.cpp）
 * 包含——不属于公开包含面，门面消费者依然只包含 robot.hpp。
 */

#include "robot.hpp"

#include "action_runner.hpp"
#include "daemon_registry.hpp"
#include "hotsql_service.hpp"
#include "hw_factory.hpp"
#include "hw_registry.hpp"
#include "meta_registry.hpp"
#include "structure_store.hpp"

namespace bot {

/* 类外定义的私有嵌套类（pImpl 惯用式）：除门面成员函数外无人能命名它。
 * 四个构造参数是门面里声明序在前的四个域门面（引用绑定不要求对象已构造，
 * 但 Internals 声明在它们之后，构造时它们必然已就绪）。 */
struct RobotStruct::Internals {
	HwFactory factory;
	ActionRunner runner;
	HotSqlService hotSql;

	Internals(StructureStore& structures, HwRegistry& registry, MetaRegistry& metas,
			DaemonRegistry& daemons)
		: factory(registry, daemons, metas), runner(registry),
		  hotSql(structures, registry, metas, daemons, factory, runner) {}
};

} // namespace bot