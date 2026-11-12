/* test_expr.cpp —— 算术表达式（$(...) 内部）解析与求值
 *
 * 覆盖：优先级/结合性、一元正负、括号、除零与取模为零、非有限值拒绝、
 * 语法错误、标识符收集、嵌套深度上限（防深括号打爆栈）、$(...) 外壳识别。
 */

#include <functional>
#include <map>
#include <set>
#include <string>

#include "expr.hpp"
#include "harness.hpp"
#include "util_except.hpp"

using bot::Expression;
using bot::exprBody;

namespace {

/* 简单变量表求值器：未定义抛 bot::IllegalArgumentException（与生产 resolver 同契约） */
std::function<double(const std::string&)> varTable(const std::map<std::string, double>& vars) {
	return [vars](const std::string& name) -> double {
		auto it = vars.find(name);
		if (it == vars.end()) {
			throw bot::IllegalArgumentException("undefined: " + name);
		}
		return it->second;
	};
}

double evalWith(const std::string& text, const std::map<std::string, double>& vars) {
	return bot::requireNum(
		Expression::parse(text).eval(bot::numericResolver(varTable(vars))));
}

/* 混合变量表：nums 模拟 @Vars（数值）、texts 模拟 @Alias（文本）——
 * 与生产 makeActionExprResolver 同契约（未定义即抛） */
bot::ExprValueResolver mixedTable(std::map<std::string, double> nums,
	std::map<std::string, std::string> texts) {
	return [nums = std::move(nums), texts = std::move(texts)](const std::string& name)
			-> bot::ExprValue {
		if (auto it = nums.find(name); it != nums.end()) {
			return bot::ExprValue::makeNum(it->second);
		}
		if (auto it = texts.find(name); it != texts.end()) {
			return bot::ExprValue::makeText(it->second);
		}
		throw bot::IllegalArgumentException("undefined: " + name);
	};
}

bot::ExprValue evalMixed(const std::string& text, std::map<std::string, double> nums,
	std::map<std::string, std::string> texts) {
	return Expression::parse(text).eval(mixedTable(std::move(nums), std::move(texts)));
}

} // namespace

TH_TEST(expr_arithmetic_and_precedence) {
	TH_CHECK(evalWith("1+2*3", {}) == 7.0);
	TH_CHECK(evalWith("(1+2)*3", {}) == 9.0);
	TH_CHECK(evalWith("10-2-3", {}) == 5.0);		/* 左结合 */
	TH_CHECK(evalWith("100/5/2", {}) == 10.0);
	TH_CHECK(evalWith("7%4", {}) == 3.0);
	TH_CHECK(evalWith("1+2+10", {}) == 13.0);
}

TH_TEST(expr_unary_and_parentheses) {
	TH_CHECK(evalWith("-5+8", {}) == 3.0);
	TH_CHECK(evalWith("--5", {}) == 5.0);
	TH_CHECK(evalWith("-(2+3)*2", {}) == -10.0);
	TH_CHECK(evalWith("+4", {}) == 4.0);
	TH_CHECK(evalWith("((((1))))", {}) == 1.0);
	TH_CHECK(evalWith("1.5*2", {}) == 3.0);
	TH_CHECK(evalWith("2e3+1", {}) == 2001.0);
}

TH_TEST(expr_identifiers_resolve) {
	std::map<std::string, double> vars{{"v1", 10.0}, {"v2", 5.0}, {"x", 2.5}};
	TH_CHECK(evalWith("v1+v2+10", vars) == 25.0);
	TH_CHECK(evalWith("v1*v2-x", vars) == 47.5);
	TH_CHECK(evalWith("(v1-v2)/(x+0.5)", vars) == 5.0 / 3.0);
}

TH_TEST(expr_undefined_identifier_propagates) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "undefined: ghost",
		evalWith("1+ghost", {}));
}

TH_TEST(expr_division_and_modulo_by_zero) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "division by zero",
		evalWith("1/0", {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "modulo by zero",
		evalWith("1%0", {}));
}

TH_TEST(expr_nonfinite_is_rejected) {
	/* 有限值防线（审计中-1）：字面量本身合法（parseNumber 已拒 inf/nan），
	 * 但中间结果可溢出（1e308*1e308 → inf；inf-inf → nan）。IEEE 语义下任何
	 * 非有限中间结果必然传播到根节点，求值出口一次检查即可封死旁路——
	 * 否则 inf/nan 经 JsonFloat/lua_pushnumber 流入驱动参数。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "non-finite",
		evalWith("1e308*1e308", {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "non-finite",
		evalWith("1e308*1e308-1e308*1e308", {}));
	/* 标识符路径同样覆盖（resolve 返回有限值，溢出发生在运算） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "non-finite",
		evalWith("v1*1e308*1e308", {{"v1", 10.0}}));
	/* 上限内的合法大数必须正常求值，确保防线没有误伤 */
	TH_CHECK(evalWith("1e308", {}) == 1e308);
}

TH_TEST(expr_syntax_errors_are_clear) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "invalid expression",
		Expression::parse("1+"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "expected ')'",
		Expression::parse("(1+2"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected trailing input",
		Expression::parse("1 2"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "empty expression",
		Expression::parse("   "));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unexpected character",
		Expression::parse("1+@"));
}

TH_TEST(expr_deep_nesting_is_rejected_not_crashed) {
	/* 脚本字节上限下，深括号（如数万层 '('）必须在解析期拒绝，而不是打爆宿主栈 */
	std::string deep(5000, '(');
	deep += "1";
	deep.append(5000, ')');
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "nesting too deep",
		Expression::parse(deep));
}

TH_TEST(expr_operator_chain_is_rejected_not_crashed) {
	/* 平铺运算符链不经过括号递归（kMaxDepth 拦不住），左深树会让 eval 的
	 * 递归深度等于树深——无界链在求值期 SIGSEGV（审计 C-1 实证：600 KB
	 * 的 '+1' 链稳定崩溃）。必须在解析期就拒绝。 */
	std::string chain = "1";
	for (int i = 0; i < 2000; ++i) { chain += "+1"; }	/* 2000 个运算符，超 kMaxOps=512 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "too many operators",
		Expression::parse(chain));
	/* 上限内的合法长链（512 个）必须正常求值，确保防线没有误伤 */
	std::string ok = "0";
	for (int i = 0; i < 500; ++i) { ok += "+1"; }
	TH_CHECK(evalWith(ok, {}) == 500.0);
}

TH_TEST(expr_collect_vars) {
	std::set<std::string> names;
	Expression::parse("v1+v2*3-(-x)").collectVars(names);
	TH_CHECK(names.size() == 3);
	TH_CHECK(names.count("v1") == 1);
	TH_CHECK(names.count("v2") == 1);
	TH_CHECK(names.count("x") == 1);
}

TH_TEST(expr_body_detects_shell) {
	auto body = exprBody("$(v1+v2+10)");
	TH_CHECK(body.has_value());
	TH_CHECK(*body == "v1+v2+10");

	TH_CHECK(!exprBody("$v1").has_value());
	TH_CHECK(!exprBody("v1+v2").has_value());
	TH_CHECK(!exprBody("$(v1) ").has_value());	/* 末尾有空格不算 */
	TH_CHECK(!exprBody("$(").has_value());
}

/* ---- 值语义：'+' 类型分派（2026-09-20 设计评估）----
 * 两个 @Vars 做算术；出现 @Alias（文本）即拼接，数值操作数以真值文本参与；
 * 其余运算符对文本无定义。 */

TH_TEST(expr_plus_text_operand_concatenates) {
	/* 文本参与 '+'：拼接；数值侧按真值渲染（%.15g，"2e3"→"2000"、0.5→"0.5"） */
	TH_CHECK(evalMixed("a+n", {{"n", 2.0}}, {{"a", "relay-"}}).text == "relay-2");
	TH_CHECK(evalMixed("a+n", {{"n", 2e3}}, {{"a", "relay-"}}).text == "relay-2000");
	TH_CHECK(evalMixed("a+n", {{"n", 0.5}}, {{"a", "relay-"}}).text == "relay-0.5");
	/* 数值在前、文本在后（交换律形态）与双文本 */
	TH_CHECK(evalMixed("n+a", {{"n", 2.0}}, {{"a", "-tail"}}).text == "2-tail");
	TH_CHECK(evalMixed("a+b", {}, {{"a", "x"}, {"b", "y"}}).text == "xy");
	/* 全数值仍是算术——类型分派不改变既有语义 */
	TH_CHECK(evalMixed("n+m", {{"n", 2.0}, {"m", 3.0}}, {}).num == 5.0);
}

TH_TEST(expr_numeric_operators_reject_text) {
	/* 除 '+' 外的运算符对文本无定义——报错文案单点（throwNonNumOperand，
	 * 2026-10-10 @if 特性起文案同时覆盖布尔操作数，断言取公共段） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'-' cannot be applied to a text operand",
		evalMixed("a-n", {{"n", 2.0}}, {{"a", "x"}}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'*' cannot be applied to a text operand",
		evalMixed("a*n", {{"n", 2.0}}, {{"a", "x"}}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'/' cannot be applied to a text operand",
		evalMixed("n/a", {{"n", 2.0}}, {{"a", "x"}}));
	/* 一元负号同样拒绝文本 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'-' cannot be applied to a text operand",
		evalMixed("-a", {}, {{"a", "x"}}));
}

TH_TEST(expr_concat_rejects_nonfinite_numeric_rendering) {
	/* 拼接中数值真值渲染必须过有限值防线——inf 变文本 "inf" 是旁路：
	 * n*n = 1e616 = inf，渲染进文本前必须拒绝 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "non-finite",
		evalMixed("a+(n*n)", {{"n", 1e308}}, {{"a", "x"}}));
}

TH_TEST(expr_require_num_rejects_text_result) {
	/* 数值语义出口（@Vars 值/元数据列）：文本结果显式拒绝 */
	TH_CHECK(bot::requireNum(bot::ExprValue::makeNum(2.5)) == 2.5);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "a numeric value is required here",
		(void)bot::requireNum(bot::ExprValue::makeText("relay-2")));
}

/* ==================== 报错不得回显整条原文（2026-09-20 重构阶段 0/4.4）====================
 * 缺陷实证：语法错误消息由 "invalid expression '" + 原文 + "'" 拼成（src/expr.cpp），
 * 原文长度不受限——动作脚本上限 8 MiB，故单条报错最多可把 8 MiB 用户可控字节
 * 灌进 stderr（实测 10k 层括号即 20KB），并可携带 ANSI 控制序列直写操作者终端。
 * 契约：报错保留可诊断的前缀（含错误成因），但引用原文的部分必须截断并有省略标记。
 */
TH_TEST(expr_parse_error_does_not_echo_the_whole_source) {
	std::string huge(20000, '(');
	std::string msg;
	try {
		(void)bot::Expression::parse(huge);
	} catch (const bot::IllegalArgumentException& e) {
		msg = e.what();
	}
	TH_CHECK(!msg.empty());
	/* 成因仍然可诊断 */
	TH_CHECK(msg.find("nesting too deep") != std::string::npos);
	/* 但原文被截断：整条消息远小于原文 */
	TH_CHECK(msg.size() < 512);
	TH_CHECK(msg.size() < huge.size() / 10);
	TH_CHECK(msg.find("...") != std::string::npos || msg.find("…") != std::string::npos);
}

/* ==================== 比较/逻辑运算（2026-10-10 @if 特性） ====================
 * ExprValue 第三态 Bool：仅由比较/逻辑产生（无 true/false 字面量）；
 * 类型严格无隐式转换——数值真值、文本相等、跨类比较各有明确报错，
 * 拼错的条件不许以错误理由成立。 */

TH_TEST(expr_comparison_produces_bool) {
	TH_CHECK(evalMixed("1>0", {}, {}).isBool());
	TH_CHECK(evalMixed("1>0", {}, {}).flag);
	TH_CHECK(!evalMixed("1<0", {}, {}).flag);
	TH_CHECK(evalMixed("2>=2", {}, {}).flag);
	TH_CHECK(evalMixed("2<=1", {}, {}).flag == false);
	TH_CHECK(evalMixed("3>2", {}, {}).flag);
	TH_CHECK(evalMixed("2>3", {}, {}).flag == false);
	/* 算术优先级高于比较（先算再比） */
	TH_CHECK(evalMixed("1+1>=2", {}, {}).flag);
	TH_CHECK(evalMixed("2*3<5", {}, {}).flag == false);
	/* 比较操作数必须数值：文本（@Alias）拒绝 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'>' cannot be applied to a text operand",
		evalMixed("a>0", {}, {{"a", "x"}}));
	/* 链式 a<b<c 语法可解析（左结合），Bool 参与数值比较在求值期拒绝 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'<' cannot be applied to a boolean operand",
		evalMixed("1<2<3", {}, {}));
}

TH_TEST(expr_equality_same_type_only) {
	/* == / != 同类可比：数值、文本（@Alias）、布尔 */
	TH_CHECK(evalMixed("1==1", {}, {}).flag);
	TH_CHECK(evalMixed("1!=2", {}, {}).flag);
	TH_CHECK(evalMixed("a==\"x\"", {}, {{"a", "x"}}).flag);
	TH_CHECK(evalMixed("a!=\"x\"", {}, {{"a", "x"}}).flag == false);
	TH_CHECK(evalMixed("\"x\"==\"x\"", {}, {}).flag);
	TH_CHECK(evalMixed("(1>0)==(2>1)", {}, {}).flag);
	/* 跨类报错——静默的恒不等与隐式转换同样危险 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot compare a number with a text",
		evalMixed("1==\"1\"", {}, {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot compare a boolean with a number",
		evalMixed("(1>0)!=0", {}, {}));
	/* 单 '=' 不是运算符（无赋值语法） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "single '=' is not an operator",
		evalMixed("1=1", {}, {}));
	/* 字符串字面量：未闭合即语法错；与 @Alias 同语义（'+' 拼接） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unterminated string literal",
		evalMixed("a==\"x", {}, {{"a", "x"}}));
	TH_CHECK(evalMixed("\"p\"+n", {}, {{"n", "2"}}).text == "p2");
}

TH_TEST(expr_string_literal_escapes) {
	/* 转义解码：\n \t \r \\ \" 成对应字节——.mt 单元格内字面换行会截格，
	 * 转义是写出换行/引号的唯一通道 */
	TH_CHECK(evalMixed("\"a\\nb\"", {}, {}).text == "a\nb");
	TH_CHECK(evalMixed("\"a\\tb\"", {}, {}).text == "a\tb");
	TH_CHECK(evalMixed("\"a\\rb\"", {}, {}).text == "a\rb");
	TH_CHECK(evalMixed("\"a\\\\b\"", {}, {}).text == "a\\b");
	TH_CHECK(evalMixed("\"a\\\"b\"", {}, {}).text == "a\"b");
	/* 转义与拼接共存；末尾转义引号不提前收口 */
	TH_CHECK(evalMixed("\"x\\n\"+a", {}, {{"a", "y"}}).text == "x\ny");
	TH_CHECK(evalMixed("\"\\\"\"+a", {}, {{"a", "\""}}).text == "\"\"");
	/* 文本比较面同样解码 */
	TH_CHECK(evalMixed("a==\"x\\ny\"", {}, {{"a", "x\ny"}}).flag);
	/* 未知转义响亮报错（不静默吞反斜杠） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unknown escape sequence '\\q'",
		evalMixed("\"a\\qb\"", {}, {}));
	/* 反斜杠吃掉闭引号 / 悬在末尾 → 未闭合 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unterminated string literal",
		evalMixed("\"a\\\"", {}, {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "unterminated string literal",
		evalMixed("\"a\\", {}, {}));
}

TH_TEST(expr_logical_operands_and_precedence) {
	TH_CHECK(evalMixed("(1>0)&&(2>0)", {}, {}).flag);
	TH_CHECK(evalMixed("(1>0)&&(2<0)", {}, {}).flag == false);
	TH_CHECK(evalMixed("(1<0)||(2>0)", {}, {}).flag);
	TH_CHECK(evalMixed("(1<0)||(2<0)", {}, {}).flag == false);
	TH_CHECK(evalMixed("!(1>0)", {}, {}).flag == false);
	TH_CHECK(evalMixed("!!(1>0)", {}, {}).flag);
	/* && 高于 ||：a||(b&&c) 整体为真即使最后一段假 */
	TH_CHECK(evalMixed("(1>0)||(2<0)&&(3<0)", {}, {}).flag);
	/* 操作数必须 Bool：数值/文本没有隐式真值 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'&&' requires logical operands",
		evalMixed("1&&2", {}, {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'||' requires logical operands",
		evalMixed("a||1>0", {}, {{"a", "x"}}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'!' cannot be applied to a number operand",
		evalMixed("!1", {}, {}));
}

TH_TEST(expr_short_circuit_skips_right_operands) {
	/* 短路：左操作数定局即不 eval 右子树——右枝的未定义标识符/除零
	 * 不构成错误（C 语义同型）；存在性校验仍由 collectVars 覆盖 */
	TH_CHECK(evalMixed("(1<0)&&boom", {}, {}).flag == false);
	TH_CHECK(evalMixed("(1>0)||boom", {}, {}).flag);
	TH_CHECK(evalMixed("(1<0)&&(1/0>0)", {}, {}).flag == false);
	/* 反向不短路：左真必 eval 右枝，除零照常报错 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "division by zero",
		evalMixed("(1>0)&&(1/0>0)", {}, {}));
	/* collectVars 是结构遍历：短路右枝的标识符仍被收集（存在性校验视角） */
	std::set<std::string> vars;
	Expression::parse("(a>0)&&boom").collectVars(vars);
	TH_CHECK(vars.count("a") == 1);
	TH_CHECK(vars.count("boom") == 1);
}

TH_TEST(expr_bool_rejected_in_numeric_contexts) {
	/* Bool 不入算术：加、一元负、取模全部拒绝 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'+' cannot be applied to a boolean operand",
		evalMixed("1+(1>0)", {}, {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'-' cannot be applied to a boolean operand",
		evalMixed("-(1>0)", {}, {}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'%' cannot be applied to a boolean operand",
		evalMixed("(1>0)%2", {}, {}));
	/* '+' 的文本拼接不收布尔操作数（不产生 "true…" 型参数） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'+' cannot be applied to a boolean operand",
		evalMixed("(1>0)+\"x\"", {}, {}));
	/* requireNum（@Vars 值/SQL 元数据列出口）拒绝 Bool */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "produced a boolean result",
		bot::requireNum(evalMixed("1>0", {}, {})));
	/* rendered 的 Bool 出口：通用字符串化（"true"/"false"） */
	TH_CHECK(evalMixed("1>0", {}, {}).rendered() == "true");
	TH_CHECK(evalMixed("1<0", {}, {}).rendered() == "false");
}
