#include "hardware.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

#include "debug_log.hpp"	/* logD */
#include "util_num.hpp"

namespace bot {

double MatrixVars_Hardware::parseMtDouble(const mt::MatrixObject& obj, std::int64_t row, std::int64_t col) {
	/* 继承结果直查前向填充缓存。旧的逐格递归既是 O(n²)（每行每格重走整条链），
	 * 递归深度又等于连续 "-" 的行数：Release 仅靠 GCC 尾调用优化才没崩，
	 * Debug/ASAN 构建同输入实测 stack-overflow。 */
	const std::string& raw = obj.inherited(row, col);
	if (raw == "-") { return 0.0; }	/* 首数据行即 "-"，无可继承 */

	/* M2/B2-2：解析骨架收敛到 parseFiniteDouble，这里只配报错文案
	 * （INVALID 与 NONFINITE 分管「不是数」与「不是有限数」两种口径）。 */
	double v = 0.0;
	switch (parseFiniteDouble(raw, v)) {
	case ParseFiniteStatus::INVALID:
		/* N-12：统一抛 IllegalArgumentException（此前是全库唯一的
		 * std::invalid_argument 孤例，catch 侧无法按同一类型收口）。
		 * C4（2026-09-20 审计）：原文经 util::echoSource 转义 + 截断——单元格
		 * 长度只受 8 MiB 脚本上限约束，原样回显实测可灌 20 万字节进 stderr，
		 * 且 ANSI 转义会直写操作者终端。表达式报错早有一条截断防线，
		 * 这里此前漏了（同类缺陷只修一条路径）。 */
		throw IllegalArgumentException("cannot parse matrix cell '" + echoSource(raw)
			+ "' as Float64");
	case ParseFiniteStatus::NONFINITE:
		/* L2：strtod 接受 nan/inf 字面量，会以非有限值流入驱动（舵机角度 NaN
		 * 比较恒假，脉冲宽度计算不可预测）——解析层显式拒绝。 */
		throw IllegalArgumentException("matrix cell '" + echoSource(raw)
			+ "' is not a finite Float64");
	case ParseFiniteStatus::OK:
		return v;
	}
	return v;
}

Json MatrixVars_Hardware::ensureOk(const Json& res, const std::string& ctx) {
	if (!res.isObj()) {
		/* N3 防线：结果不是表就没有 result 键可读，旧实现原样放行等同「成功」。
		 * 典型成因：驱动少写 return（call_lua 已就形态报 ERR）、驱动把标量当
		 * 结果表返回。（曾有一条常见成因是把 @Alias 名当 @Action 设备列用
		 * ——alias 的 play 返回标量字符串；设备列别名解析落地后该路径在派发
		 * 前就走 resolveActionDevice 了，不再到达这里。） */
		static const char* const kKindName[] =
			{"null", "bool", "int", "float", "string", "array", "object"};
		/* B0：枚举下标取值加防线——kKindName 与 Json::T 的取值靠人工同步，
		 * 新增枚举值漏改此处即越界读。编译期钉住当前数量，运行期再做一次
		 * 边界检查（越界退化为 "unknown" 而不是 UB）。 */
		static_assert(sizeof(kKindName) / sizeof(kKindName[0])
			== static_cast<std::size_t>(Json::T::Obj) + 1,
			"kKindName must have exactly one entry per Json::T value");
		const auto kindIdx = static_cast<std::size_t>(static_cast<int>(res.type));
		const char* kind = kindIdx < sizeof(kKindName) / sizeof(kKindName[0])
			? kKindName[kindIdx] : "unknown";
		throw std::runtime_error("Hardware call (" + ctx + ") returned a non-table result ("
			+ kind + "). Every driver build/call/destroy must"
			+ " return a table with result=\"OK\" or result=\"ERR\".");
	}
	const Json& obj = res;
	/* L1：空表拦截——驱动 call 返回 {} 说明「什么都没干」，旧实现见无 result 键
	 * 即判成功（call_lua 的 N3 只拦得住「漏写 return」）。注意不能一刀切要求
	 * result 键必在：Relay/Servo 的 call 刻意返回无 result 的数据表（controller
	 * 转发语义），daemonPlay 输出 status/count 也无 result 键——两者均为非空表。 */
	if (obj.objSize() == 0) {
		throw std::runtime_error("Hardware call (" + ctx + ") returned an empty table ({}),"
			" which reads as success although the driver produced nothing. Every driver"
			" build/call/destroy must return a table with result=\"OK\" or result=\"ERR\""
			" (data fields may accompany).");
	}
	const Json* rs = obj.find("result");	/* F5-3：热路径零拷贝，免整值 optional 拷出 */
	if (rs) {
		if (!rs->isStr()) {
			throw std::runtime_error("Hardware call (" + ctx + ") returned a non-string"
				" 'result' field; the driver contract requires result=\"OK\" or result=\"ERR\".");
		}
		std::string v = trim(rs->getValue());
		if (v == "ERR") {
			std::string msg = "Hardware call failed (" + ctx + ")";
			const Json* m = obj.find("message");
			if (m && m->isStr()) { msg += ": " + m->getValue(); }
			throw std::runtime_error(msg);
		}
		if (v != "OK") {
			throw std::runtime_error("Hardware call (" + ctx + ") returned result=\"" + v
				+ "\"; the driver contract only allows result=\"OK\" or result=\"ERR\".");
		}
	}
	return res;
}

/* ---- 别名硬件变量 ---- */
std::unique_ptr<MtVars_Alias> MtVars_Alias::Factory(const mt::MatrixObject& defs, std::int64_t i) {
	std::int64_t idxName = defs.requireCol(0, "name", "Alias matrix");
	std::int64_t idxAlias = defs.requireCol(0, "alias", "Alias matrix");

	std::string name = defs(i, idxName);
	std::string alias = defs.inherited(i, idxAlias);

	/* N-12：装配期进度走 logD（数据走 stdout、错误走 stderr 的通道纪律） */
	logD([&] { return "Create an Alias vars: " + name + ", which means " + alias; });

	return std::unique_ptr<MtVars_Alias>(new MtVars_Alias(std::move(alias)));
}

std::unique_ptr<MtVars_Alias> MtVars_Alias::Make(std::string alias) {
	return std::unique_ptr<MtVars_Alias>(new MtVars_Alias(std::move(alias)));
}

/* ---- 命名数值变量 @Vars ---- */

/* 表达式求值的递归深度上限：Vars 表达式可互相引用（$(v1+v2)），成环
 * （A→B→A）或自引用会无限递归。线程局部计数兜底，超限判成环并清晰报错。
 * N-15：RAII 计数收敛为 util 的 RecursionGuard；重构计划 1-B2 把「超限
 * 检查 + 计数」进一步合一为 DepthLimitGuard。 */
namespace {
thread_local int t_varsDepth = 0;
constexpr int kMaxVarsDepth = 32;
} // namespace

double MtVars_Vars::numericValue() const {
	DepthLimitGuard guard(t_varsDepth, &kMaxVarsDepth, [] {
		return "circular @Vars expression reference detected (chain exceeds "
			+ std::to_string(kMaxVarsDepth) + " levels); an expression may not reference itself,"
			+ " directly or indirectly.";
	});
	if (expr_) {
		if (!resolve_) {
			throw IllegalArgumentException("Vars expression has no variable resolver"
				" (it can only be constructed through HwFactory)");
		}
		/* @Vars 的值是数值常量：resolve_ 只产 Num（vars-only 解析器），文本
		 * 结果不可达；requireNum 是共享 AST 的不变量钉（数值语义出口单点）。 */
		return requireNum(expr_->eval(numericResolver(resolve_)));
	}
	/* 字面量分支：Factory 已用 isNumericLiteral 校验过，这里独立复核一遍——
	 * 旧实现把 strtod 的 end 丢掉且不查 isfinite，一旦今后新增构造路径绕过
	 * Factory，畸形字面量会被静默当成数值用（strtod 失败返 0，与真实数值不可分）。
	 * M2/B2-2：判据收敛到 parseFiniteDouble（Factory 即 isNumericLiteral 同源）。 */
	double v = 0.0;
	if (parseFiniteDouble(literal_, v) != ParseFiniteStatus::OK) {
		throw IllegalArgumentException("Vars literal '" + literal_ + "' is not a finite Float64");
	}
	return v;
}

Json MtVars_Vars::play(const Json&) {
	/* 字面量保持原文（值按文本驻留，如 "2e3" 不被规范化）；表达式回写求值结果 */
	if (!expr_) { return JsonString(literal_); }
	return JsonString(formatNumber(numericValue()));
}

std::unique_ptr<MtVars_Vars> MtVars_Vars::Factory(const mt::MatrixObject& defs, std::int64_t i,
		std::function<double(const std::string&)> resolve) {
	std::int64_t idxName = defs.requireCol(0, "name", "Vars matrix");
	std::int64_t idxValue = defs.requireCol(0, "value", "Vars matrix");

	std::string name = defs(i, idxName);
	std::string value = defs.inherited(i, idxValue);

	/* value 允许两种形态：$(<表达式>)（语法在构造期校验，标识符惰性求值）
	 * 或数值字面量（仅支持 Number）。 */
	if (auto body = exprBody(value)) {
		Expression e = Expression::parse(*body);	/* 语法错误早报 */
		logD([&] { return "Create a Vars: " + name + " = " + value; });
		return std::unique_ptr<MtVars_Vars>(
			new MtVars_Vars(std::string(), std::move(e), std::move(resolve)));
	}
	if (!isNumericLiteral(value)) {
		throw IllegalArgumentException("Vars '" + name + "' in matrix '" + defs.getName()
			+ "': value '" + value + "' is neither a Number nor a $(...) expression.");
	}

	logD([&] { return "Create a Vars: " + name + " = " + value; });

	return std::unique_ptr<MtVars_Vars>(
		new MtVars_Vars(std::move(value), std::nullopt, std::move(resolve)));
}

std::unique_ptr<MtVars_Vars> MtVars_Vars::Make(double value) {
	/* L2 同源：非有限值不得流入 @Vars（数值常量语义），捕获出口显式拒绝。 */
	if (!std::isfinite(value)) {
		throw IllegalArgumentException("captured @Vars value is not a finite Float64");
	}
	std::string literal = formatNumber(value);
	logD([&] { return "Capture a Vars: " + literal; });
	return std::unique_ptr<MtVars_Vars>(
		new MtVars_Vars(std::move(literal), std::nullopt, {}));
}

} // namespace bot