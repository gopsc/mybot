#pragma once
/* native_var.hpp —— C++ 原生驱动的 MatrixVars 适配层
 *
 * 与 MtVars_Lua 同契约：元数据 ∪ 动作参数 ∪ trigger 结果 → driver->call()；
 * controller 转发、destroy 元数据快照、参数键冲突检查全部保持。
 */

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "hardware.hpp"
#include "native_driver.hpp"

namespace bot {

class MtVars_Native : public MatrixVars_Hardware {
public:
	using MetadataFn = std::function<Json(bool)>;

	static std::unique_ptr<MtVars_Native> Factory(
		std::unique_ptr<NativeDriver> driver, std::string name,
		MetadataFn getMetadata, std::vector<std::string> ctrlNames,
		std::vector<std::string> trigNames, HwLookup* registry);

	Json play(const Json& input) override;
	Json read() override;
	void build() override;
	void destroy() override;
	const char* kindName() const override { return "native"; }

private:
	MtVars_Native(std::unique_ptr<NativeDriver> driver, std::string name,
		MetadataFn getMetadata, std::vector<std::string> ctrlNames,
		std::vector<std::string> trigNames, HwLookup* registry);

	void rejectReservedKeys(const Json& metadata, const Json& params) const;
	void mergeTriggerResults(Json& obj);
	Json forwardToControllers(const Json& metadata, const Json& res);
	MatrixVars_Hardware* flowTarget(std::vector<MatrixVars_Hardware*>& ptrs,
		const std::vector<std::string>& names, std::size_t index, const char* kind);

	std::unique_ptr<NativeDriver> driver_;
	std::string name_;
	MetadataFn getMetadata_;
	std::vector<std::string> ctrlNames_;
	std::vector<std::string> trigNames_;
	std::vector<MatrixVars_Hardware*> ctrlPtrs_;
	std::vector<MatrixVars_Hardware*> trigPtrs_;
	HwLookup* registry_ = nullptr;
};

} // namespace bot
