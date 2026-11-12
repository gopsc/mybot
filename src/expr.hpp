#pragma once
/* expr.hpp —— 表达式（用于 $(...) 引用/定义，以及 @if(...) 条件块）
 *
 * 语法：+ - * / %、一元正负、括号、十进制字面量、字符串字面量（"x"，
 * 转义 \n \t \r \\ \" 解码成对应字节，未知转义报错；文本比较
 * @if(mode=="auto") 的必要面）、标识符（@Vars 名；在
 * @Action 求值面亦可为 @Alias 名）。比较（< > <= >= == !=）与逻辑
 * （&& || !，短路求值）产出 Bool——**仅 @if(...) 条件语境有意义**：
 * 旧消费面（@Action 格子/列头、@Vars 值、SQL 元数据列）遇到 Bool 结果
 * 一律显式拒绝（各自给出「逻辑表达式属于 @if」类文案）。无函数调用/
 * 赋值，避免扩大攻击面。标识符求值经 resolve 回调，实现与调用方解耦。
 * 解析在构造期完成（语法错误早报），求值惰性（可安全支持前向引用与
 * 动作覆盖）。
 *
 * 值语义：求值结果是 ExprValue（数值、文本或布尔）。'+' 在出现文本操作数
 * 时变为拼接（数值操作数以真值文本 formatNumber 参与）；其余算术运算符
 * 只收数值。比较 > < <= >= 只收数值；== != 同类可比（数值/文本/布尔），
 * 跨类报错；&& || ! 只收布尔。类型严格分档、无隐式转换——静默的真值
 * 语义（如数值 0 当 false）会让拼错的条件以错误理由成立。
 * 「运算/拼接只发生在 $(...) 与 @if(...) 之内」——裸单元格不引入任何
 * 新语法。
 */

#include <functional>
#include <memory>
#include <optional>
#include <set>
#include <string>


namespace bot {

/* 表达式求值结果：数值、文本或布尔。类型由操作数决定（@Vars → 数值、
 * @Alias → 文本、比较/逻辑 → 布尔），不是由语法决定——这正是「两个
 * @Vars 做运算、出现 @Alias 就拼接」的类型分派规则；Bool 只能由
 * 比较/逻辑运算产生（无 true/false 字面量，字面量语境写不出布尔）。 */
struct ExprValue {
	enum class Kind { Num, Text, Bool };
	Kind kind = Kind::Num;
	double num = 0.0;
	std::string text;
	bool flag = false;

	static ExprValue makeNum(double v) {
		ExprValue e;
		e.kind = Kind::Num;
		e.num = v;
		return e;
	}
	static ExprValue makeText(std::string s) {
		ExprValue e;
		e.kind = Kind::Text;
		e.text = std::move(s);
		return e;
	}
	static ExprValue makeBool(bool v) {
		ExprValue e;
		e.kind = Kind::Bool;
		e.flag = v;
		return e;
	}
	bool isNum() const { return kind == Kind::Num; }
	bool isText() const { return kind == Kind::Text; }
	bool isBool() const { return kind == Kind::Bool; }

	/* 文本出口：Text 原样；Num 以真值渲染（formatNumber，%.15g——整数不带
	 * 小数点，"2e3" 的真值是 "2000"）；Bool 渲染 "true"/"false"（rendered
	 * 是通用字符串化单点，Bool 的语义出口在 @if 条件判定，见消费面检查）。
	 * 拼接与 Action 落点共用的唯一渲染单点；非有限数值在此拒绝（否则 inf
	 * 会经 formatNumber 变成文本 "inf" 流入名字/参数，绕过求值出口的有限值
	 * 防线）。 */
	std::string rendered() const;
};

/* 类型名单点（"number"/"text"/"boolean"）：报错文案与调用方的语境检查
 * 共用，避免各处手拼漂移。 */
const char* exprTypeName(const ExprValue& v);

/* 标识符求值回调：@Vars → Num（numericValue），@Alias → Text（别名值文本），
 * 其余（驱动/守护名、未定义名）由解析器实现抛错。 */
using ExprValueResolver = std::function<ExprValue(const std::string&)>;

/* 数值解析器适配：把 double 解析器（makeVarsResolver 的既有形态）包成
 * 只产 Num 的 ExprValue 解析器。 */
ExprValueResolver numericResolver(std::function<double(const std::string&)> f);

/* 数值语义出口：供「只收数值」的调用面（@Vars 的 value、SQL 元数据列）。
 * 文本结果在此显式拒绝——这些位置不引入拼接能力。 */
double requireNum(const ExprValue& v);

class Expression {
public:
	/* 内部 AST 实现（定义在 expr.cpp；公开仅为 pimpl 派生实现，非使用接口）。 */
	struct Impl;

	/* 解析表达式文本；语法错误抛 IllegalArgumentException（含出错位置）。 */
	static Expression parse(const std::string& text);

	/* 求值：标识符经 resolve 取值；除零/取模为零由本函数抛错，标识符
	 * 未定义由 resolve 抛错。非有限数值结果（含拼接中的数值真值渲染）拒绝。 */
	ExprValue eval(const ExprValueResolver& resolve) const;

	/* 收集全部标识符（供调用方做存在性校验）。 */
	void collectVars(std::set<std::string>& out) const;

	bool empty() const { return !impl_; }

private:
	std::shared_ptr<const Impl> impl_;
};

/* 若 value 形如 $(<expr>) 则返回内部表达式文本，否则 nullopt。
 * 注意：$(...) 内不得含空格（矩阵按空白切格），SQL 结构脚本内需写成
 * 引号形式 '$(...)'（SQL 词法把 '(' ')' 当分隔符）。 */
std::optional<std::string> exprBody(const std::string& value);

} // namespace bot
