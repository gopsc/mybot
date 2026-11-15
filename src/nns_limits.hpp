#pragma once
/* nns_limits.hpp —— Nns 网络形状的边界（驱动与热 SQL 计划共用，2026-11-15 审计 M9）
 *
 * `layers` 是结构 SQL/热 SQL 提供的文本。旧实现只要求每个尺寸是正整数：
 * "1000000000,1000000000" 会在 createNetwork() 里按 Eigen 矩阵分配数十 GB，
 * 直接 OOM；层数也没有上限。这里把「形状」的合法性收成一个单点，启动期与
 * 热插路径用同一份判据，避免两处漂移。
 *
 * 阈值是防御性上限而非性能承诺：16 层 / 单层 4096 / 总参数 1e7。参数按
 * 全连接层 weights+bias 计（in*out + out）。
 */

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

namespace bot {

constexpr std::size_t kNnsMaxLayers = 16;
constexpr std::int64_t kNnsMaxLayerSize = 4096;
constexpr std::int64_t kNnsMaxParameters = 10000000;
/* 单行动作的训练重复次数上限。训练是宿主 CPU 循环，Lua 执行预算钩子
 * 打不断它；驱动在每轮之前显式检查 exec_budget，本上限只负责给一个
 * 可解释的输入边界，防止一次动作被写成无界长跑。 */
constexpr std::int64_t kNnsMaxRepeat = 100000;

/* 逗号/分号/空白分隔的正整数序列 → layers。成功返回 true；失败时 message
 * 是可直接拼进 ERR 的人话（点名越界值/上限）。 */
inline bool parseNnsLayers(const std::string& text, std::vector<std::int64_t>& layers,
		std::string& message) {
	layers.clear();
	std::string normalized = text;
	for (char& c : normalized) {
		if (c == ',' || c == ';') { c = ' '; }
	}
	std::istringstream input(normalized);
	std::string token;
	while (input >> token) {
		errno = 0;
		char* end = nullptr;
		const long long value = std::strtoll(token.c_str(), &end, 10);
		if (end != token.c_str() + token.size() || errno == ERANGE || value <= 0) {
			message = "invalid layer size '" + token + "' (must be a positive integer)";
			return false;
		}
		if (value > kNnsMaxLayerSize) {
			message = "layer size " + std::to_string(value) + " exceeds the limit "
				+ std::to_string(kNnsMaxLayerSize);
			return false;
		}
		layers.push_back(static_cast<std::int64_t>(value));
	}
	if (layers.size() < 2) {
		message = "layers must contain at least input and output sizes";
		return false;
	}
	if (layers.size() > kNnsMaxLayers) {
		message = "layers has " + std::to_string(layers.size())
			+ " sizes; at most " + std::to_string(kNnsMaxLayers) + " are allowed";
		return false;
	}
	std::int64_t parameters = 0;
	for (std::size_t i = 0; i + 1 < layers.size(); ++i) {
		/* 已先钳住层数与单层大小，乘积/累加不会溢出 int64。 */
		parameters += layers[i] * layers[i + 1] + layers[i + 1];
	}
	if (parameters > kNnsMaxParameters) {
		message = "network has " + std::to_string(parameters)
			+ " parameters; at most " + std::to_string(kNnsMaxParameters)
			+ " are allowed (reduce layers or widths)";
		return false;
	}
	return true;
}

} // namespace bot
