#include "native_var.hpp"

#include <algorithm>
#include <iostream>
#include <stdexcept>

#include "util_except.hpp"
#include "util_str.hpp"

namespace bot {
namespace {
thread_local int g_nativeDepth = 0;
} // namespace

MtVars_Native::MtVars_Native(std::unique_ptr<NativeDriver> driver, std::string name,
		MetadataFn getMetadata, std::vector<std::string> ctrlNames,
		std::vector<std::string> trigNames, HwLookup* registry)
	: MatrixVars_Hardware(), driver_(std::move(driver)), name_(std::move(name)),
	  getMetadata_(std::move(getMetadata)), ctrlNames_(std::move(ctrlNames)),
	  trigNames_(std::move(trigNames)), ctrlPtrs_(ctrlNames_.size(), nullptr),
	  trigPtrs_(trigNames_.size(), nullptr), registry_(registry) {}

std::unique_ptr<MtVars_Native> MtVars_Native::Factory(
		std::unique_ptr<NativeDriver> driver, std::string name,
		MetadataFn getMetadata, std::vector<std::string> ctrlNames,
		std::vector<std::string> trigNames, HwLookup* registry) {
	if (!ctrlNames.empty() && registry == nullptr) {
		throw std::runtime_error("MtVars_Native::Factory: controller requires a registry");
	}
	if (!trigNames.empty() && registry == nullptr) {
		throw std::runtime_error("MtVars_Native::Factory: trigger requires a registry");
	}
	return std::unique_ptr<MtVars_Native>(new MtVars_Native(
		std::move(driver), std::move(name), std::move(getMetadata),
		std::move(ctrlNames), std::move(trigNames), registry));
}

void MtVars_Native::rejectReservedKeys(const Json& metadata, const Json& params) const {
	static const char* const kFrameworkKeys[] = {"mode", "result", "message"};
	if (!params.isObj()) { return; }
	for (const auto& kv : params.items()) {
		const std::string& key = kv.first;
		const char* why = nullptr;
		if (metadata.find(key) != nullptr) {
			why = "a structure-script metadata column";
		}
		for (const char* reserved : kFrameworkKeys) {
			if (key == reserved) { why = "a framework-reserved key"; }
		}
		for (const std::string& trigger : trigNames_) {
			if (key == trigger) {
				why = "a trigger reference name (the trigger result is merged under this key)";
			}
		}
		if (why != nullptr) {
			throw IllegalArgumentException("Hardware variable '" + name_
				+ "': @Action column '" + name_ + "." + key + "' is rejected because '"
				+ key + "' is " + why + " and cannot be supplied by the action script."
				" Action columns may only introduce new parameter names.");
		}
	}
}

MatrixVars_Hardware* MtVars_Native::flowTarget(std::vector<MatrixVars_Hardware*>& ptrs,
		const std::vector<std::string>& names, std::size_t index, const char* kind) {
	if (ptrs[index] == nullptr) { ptrs[index] = registry_->find(names[index]); }
	MatrixVars_Hardware* target = ptrs[index];
	if (target == nullptr) {
		throw IllegalArgumentException(std::string(kind) + " '" + names[index]
			+ "' of hardware variable '" + name_ + "' is no longer registered");
	}
	return target;
}

void MtVars_Native::mergeTriggerResults(Json& obj) {
	for (std::size_t index = 0; index < trigNames_.size(); ++index) {
		MatrixVars_Hardware* trigger = flowTarget(trigPtrs_, trigNames_, index, "trigger");
		Json result = trigger->play(JsonObject());
		ensureOk(result, "trigger '" + trigNames_[index] + "' of " + name_);
		obj.put(trigNames_[index], result);
	}
}

Json MtVars_Native::forwardToControllers(const Json& metadata, const Json& res) {
	Json payload = JsonObject();
	jsonMergeInto(payload, metadata);
	jsonMergeInto(payload, res.asObject());
	Json controllerResult;
	for (std::size_t index = 0; index < ctrlNames_.size(); ++index) {
		MatrixVars_Hardware* controller = flowTarget(ctrlPtrs_, ctrlNames_, index, "controller");
		controllerResult = controller->play(payload);
		ensureOk(controllerResult, "controller '" + ctrlNames_[index] + "' of " + name_);
	}
	return controllerResult;
}

Json MtVars_Native::play(const Json& input) {
	if (driver_ == nullptr) {
		throw std::runtime_error("'" + name_ + "' is not built or already destroyed");
	}
	const bool top = g_nativeDepth == 0;
	++g_nativeDepth;
	Json result;
	try {
		Json metadata = getMetadata_(false);
		rejectReservedKeys(metadata, input);
		Json object = JsonObject();
		jsonMergeInto(object, metadata);
		jsonMergeInto(object, input.asObject());
		mergeTriggerResults(object);
		object.put("mode", JsonString("call"));
		result = driver_->call(object);
		ensureOk(result, "call " + name_);
		if (!ctrlNames_.empty()) { result = forwardToControllers(metadata, result); }
	} catch (...) {
		--g_nativeDepth;
		throw;
	}
	--g_nativeDepth;
	if (top) { std::cerr << result.toString() << std::endl; }
	return result;
}

Json MtVars_Native::read() {
	if (driver_ == nullptr) {
		throw std::runtime_error("'" + name_ + "' is not built or already destroyed");
	}
	Json metadata = getMetadata_(false);
	metadata.put("mode", JsonString("read"));
	return driver_->read(metadata);
}

void MtVars_Native::build() {
	if (driver_ == nullptr) { return; }
	Json metadata = getMetadata_(false);
	metadata.put("mode", JsonString("build"));
	ensureOk(driver_->build(metadata), "build " + name_);
}

void MtVars_Native::destroy() {
	if (driver_ == nullptr) { return; }
	Json metadata;
	try {
		metadata = getMetadata_(true);
	} catch (const std::exception&) {
		metadata = JsonObject();
	}
	metadata.put("mode", JsonString("destroy"));
	ensureOk(driver_->destroy(metadata), "destroy " + name_);
	driver_.reset();
}

} // namespace bot
