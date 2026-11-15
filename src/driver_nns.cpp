/* driver_nns.cpp —— Nns 原生驱动：在结构 SQL 的 Nns 表中创建/加载神经网络。
 *
 * 这是 nn4cpp（C++17 神经网络库）的宿主侧 HAL 驱动，不经过 Lua：
 *
 *   CREATE TABLE Nns (
 *       name String,               -- 变量名，动作列写作 <name>.<param>
 *       layers String,             -- "2,4,1"；path 不存在时必填
 *       activation String,         -- 隐藏层激活，缺省 Leaky_ReLU
 *       output_activation String,  -- 输出层激活，缺省 Sigmoid
 *       learning_rate String,      -- 缺省 0.01
 *       optimizer String,          -- sgd（缺省）/ adam
 *       beta1 String, beta2 String, epsilon String,
 *       alpha String,              -- Leaky_ReLU 的 alpha，缺省 0.1
 *       seed String,               -- 可选；每层使用 seed + layerIndex
 *       path String,               -- 模型文件；存在则加载，不存在则创建并保存
 *       autosave String            -- 训练/销毁时自动保存，缺省 0
 *   );
 *
 * 动作参数：
 *   input    数值向量（"0,1" 或 JSON 数组）
 *   target   数值向量；存在即训练，否则推理
 *   command  predict / train / save / load / info（可选）
 *   discount 训练折扣，缺省 1.0
 *   save     本次训练后保存（可选，1/true）
 *
 * 返回值始终是带 result 的 JSON 对象；动作侧由 MtVars_Native 统一 ensureOk。
 * 训练/推理使用 nn4cpp 的行优先 Eigen 矩阵，所有输入在边界处做有限值/维度校验。
 */

#include "native_driver.hpp"

#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "exec_budget.hpp"
#include "nns_limits.hpp"
#include "util_path.hpp"
#include "util_str.hpp"

#ifdef MYBOT_HAVE_NN4CPP
#include "nn4cpp/nn4cpp.hpp"
#endif

namespace bot {

#ifndef MYBOT_HAVE_NN4CPP

std::unique_ptr<NativeDriver> makeNnsDriver(HALManager&) {
	return nullptr;
}

#else

namespace {

Json error(const std::string& message) {
	Json out = JsonObject();
	out.put("result", JsonString("ERR"));
	out.put("message", JsonString(message));
	return out;
}

Json ok() {
	Json out = JsonObject();
	out.put("result", JsonString("OK"));
	return out;
}

std::string lowerAscii(std::string text) {
	for (char& c : text) {
		c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
	}
	return text;
}

bool parseDoubleText(const std::string& text, double& out) {
	if (text.empty()) { return false; }
	errno = 0;
	char* end = nullptr;
	const double value = std::strtod(text.c_str(), &end);
	if (end != text.c_str() + text.size() || errno == ERANGE || !std::isfinite(value)) {
		return false;
	}
	out = value;
	return true;
}

bool parseUInt64Text(const std::string& text, std::uint64_t& out) {
	if (text.empty() || text[0] == '-') { return false; }
	errno = 0;
	char* end = nullptr;
	const unsigned long long value = std::strtoull(text.c_str(), &end, 10);
	if (end != text.c_str() + text.size() || errno == ERANGE) { return false; }
	out = static_cast<std::uint64_t>(value);
	return true;
}

bool parseBoolText(const std::string& text, bool& out) {
	const std::string lower = lowerAscii(bot::trim(text));
	if (lower == "1" || lower == "true" || lower == "yes" || lower == "on") {
		out = true;
		return true;
	}
	if (lower == "0" || lower == "false" || lower == "no" || lower == "off") {
		out = false;
		return true;
	}
	return false;
}

std::optional<double> numberValue(const Json& value) {
	if (value.isInt()) { return static_cast<double>(value.getInt()); }
	if (value.isFloat()) { return value.getFloat(); }
	if (value.isBool()) { return value.getBool() ? 1.0 : 0.0; }
	if (value.isStr()) {
		double number = 0.0;
		if (parseDoubleText(bot::trim(value.getValue()), number)) { return number; }
	}
	return std::nullopt;
}

std::string metadataText(const Json& data, const std::string& key) {
	const Json* value = data.find(key);
	if (value == nullptr || value->isNull()) { return std::string(); }
	if (value->isStr()) { return bot::trim(value->getValue()); }
	if (value->isInt()) { return std::to_string(value->getInt()); }
	if (value->isFloat()) { return std::to_string(value->getFloat()); }
	if (value->isBool()) { return value->getBool() ? "true" : "false"; }
	return std::string();
}

bool parseVector(const Json& value, std::vector<double>& out, std::string& message) {
	out.clear();
	if (value.isArr()) {
		for (const Json& item : value.arr) {
			const auto number = numberValue(item);
			if (!number) {
				message = "vector contains a non-numeric element";
				return false;
			}
			out.push_back(*number);
		}
	} else if (value.isStr()) {
		std::string text = bot::trim(value.getValue());
		if (text.size() >= 2 && text.front() == '[' && text.back() == ']') {
			text = text.substr(1, text.size() - 2);
		}
		for (char& c : text) {
			if (c == ',' || c == ';' || c == '[' || c == ']') { c = ' '; }
		}
		std::istringstream input(text);
		std::string token;
		while (input >> token) {
			double number = 0.0;
			if (!parseDoubleText(token, number)) {
				message = "invalid number '" + token + "'";
				return false;
			}
			out.push_back(number);
		}
	} else {
		const auto number = numberValue(value);
		if (!number) {
			message = "expected a number or numeric vector";
			return false;
		}
		out.push_back(*number);
	}
	if (out.empty()) {
		message = "vector must not be empty";
		return false;
	}
	return true;
}

/* 动作侧向量有两种写法：
 *   input  = "0,1" / JSON 数组（文本格或直接调用）
 *   input0, input1, ...（每个数据格是数值，最符合 .mt 数值格习惯）
 * 两种都支持；优先使用整体 input。 */
bool parseVectorWithWidth(const Json& data, const std::string& base,
	std::int64_t width, std::vector<double>& out, std::string& message) {
	if (const Json* whole = data.find(base); whole != nullptr && !whole->isNull()) {
		return parseVector(*whole, out, message);
	}
	out.clear();
	for (std::int64_t i = 0; i < width; ++i) {
		const std::string key = base + std::to_string(i);
		const Json* value = data.find(key);
		if (value == nullptr || value->isNull()) {
			message = "missing '" + base + "' or '" + key + "'";
			return false;
		}
		const auto number = numberValue(*value);
		if (!number) {
			message = "'" + key + "' is not numeric";
			return false;
		}
		out.push_back(*number);
	}
	return true;
}

std::vector<std::string> splitNames(const std::string& text) {
	std::string normalized = text;
	for (char& c : normalized) {
		if (c == ',' || c == ';') { c = ' '; }
	}
	std::vector<std::string> names;
	std::istringstream input(normalized);
	std::string token;
	while (input >> token) { names.push_back(token); }
	return names;
}

bool fileExists(const std::string& path) {
	std::ifstream input(path, std::ios::binary);
	return input.good();
}

/* 拒绝最后一段是符号链接的模型文件：即使路径通过了模型根前缀检查，
 * 写/读时跟随链接仍可能落到根外（save 用 ofstream，会跟随）。 */
bool isSymlinkPath(const std::string& path) {
	std::error_code ec;
	const auto status = std::filesystem::symlink_status(path, ec);
	return !ec && std::filesystem::is_symlink(status);
}

/* 热 SQL：path 必须是模型根下的相对路径，解析后再做 canonical 前缀检查。
 * weakly_canonical 会把已存在的目录/符号链接尽量解析掉，故子目录里的链接
 * 无法把最终路径带出根外。启动期/直接调用保持既有语义（绝对路径与 CWD
 * 相对路径都保留），这是 D3 的兼容边界。 */
std::string resolveModelPath(const std::string& raw, bool hot, std::string& message) {
	const std::string path = bot::trim(raw);
	if (path.empty()) { return std::string(); }
	if (path.find('\0') != std::string::npos) {
		message = "path contains NUL";
		return std::string();
	}
	if (!hot) {
		/* 可信本地路径也拒绝目录穿越：绝对路径本身合法，但 '..' 会让
		 * 模型指向任意位置，且与路径规范化无关。 */
		if (hasDotDotComponent(path)) {
			message = "path must not contain '..' components";
			return std::string();
		}
		return path;
	}
	if (checkRelPath(path) != RelPathCheck::OK) {
		message = "hot SQL Nns.path must be a relative path under the model root"
			" (absolute paths, '.', '..' and NUL are rejected; set"
			" BOT4CJ_MODEL_DIR or BOT4CJ_STATE_DIR to choose the root)";
		return std::string();
	}
	const std::filesystem::path root = std::filesystem::weakly_canonical(modelRoot());
	const std::filesystem::path full = std::filesystem::weakly_canonical(root / path);
	auto rootIt = root.begin();
	auto fullIt = full.begin();
	for (; rootIt != root.end(); ++rootIt, ++fullIt) {
		if (fullIt == full.end() || *rootIt != *fullIt) {
			message = "hot SQL Nns.path escapes the model root '" + root.string()
				+ "' after path resolution";
			return std::string();
		}
	}
	return full.string();
}

/* 保存前确保父目录存在（热插的模型根可能尚未创建）。只对确实是目录的
 * 父路径调用 create_directories；失败如实返回。 */
bool ensureModelParent(const std::string& path, std::string& message) {
	const std::filesystem::path parent = std::filesystem::path(path).parent_path();
	if (parent.empty()) { return true; }
	std::error_code ec;
	std::filesystem::create_directories(parent, ec);
	if (ec) {
		message = "cannot create model directory '" + parent.string()
			+ "': " + ec.message();
		return false;
	}
	return true;
}

Json vectorJson(const std::vector<double>& values) {
	Json out = JsonArray();
	for (double value : values) { out.add(JsonFloat(value)); }
	return out;
}

bool finiteOutput(const nn4cpp::Matrix& output) {
	for (std::int64_t r = 0; r < output.rows(); ++r) {
		for (std::int64_t c = 0; c < output.cols(); ++c) {
			if (!std::isfinite(output(r, c))) { return false; }
		}
	}
	return true;
}

std::string joinLayers(const std::vector<std::int64_t>& layers) {
	std::string out;
	for (std::size_t i = 0; i < layers.size(); ++i) {
		if (i != 0) { out.push_back(','); }
		out += std::to_string(layers[i]);
	}
	return out;
}

nn4cpp::Activation activationFor(const std::string& name, double alpha) {
	return nn4cpp::Activation::factory(name,
		name == "Leaky_ReLU" ? alpha : 0.0);
}

} // namespace

class NnsDriver final : public NativeDriver {
public:
	explicit NnsDriver(HALManager&) {}

	Json build(const Json& data) override;
	Json call(const Json& data) override;
	Json read(const Json& data) override;
	Json destroy(const Json& data) override;
	void setHotSql(bool hot) override { hot_ = hot; }

private:
	bool parseConfig(const Json& data, std::string& message);
	bool saveNetwork(std::string& message) const;
	std::shared_ptr<nn4cpp::Network> createNetwork(std::string& message) const;
	std::shared_ptr<nn4cpp::Network> loadNetwork(std::string& message) const;
	bool validateNetworkShape(const nn4cpp::Network& network, std::string& message);
	Json infoJson() const;
	Json predict(const Json& data);
	Json train(const Json& data);
	Json saveModel();
	Json loadModel();
	void appendOutput(Json& result, const nn4cpp::Matrix& output) const;
	std::int64_t parameterCount() const;

	std::shared_ptr<nn4cpp::Network> network_;
	std::string path_;
	/* 热 SQL 装配期由 HwFactory::createNativeVars 置位：path 必须相对且落在
	 * 模型根下，不能写任意绝对文件。 */
	bool hot_ = false;
	bool autosave_ = false;
	bool built_ = false;
	std::vector<std::int64_t> layers_;
	std::string activationName_ = "Leaky_ReLU";
	std::string outputActivationName_ = "Sigmoid";
	std::string activationsText_;
	double alpha_ = 0.1;
	double learningRate_ = 0.01;
	std::optional<nn4cpp::Adam> optimizer_;
	std::optional<std::uint64_t> seed_;
	std::optional<nn4cpp::Matrix> lastOutput_;
	double lastLoss_ = 0.0;
	bool hasLoss_ = false;
};

bool NnsDriver::parseConfig(const Json& data, std::string& message) {
	std::string rawPath = metadataText(data, "path");
	if (rawPath == "-") { rawPath.clear(); }	/* 占位符 = 无模型文件 */
	path_ = resolveModelPath(rawPath, hot_, message);
	if (path_.empty() && !message.empty()) { return false; }
	if (!path_.empty() && isSymlinkPath(path_)) {
		message = "model path '" + path_ + "' is a symbolic link; refusing to"
			" read or overwrite it";
		return false;
	}
	autosave_ = false;
	const std::string autosaveText = metadataText(data, "autosave");
	if (!autosaveText.empty() && !parseBoolText(autosaveText, autosave_)) {
		message = "invalid autosave value '" + autosaveText + "'";
		return false;
	}
	if (autosave_ && path_.empty()) {
		message = "autosave requires a non-empty 'path'";
		return false;
	}

	layers_.clear();
	const std::string layersText = metadataText(data, "layers");
	if (!layersText.empty() && !parseNnsLayers(layersText, layers_, message)) {
		return false;
	}

	activationName_ = metadataText(data, "activation");
	if (activationName_.empty()) { activationName_ = "Leaky_ReLU"; }
	outputActivationName_ = metadataText(data, "output_activation");
	if (outputActivationName_.empty()) { outputActivationName_ = "Sigmoid"; }
	activationsText_ = metadataText(data, "activations");

	alpha_ = 0.1;
	const std::string alphaText = metadataText(data, "alpha");
	if (!alphaText.empty() && !parseDoubleText(alphaText, alpha_)) {
		message = "invalid alpha value '" + alphaText + "'";
		return false;
	}
	if (!std::isfinite(alpha_)) {
		message = "alpha must be finite";
		return false;
	}
	try {
		if (activationsText_.empty()) {
			activationFor(activationName_, alpha_);
			activationFor(outputActivationName_, alpha_);
		} else {
			for (const std::string& name : splitNames(activationsText_)) {
				activationFor(name, alpha_);
			}
		}
	} catch (const std::exception& exception) {
		message = exception.what();
		return false;
	}

	learningRate_ = 0.01;
	const std::string rateText = metadataText(data, "learning_rate");
	const std::string shortRateText = metadataText(data, "lr");
	const std::string& chosenRate = rateText.empty() ? shortRateText : rateText;
	if (!chosenRate.empty() && !parseDoubleText(chosenRate, learningRate_)) {
		message = "invalid learning_rate value '" + chosenRate + "'";
		return false;
	}
	if (!(learningRate_ > 0.0) || !std::isfinite(learningRate_)) {
		message = "learning_rate must be finite and positive";
		return false;
	}

	optimizer_.reset();
	const std::string optimizer = lowerAscii(metadataText(data, "optimizer"));
	if (!optimizer.empty() && optimizer != "sgd" && optimizer != "none"
			&& optimizer != "adam") {
		message = "optimizer must be 'sgd' or 'adam'";
		return false;
	}
	if (optimizer == "adam") {
		double beta1 = 0.9;
		double beta2 = 0.999;
		double epsilon = 1e-8;
		const std::string beta1Text = metadataText(data, "beta1");
		const std::string beta2Text = metadataText(data, "beta2");
		const std::string epsilonText = metadataText(data, "epsilon");
		if ((!beta1Text.empty() && !parseDoubleText(beta1Text, beta1))
			|| (!beta2Text.empty() && !parseDoubleText(beta2Text, beta2))
			|| (!epsilonText.empty() && !parseDoubleText(epsilonText, epsilon))) {
			message = "invalid adam hyperparameter";
			return false;
		}
		try {
			optimizer_ = nn4cpp::Adam(beta1, beta2, epsilon);
		} catch (const std::exception& exception) {
			message = exception.what();
			return false;
		}
	}

	seed_.reset();
	const std::string seedText = metadataText(data, "seed");
	if (!seedText.empty()) {
		std::uint64_t seed = 0;
		if (!parseUInt64Text(seedText, seed)) {
			message = "invalid seed value '" + seedText + "'";
			return false;
		}
		seed_ = seed;
	}
	return true;
}

bool NnsDriver::saveNetwork(std::string& message) const {
	if (network_ == nullptr) {
		message = "network is not initialized";
		return false;
	}
	/* 保存是写穿操作：符号链接可能把模型写到根外，热插相对路径解析后
	 * 也不应跟随最后一段链接。 */
	if (isSymlinkPath(path_)) {
		message = "model path '" + path_ + "' is a symbolic link; refusing to overwrite it";
		return false;
	}
	if (!ensureModelParent(path_, message)) { return false; }
	network_->save(path_);
	return true;
}

std::shared_ptr<nn4cpp::Network> NnsDriver::createNetwork(std::string& message) const {
	std::vector<nn4cpp::Activation> activations;
	if (!activationsText_.empty()) {
		const std::vector<std::string> names = splitNames(activationsText_);
		if (names.size() != layers_.size() - 1) {
			message = "activations count must be layers-1";
			return nullptr;
		}
		for (const std::string& name : names) {
			activations.push_back(activationFor(name, alpha_));
		}
	} else {
		const nn4cpp::Activation hidden = activationFor(activationName_, alpha_);
		const nn4cpp::Activation output = activationFor(outputActivationName_, alpha_);
		for (std::size_t i = 0; i + 1 < layers_.size(); ++i) {
			activations.push_back(i + 2 == layers_.size() ? output : hidden);
		}
	}

	auto network = std::make_shared<nn4cpp::Network>();
	for (std::size_t i = 0; i + 1 < layers_.size(); ++i) {
		std::optional<std::uint64_t> layerSeed;
		if (seed_.has_value()) {
			layerSeed = *seed_ + static_cast<std::uint64_t>(i);
		}
		network->add(std::make_shared<nn4cpp::Layer>(layers_[i], layers_[i + 1],
			learningRate_, activations[i], optimizer_, layerSeed));
	}
	return network;
}

std::shared_ptr<nn4cpp::Network> NnsDriver::loadNetwork(std::string& message) const {
	try {
		return std::make_shared<nn4cpp::Network>(nn4cpp::Network::load(path_, optimizer_));
	} catch (const std::exception& exception) {
		message = exception.what();
		return nullptr;
	}
}

bool NnsDriver::validateNetworkShape(const nn4cpp::Network& network,
	std::string& message) {
	if (network.layers().empty()) {
		message = "network has no layers";
		return false;
	}
	std::vector<std::int64_t> actual;
	actual.push_back(network.layers().front()->inputSize());
	for (const auto& layer : network.layers()) {
		actual.push_back(layer->outputSize());
	}
	if (layers_.empty()) {
		layers_ = actual;
		return true;
	}
	if (actual != layers_) {
		message = "model layer sizes do not match the 'layers' column";
		return false;
	}
	return true;
}

std::int64_t NnsDriver::parameterCount() const {
	if (!network_) { return 0; }
	std::int64_t count = 0;
	for (const auto& layer : network_->layers()) {
		count += static_cast<std::int64_t>(layer->weights().size());
		count += static_cast<std::int64_t>(layer->bias().size());
	}
	return count;
}

Json NnsDriver::infoJson() const {
	Json result = ok();
	result.put("layers", JsonString(joinLayers(layers_)));
	result.put("path", JsonString(path_));
	result.put("autosave", JsonBool(autosave_));
	result.put("built", JsonBool(built_));
	result.put("parameters", JsonInt(parameterCount()));
	if (hasLoss_) { result.put("last_loss", JsonFloat(lastLoss_)); }
	return result;
}

void NnsDriver::appendOutput(Json& result, const nn4cpp::Matrix& output) const {
	const std::int64_t columns = output.cols();
	std::vector<double> values;
	values.reserve(static_cast<std::size_t>(columns));
	for (std::int64_t c = 0; c < columns; ++c) {
		values.push_back(output(0, c));
		result.put("output" + std::to_string(c), JsonFloat(output(0, c)));
	}
	result.put("output", vectorJson(values));
}

Json NnsDriver::build(const Json& data) {
	built_ = false;
	network_.reset();
	lastOutput_.reset();
	hasLoss_ = false;
	lastLoss_ = 0.0;

	try {
		std::string message;
		if (!parseConfig(data, message)) {
			return error("Nns: " + message);
		}

		if (!path_.empty() && fileExists(path_)) {
			network_ = loadNetwork(message);
			if (!network_) { return error("Nns: " + message); }
			if (!validateNetworkShape(*network_, message)) {
				return error("Nns: " + message);
			}
			built_ = true;
			Json result = infoJson();
			result.put("source", JsonString("load"));
			return result;
		}

		if (layers_.empty()) {
			return error("Nns: 'layers' is required when 'path' does not exist");
		}
		network_ = createNetwork(message);
		if (!network_) { return error("Nns: " + message); }
		if (!validateNetworkShape(*network_, message)) {
			return error("Nns: " + message);
		}
		if (!path_.empty() && !saveNetwork(message)) {
			return error("Nns: " + message);
		}
		built_ = true;
		Json result = infoJson();
		result.put("source", JsonString("create"));
		return result;
	} catch (const std::exception& exception) {
		return error(std::string("Nns: ") + exception.what());
	}
}

Json NnsDriver::predict(const Json& data) {
	const std::int64_t width = network_->layers().front()->inputSize();
	std::vector<double> values;
	std::string message;
	if (!parseVectorWithWidth(data, "input", width, values, message)) {
		return error("Nns: " + message);
	}
	if (static_cast<std::int64_t>(values.size()) != width) {
		return error("Nns: input width " + std::to_string(values.size())
			+ " != " + std::to_string(width));
	}

	nn4cpp::Matrix inputMatrix(1, width);
	for (std::int64_t c = 0; c < width; ++c) {
		inputMatrix(0, c) = values[static_cast<std::size_t>(c)];
	}
	const nn4cpp::Matrix output = network_->predict(inputMatrix);
	if (!finiteOutput(output)) {
		return error("Nns: prediction produced a non-finite value");
	}
	lastOutput_ = output;
	Json result = ok();
	appendOutput(result, output);
	return result;
}

Json NnsDriver::train(const Json& data) {
	const std::int64_t inputWidth = network_->layers().front()->inputSize();
	const std::int64_t outputWidth = network_->layers().back()->outputSize();
	std::vector<double> inputValues;
	std::vector<double> targetValues;
	std::string message;
	if (!parseVectorWithWidth(data, "input", inputWidth, inputValues, message)) {
		return error("Nns: " + message);
	}
	if (!parseVectorWithWidth(data, "target", outputWidth, targetValues, message)) {
		return error("Nns: " + message);
	}
	if (static_cast<std::int64_t>(inputValues.size()) != inputWidth) {
		return error("Nns: input width " + std::to_string(inputValues.size())
			+ " != " + std::to_string(inputWidth));
	}
	if (static_cast<std::int64_t>(targetValues.size()) != outputWidth) {
		return error("Nns: target width " + std::to_string(targetValues.size())
			+ " != " + std::to_string(outputWidth));
	}

	double discount = 1.0;
	if (const Json* discountValue = data.find("discount");
			discountValue != nullptr && !discountValue->isNull()) {
		const auto value = numberValue(*discountValue);
		if (!value) { return error("Nns: invalid discount"); }
		discount = *value;
	}

	nn4cpp::Matrix inputMatrix(1, inputWidth);
	nn4cpp::Matrix targetMatrix(1, outputWidth);
	for (std::int64_t c = 0; c < inputWidth; ++c) {
		inputMatrix(0, c) = inputValues[static_cast<std::size_t>(c)];
	}
	for (std::int64_t c = 0; c < outputWidth; ++c) {
		targetMatrix(0, c) = targetValues[static_cast<std::size_t>(c)];
	}

	bool save = autosave_;
	if (const Json* saveValue = data.find("save");
			saveValue != nullptr && !saveValue->isNull()) {
		bool requested = false;
		if (saveValue->isBool()) {
			requested = saveValue->getBool();
		} else if (const auto number = numberValue(*saveValue);
				number.has_value() && (*number == 0.0 || *number == 1.0)) {
			requested = *number != 0.0;
		} else {
			const std::string text = metadataText(data, "save");
			if (!parseBoolText(text, requested)) {
				return error("Nns: invalid save flag");
			}
		}
		save = save || requested;
	}
	/* 在更新参数之前拒绝“要求保存但没有路径”，避免一次失败的 action
	 * 已经把模型训练了半个回合。 */
	if (save && path_.empty()) {
		return error("Nns: save requested but 'path' is empty");
	}

	std::int64_t repeat = 1;
	if (const Json* repeatValue = data.find("repeat");
			repeatValue != nullptr && !repeatValue->isNull()) {
		const auto value = numberValue(*repeatValue);
		if (!value || *value < 1.0 || std::floor(*value) != *value
				|| *value > static_cast<double>(kNnsMaxRepeat)) {
			return error("Nns: repeat must be an integer in [1, "
				+ std::to_string(kNnsMaxRepeat) + "]");
		}
		repeat = static_cast<std::int64_t>(*value);
	}

	double loss = 0.0;
	for (std::int64_t i = 0; i < repeat; ++i) {
		/* C++ 训练循环不受 Lua 指令钩子约束；每轮检查动作预算，使
		 * --timeout / Ctrl-C 能中止长训练（ExecBudgetExceeded 在 call()
		 * 里原样重抛，不折成普通 ERR）。 */
		requireExecBudget();
		loss = network_->train(inputMatrix, targetMatrix, discount);
	}
	lastLoss_ = loss;
	hasLoss_ = true;
	const nn4cpp::Matrix output = network_->predict(inputMatrix);
	if (!finiteOutput(output)) {
		return error("Nns: training produced a non-finite output");
	}
	lastOutput_ = output;

	bool saved = false;
	if (save) {
		std::string saveMessage;
		if (!saveNetwork(saveMessage)) { return error("Nns: " + saveMessage); }
		saved = true;
	}

	Json result = ok();
	result.put("loss", JsonFloat(loss));
	result.put("saved", JsonBool(saved));
	appendOutput(result, output);
	return result;
}

Json NnsDriver::saveModel() {
	if (path_.empty()) {
		return error("Nns: save requires a non-empty 'path' column");
	}
	std::string message;
	if (!saveNetwork(message)) { return error("Nns: " + message); }
	Json result = ok();
	result.put("path", JsonString(path_));
	return result;
}

Json NnsDriver::loadModel() {
	if (path_.empty()) {
		return error("Nns: load requires a non-empty 'path' column");
	}
	if (!fileExists(path_)) {
		return error("Nns: model file does not exist: " + path_);
	}
	std::string message;
	auto network = loadNetwork(message);
	if (!network) { return error("Nns: " + message); }
	if (!validateNetworkShape(*network, message)) {
		return error("Nns: " + message);
	}
	network_ = std::move(network);
	lastOutput_.reset();
	hasLoss_ = false;
	built_ = true;
	Json result = infoJson();
	result.put("source", JsonString("load"));
	return result;
}

Json NnsDriver::call(const Json& data) {
	if (!built_ || !network_) { return error("Nns: not built"); }
	try {
		std::string command = lowerAscii(metadataText(data, "command"));
		if (command.empty()) {
			bool hasTarget = data.find("target") != nullptr;
			if (!hasTarget) {
				const std::int64_t width = network_->layers().back()->outputSize();
				for (std::int64_t i = 0; i < width && !hasTarget; ++i) {
					hasTarget = data.find("target" + std::to_string(i)) != nullptr;
				}
			}
			command = hasTarget ? "train" : "predict";
		}
		if (command == "predict") { return predict(data); }
		if (command == "train") { return train(data); }
		if (command == "save") { return saveModel(); }
		if (command == "load") { return loadModel(); }
		if (command == "info") { return infoJson(); }
		return error("Nns: unknown command '" + command + "'");
	} catch (const ExecBudgetExceeded&) {
		/* 预算耗尽不是驱动失败：必须穿透 Native 的 ERR 折叠，让
		 * ActionRunner 走 halt-on-error 而不是继续下一行。 */
		throw;
	} catch (const std::exception& exception) {
		return error(std::string("Nns: ") + exception.what());
	}
}

Json NnsDriver::read(const Json&) {
	Json result = infoJson();
	if (lastOutput_.has_value()) {
		appendOutput(result, *lastOutput_);
	}
	return result;
}

Json NnsDriver::destroy(const Json&) {
	try {
		if (built_ && autosave_ && !path_.empty()) {
			std::string message;
			if (!saveNetwork(message)) {
				throw std::runtime_error(message);
			}
		}
		network_.reset();
		lastOutput_.reset();
		hasLoss_ = false;
		built_ = false;
		return ok();
	} catch (const std::exception& exception) {
		network_.reset();
		lastOutput_.reset();
		hasLoss_ = false;
		built_ = false;
		return error(std::string("Nns: destroy save failed: ") + exception.what());
	}
}

std::unique_ptr<NativeDriver> makeNnsDriver(HALManager& hal) {
	return std::make_unique<NnsDriver>(hal);
}

#endif // MYBOT_HAVE_NN4CPP

} // namespace bot
