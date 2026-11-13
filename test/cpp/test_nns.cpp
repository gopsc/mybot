/* test_nns.cpp —— Nns 原生驱动（nn4cpp 后端）的直接单测与结构表集成测试。 */

#include <cmath>
#include <filesystem>
#include <string>

#include "hal.hpp"
#include "harness.hpp"
#include "native_driver.hpp"
#include "util_except.hpp"

#ifdef MYBOT_HAVE_NN4CPP
#include "robot.hpp"
#endif

namespace {

bot::Json data(std::initializer_list<std::pair<const char*, bot::Json>> items) {
	bot::Json out = bot::JsonObject();
	for (const auto& item : items) { out.put(item.first, item.second); }
	return out;
}

std::string resultOf(const bot::Json& value) {
	const bot::Json* result = value.find("result");
	return result != nullptr && result->isStr() ? result->getValue() : std::string();
}

#ifdef MYBOT_HAVE_NN4CPP
bot::Json makeConfig(const std::string& layers, const std::string& path = "") {
	return data({
		{"layers", bot::JsonString(layers)},
		{"activation", bot::JsonString("Leaky_ReLU")},
		{"output_activation", bot::JsonString("Sigmoid")},
		{"learning_rate", bot::JsonString("0.1")},
		{"optimizer", bot::JsonString("adam")},
		{"seed", bot::JsonString("42")},
		{"path", bot::JsonString(path)},
		{"autosave", bot::JsonString("0")},
	});
}
#endif

} // namespace

TH_TEST(nns_driver_is_registered_only_with_nn4cpp) {
#ifdef MYBOT_HAVE_NN4CPP
	bot::HALManager hal;
	TH_CHECK(bot::makeNnsDriver(hal) != nullptr);
	TH_CHECK(bot::hasNativeDriver("Nns"));
#else
	bot::HALManager hal;
	TH_CHECK(bot::makeNnsDriver(hal) == nullptr);
	TH_CHECK(!bot::hasNativeDriver("Nns"));
#endif
}

#ifdef MYBOT_HAVE_NN4CPP

TH_TEST(nns_driver_creates_predicts_trains_and_reads) {
	bot::HALManager hal;
	auto driver = bot::makeNnsDriver(hal);
	TH_CHECK(driver != nullptr);

	const bot::Json built = driver->build(makeConfig("2,3,1"));
	TH_CHECK(resultOf(built) == "OK");
	TH_CHECK(built.find("layers") != nullptr && built.find("layers")->getValue() == "2,3,1");
	TH_CHECK(built.find("built") != nullptr && built.find("built")->getBool());

	const bot::Json predicted = driver->call(data({
		{"input", bot::JsonString("0,1")},
	}));
	TH_CHECK(resultOf(predicted) == "OK");
	TH_CHECK(predicted.find("output") != nullptr && predicted.find("output")->isArr());
	TH_CHECK(predicted.find("output")->size() == 1);
	TH_CHECK(predicted.find("output0") != nullptr && predicted.find("output0")->isFloat());
	TH_CHECK(std::isfinite(predicted.find("output0")->getFloat()));

	const bot::Json trained = driver->call(data({
		{"input0", bot::JsonFloat(0.0)},
		{"input1", bot::JsonFloat(1.0)},
		{"target0", bot::JsonFloat(1.0)},
		{"discount", bot::JsonFloat(1.0)},
	}));
	TH_CHECK(resultOf(trained) == "OK");
	TH_CHECK(trained.find("loss") != nullptr && trained.find("loss")->isFloat());
	TH_CHECK(std::isfinite(trained.find("loss")->getFloat()));
	TH_CHECK(trained.find("saved") != nullptr && !trained.find("saved")->getBool());

	const bot::Json readBack = driver->read(bot::JsonObject());
	TH_CHECK(resultOf(readBack) == "OK");
	TH_CHECK(readBack.find("output0") != nullptr);
	TH_CHECK(readBack.find("built") != nullptr && readBack.find("built")->getBool());

	const bot::Json info = driver->call(data({
		{"command", bot::JsonString("info")},
	}));
	TH_CHECK(resultOf(info) == "OK");
	TH_CHECK(info.find("parameters") != nullptr && info.find("parameters")->getInt() > 0);
}

TH_TEST(nns_driver_saves_and_loads_model) {
	const std::filesystem::path path =
		std::filesystem::temp_directory_path() / "mybot_nns_model_test.nn";
	std::filesystem::remove(path);

	bot::HALManager hal;
	auto first = bot::makeNnsDriver(hal);
	const bot::Json created = first->build(makeConfig("2,3,1", path.string()));
	TH_CHECK(resultOf(created) == "OK");
	TH_CHECK(created.find("source") != nullptr && created.find("source")->getValue() == "create");
	TH_CHECK(std::filesystem::exists(path));

	const bot::Json before = first->call(data({
		{"input", bot::JsonString("0.25,-0.5")},
	}));
	TH_CHECK(resultOf(before) == "OK");
	const double value = before.find("output0")->getFloat();

	auto second = bot::makeNnsDriver(hal);
	const bot::Json loaded = second->build(data({
		{"path", bot::JsonString(path.string())},
		{"optimizer", bot::JsonString("sgd")},
	}));
	TH_CHECK(resultOf(loaded) == "OK");
	TH_CHECK(loaded.find("source") != nullptr && loaded.find("source")->getValue() == "load");
	TH_CHECK(loaded.find("layers") != nullptr && loaded.find("layers")->getValue() == "2,3,1");
	const bot::Json after = second->call(data({
		{"input", bot::JsonString("0.25,-0.5")},
	}));
	TH_CHECK(resultOf(after) == "OK");
	TH_CHECK(std::fabs(after.find("output0")->getFloat() - value) <= 1e-12);

	TH_CHECK(resultOf(first->destroy(bot::JsonObject())) == "OK");
	TH_CHECK(resultOf(second->destroy(bot::JsonObject())) == "OK");
	std::filesystem::remove(path);
}

TH_TEST(nns_driver_rejects_invalid_configuration_and_arguments) {
	bot::HALManager hal;
	auto driver = bot::makeNnsDriver(hal);

	TH_CHECK(resultOf(driver->build(data({}))) == "ERR");
	TH_CHECK(resultOf(driver->build(data({
		{"layers", bot::JsonString("2,0,1")},
	}))) == "ERR");
	TH_CHECK(resultOf(driver->build(data({
		{"layers", bot::JsonString("2,3,1")},
		{"activation", bot::JsonString("NoSuchActivation")},
	}))) == "ERR");
	TH_CHECK(resultOf(driver->build(data({
		{"layers", bot::JsonString("2,3,1")},
		{"optimizer", bot::JsonString("rmsprop")},
	}))) == "ERR");

	TH_CHECK(resultOf(driver->build(makeConfig("2,3,1"))) == "OK");
	TH_CHECK(resultOf(driver->call(data({}))) == "ERR");
	TH_CHECK(resultOf(driver->call(data({
		{"input", bot::JsonString("1")},
	}))) == "ERR");
	TH_CHECK(resultOf(driver->call(data({
		{"command", bot::JsonString("train")},
		{"input", bot::JsonString("0,1")},
	}))) == "ERR");
	TH_CHECK(resultOf(driver->call(data({
		{"command", bot::JsonString("unknown")},
	}))) == "ERR");
	TH_CHECK(resultOf(driver->call(data({
		{"command", bot::JsonString("save")},
	}))) == "ERR");
}

TH_TEST(nns_table_creates_native_variable_and_action_can_train) {
	const std::string sql =
		"CREATE TABLE Nns (name String, layers String, activation String,"
		" output_activation String, learning_rate String, optimizer String,"
		" seed String, path String, autosave String);\n"
		"INSERT INTO Nns (name, layers, activation, output_activation,"
		" learning_rate, optimizer, seed, path, autosave) VALUES"
		" ('nn', '2,3,1', 'Leaky_ReLU', 'Sigmoid', '0.1', 'sgd', '42', '', '0');\n";

	bot::MemoryReader reader(sql);
	bot::RobotStruct robot(reader);
	robot.active();
	bot::MatrixVars_Hardware* variable = robot.registry().find("nn");
	TH_CHECK(variable != nullptr);
	TH_CHECK(std::string(variable->kindName()) == "native");

	const bot::Json direct = variable->play(data({
		{"input", bot::JsonString("0,1")},
	}));
	TH_CHECK(resultOf(direct) == "OK");

	bot::MemoryReader actions(
		"@Action\n"
		"nn.input0 nn.input1 nn.target0;\n"
		"  0         1         1;\n"
		"@\n");
	robot.run(actions);
	robot.deactivate();
}

#endif // MYBOT_HAVE_NN4CPP
