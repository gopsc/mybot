/* test_action_scope.cpp —— 块级 @Alias/@Vars 词法作用域（当前 Python 对齐） */

#include <deque>
#include <memory>
#include <string>

#include "action_runner.hpp"
#include "daemon_registry.hpp"
#include "fixtures.hpp"
#include "hal.hpp"
#include "harness.hpp"
#include "hw_factory.hpp"
#include "hw_registry.hpp"
#include "meta_registry.hpp"
#include "util_except.hpp"

namespace {

struct Fixture {
	bot::HwRegistry registry;
	bot::DaemonRegistry daemons;
	bot::MetaRegistry metas;
	bot::HALManager hal;
	bot::HwFactory factory;
	std::string seen;

	Fixture()
		: factory(registry, daemons, metas, hal) {
		registry.add("dev", std::unique_ptr<bot::MatrixVars_Hardware>(
			new fx::LambdaHw([this](const bot::Json& input) {
				const bot::Json* value = input.find("x");
				if (value != nullptr) {
					if (value->isStr()) { seen = value->getValue(); }
					else if (value->isInt()) { seen = std::to_string(value->getInt()); }
					else if (value->isFloat()) {
						seen = std::to_string(static_cast<long long>(value->getFloat()));
					}
				}
				bot::Json ok = bot::JsonObject();
				ok.put("result", bot::JsonString("OK"));
				if (value != nullptr) { ok.put("value", *value); }
				return ok;
			})));
	}
};

std::vector<mt::MatrixObject> actionScript(const std::string& text) {
	return fx::manyMatrices(text);
}

} // namespace

TH_TEST(action_scope_local_vars_shadow_then_restore) {
	Fixture fixture;
	mt::MatrixBuilder vars;
	vars.name("Vars");
	vars.item("name");
	vars.item("value");
	vars.line(1);
	vars.item("n");
	vars.item("3");
	vars.line(2);
	std::deque<mt::MatrixObject> structure;
	structure.push_back(vars.take());
	fixture.factory.createHardVars(structure);

	auto matrices = actionScript(
		"@Action\n"
		"@Vars\n"
		"name value;\n"
		"n 7;\n"
		"@\n"
		"dev.x;\n"
		"$(n);\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	runner.runAction(matrices);
	TH_CHECK(fixture.seen == "7");
	/* 块出口恢复结构 Vars：结构值 3 重新可见。 */
	bot::MatrixVars_Hardware* restored = fixture.registry.find("n");
	TH_CHECK(restored != nullptr);
	TH_CHECK(restored->play(bot::JsonObject()).asString().getValue() == "3");
}

TH_TEST(action_scope_local_alias_disappears_after_the_block) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Action\n"
		"@Alias\n"
		"name alias;\n"
		"tag hello;\n"
		"@\n"
		"dev.x;\n"
		"$(tag);\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	runner.runAction(matrices);
	TH_CHECK(fixture.seen == "hello");
	TH_CHECK(fixture.registry.find("tag") == nullptr);
}

TH_TEST(action_scope_duplicate_local_declaration_is_rejected) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Action\n"
		"@Vars\n"
		"name value;\n"
		"n 1;\n"
		"n 2;\n"
		"@\n"
		"dev.x;\n"
		"$(n);\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Duplicate",
		runner.runAction(matrices));
}

TH_TEST(action_scope_local_declaration_cannot_replace_a_driver) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Action\n"
		"@Alias\n"
		"name alias;\n"
		"dev other;\n"
		"@\n"
		"dev.x;\n"
		"1;\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot replace",
		runner.runAction(matrices));
}

TH_TEST(action_named_reflex_binds_parameters) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Reflex(echo)\n"
		"dev.x;\n"
		"$(v);\n"
		"@\n"
		"@Action\n"
		"echo.v;\n"
		"     5;\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	runner.runAction(matrices);
	TH_CHECK(fixture.seen == "5");
}

TH_TEST(action_named_reflex_capture_feeds_later_action) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Reflex(echo)\n"
		"dev.x;\n"
		"$(v);\n"
		"@\n"
		"@Action\n"
		"echo.v echo.cap;\n"
		"     5 $cap=value;\n"
		"@\n"
		"@Action\n"
		"dev.x;\n"
		"$(cap);\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	runner.runAction(matrices);
	TH_CHECK(fixture.seen == "5");
	TH_CHECK(fixture.registry.find("cap") != nullptr);
}

TH_TEST(action_named_reflex_duplicate_definition_is_rejected) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Reflex(echo)\n"
		"dev.x;\n"
		"1;\n"
		"@\n"
		"@Reflex(echo)\n"
		"dev.x;\n"
		"2;\n"
		"@\n"
		"@Action\n"
		"dev.x;\n"
		"1;\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Duplicate Reflex",
		runner.runAction(matrices));
}

TH_TEST(action_named_reflex_argument_cannot_replace_a_driver) {
	Fixture fixture;
	auto matrices = actionScript(
		"@Reflex(bad)\n"
		"dev.x;\n"
		"$(dev);\n"
		"@\n"
		"@Action\n"
		"bad.dev;\n"
		"      1;\n"
		"@\n");
	bot::ActionRunner runner(fixture.registry, fixture.factory);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot replace",
		runner.runAction(matrices));
}
