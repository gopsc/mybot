#include "expr.hpp"

#include <cmath>
#include <cstdlib>

#include "util_except.hpp"
#include "util_num.hpp"
#include "util_str.hpp"

namespace bot {

/* ==================== 值语义 ==================== */

std::string ExprValue::rendered() const {
	if (isText()) { return text; }
	if (isBool()) { return flag ? "true" : "false"; }
	if (!std::isfinite(num)) {
		throw IllegalArgumentException("expression evaluates to a non-finite value"
			" (inf/nan), which is rejected");
	}
	return formatNumber(num);
}

const char* exprTypeName(const ExprValue& v) {
	switch (v.kind) {
	case ExprValue::Kind::Num: return "number";
	case ExprValue::Kind::Text: return "text";
	case ExprValue::Kind::Bool: return "boolean";
	}
	return "?";
}

ExprValueResolver numericResolver(std::function<double(const std::string&)> f) {
	return [f = std::move(f)](const std::string& name) {
		return ExprValue::makeNum(f(name));
	};
}

double requireNum(const ExprValue& v) {
	if (v.isText()) {
		throw IllegalArgumentException("expression produced a text result"
			" (an @Alias may only take part in '+' concatenation inside @Action"
			" cells); a numeric value is required here");
	}
	if (v.isBool()) {
		throw IllegalArgumentException("expression produced a boolean result"
			" (a comparison or logical expression); logical expressions belong"
			" in an @if(...) condition, not in $(...) on this position");
	}
	return v.num;
}

/* ==================== AST 节点 ==================== */

struct Expression::Impl {
	virtual ~Impl() = default;
	virtual ExprValue eval(const ExprValueResolver& resolve) const = 0;
	virtual void collect(std::set<std::string>& out) const = 0;
};

namespace {

/* 运算符的枚举形态（2026-10-10 @if 特性）：原 char 只装得下算术单字符，
 * 比较与逻辑的双字符 token（<=、==、&&、||）进来后统一走 enum，
 * eval 的分派与文案不再做字符手拼。 */
enum class BinOp { Add, Sub, Mul, Div, Mod, Lt, Gt, Le, Ge, Eq, Ne, And, Or };
enum class UnOp { Plus, Minus, Not };

/* 运算符的报错显示形态：与源语法逐字一致（含双字符），单点。 */
const char* binOpText(BinOp op) {
	switch (op) {
	case BinOp::Add: return "+";
	case BinOp::Sub: return "-";
	case BinOp::Mul: return "*";
	case BinOp::Div: return "/";
	case BinOp::Mod: return "%";
	case BinOp::Lt: return "<";
	case BinOp::Gt: return ">";
	case BinOp::Le: return "<=";
	case BinOp::Ge: return ">=";
	case BinOp::Eq: return "==";
	case BinOp::Ne: return "!=";
	case BinOp::And: return "&&";
	case BinOp::Or: return "||";
	}
	return "?";
}

/* 非数值操作数只允许出现在 '+' 里（拼接）；其余算术/比较运算符对文本与
 * 布尔无定义。文案单点：BinNode 与 UnNode 共用。 */
[[noreturn]] void throwNonNumOperand(BinOp op, const ExprValue& v) {
	throw IllegalArgumentException(std::string("expression operator '") + binOpText(op)
		+ "' cannot be applied to a " + exprTypeName(v)
		+ " operand; only numbers (and '+' text concatenation) are defined here");
}

/* 数值比较分支的非有限防线：原「非有限中间结果必然传播到根节点」的出口
 * 论断只对算术成立——比较会**消费**数值产出 Bool，inf/nan 在此不再向上
 * 传播（`1e308*10>0` 的根是 Bool）。IEEE 语义里 inf>0 为真、nan>0 为假，
 * 让非有限值以如此静默的理由决定 @if 分支，等于把「拒绝」防线放宽成
 * 「碰巧有定义」；故比较分支就地维持同一句拒绝文案。
 * 调用方已保证两侧为 Num（文本/布尔在比较前已被 throwNonNumOperand 拒）。 */
void requireFiniteForCompare(const ExprValue& a, const ExprValue& b) {
	if (!std::isfinite(a.num) || !std::isfinite(b.num)) {
		throw IllegalArgumentException("expression evaluates to a non-finite value"
			" (inf/nan), which is rejected");
	}
}

struct NumNode : Expression::Impl {
	double v;
	explicit NumNode(double x) : v(x) {}
	ExprValue eval(const ExprValueResolver&) const override { return ExprValue::makeNum(v); }
	void collect(std::set<std::string>&) const override {}
};

/* 字符串字面量（"x"，2026-10-10 @if 特性）：文本比较（@if(mode=="auto")）
 * 的必要面——此前文本只能来自标识符（@Alias），与常量比对写不出来。
 * 转义 \n \t \r \\ \" 在解析期解码成对应字节，未知转义响亮报错（值内可含
 * '"' 与控制字符；含空格受上层切格/块头约束，不在此重复禁），
 * 未闭合在解析期报错。除比较外与 @Alias 值同语义（'+' 拼接、rendered 原样）。 */
struct StrNode : Expression::Impl {
	std::string v;
	explicit StrNode(std::string s) : v(std::move(s)) {}
	ExprValue eval(const ExprValueResolver&) const override { return ExprValue::makeText(v); }
	void collect(std::set<std::string>&) const override {}
};

struct VarNode : Expression::Impl {
	std::string name;
	explicit VarNode(std::string n) : name(std::move(n)) {}
	ExprValue eval(const ExprValueResolver& resolve) const override { return resolve(name); }
	void collect(std::set<std::string>& out) const override { out.insert(name); }
};

struct UnNode : Expression::Impl {
	UnOp op;
	std::shared_ptr<const Expression::Impl> child;
	UnNode(UnOp o, std::shared_ptr<const Expression::Impl> c)
		: op(o), child(std::move(c)) {}
	ExprValue eval(const ExprValueResolver& resolve) const override {
		ExprValue v = child->eval(resolve);
		if (op == UnOp::Not) {
			if (!v.isBool()) {
				throw IllegalArgumentException(std::string("expression operator '!'")
					+ " cannot be applied to a " + exprTypeName(v)
					+ " operand; '!' negates a logical expression");
			}
			return ExprValue::makeBool(!v.flag);
		}
		if (!v.isNum()) { throwNonNumOperand(op == UnOp::Plus ? BinOp::Add : BinOp::Sub, v); }
		return op == UnOp::Minus ? ExprValue::makeNum(-v.num) : v;
	}
	void collect(std::set<std::string>& out) const override { child->collect(out); }
};

/* Bool 逻辑与同类相等判定的公共出口：&&(||) 的两侧都必须已是 Bool——
 * 数值真值不隐式转换（静默的真值语义会让拼错的条件以错误理由成立）。 */
void requireBoolOperand(const char* opText, const ExprValue& v) {
	if (!v.isBool()) {
		throw IllegalArgumentException(std::string("expression operator '") + opText
			+ "' requires logical operands; a " + exprTypeName(v)
			+ " operand is not implicitly true/false"
			+ " (compare explicitly, e.g. 'x>0')");
	}
}

struct BinNode : Expression::Impl {
	BinOp op;
	std::shared_ptr<const Expression::Impl> l, r;
	BinNode(BinOp o, std::shared_ptr<const Expression::Impl> a,
			std::shared_ptr<const Expression::Impl> b)
		: op(o), l(std::move(a)), r(std::move(b)) {}
	ExprValue eval(const ExprValueResolver& resolve) const override {
		/* && / || 短路：左操作数定局即不 eval 右子树——不仅是省算力，
		 * 右枝的除零/未定义标识符在短路下不构成错误（C 语义同型），
		 * 存在性校验仍由 collectVars 的结构遍历覆盖（与求值无关）。 */
		if (op == BinOp::And || op == BinOp::Or) {
			ExprValue a = l->eval(resolve);
			requireBoolOperand(binOpText(op), a);
			if (op == BinOp::And && !a.flag) { return ExprValue::makeBool(false); }
			if (op == BinOp::Or && a.flag) { return ExprValue::makeBool(true); }
			ExprValue b = r->eval(resolve);
			requireBoolOperand(binOpText(op), b);
			return ExprValue::makeBool(b.flag);
		}
		ExprValue a = l->eval(resolve);
		ExprValue b = r->eval(resolve);
		/* '+' 类型分派：出现文本操作数即拼接（数值操作数以真值文本参与），
		 * 全数值才是算术加。「两个 @Vars 做运算、有一个 @Alias 就拼接」。
		 * 布尔操作数不参与拼接——'true'+x 流入参数只会掩盖「逻辑表达式
		 * 写错了位置」，消费面自有专门拒绝文案。 */
		if (op == BinOp::Add) {
			if (a.isText() || b.isText()) {
				if (a.isBool() || b.isBool()) { throwNonNumOperand(op, a.isBool() ? a : b); }
				return ExprValue::makeText(a.rendered() + b.rendered());
			}
		}
		/* Eq/Ne 是唯一收文本/布尔的二元运算（同类比较，分支内自带类型
		 * 检查与跨类报错），不走数值/拼接的通用拦截。 */
		const bool equality = (op == BinOp::Eq || op == BinOp::Ne);
		if (!equality && (a.isText() || b.isText() || a.isBool() || b.isBool())) {
			throwNonNumOperand(op, a.isBool() || b.isBool()
				? (a.isBool() ? a : b) : (a.isText() ? a : b));
		}
		switch (op) {
		case BinOp::Add: return ExprValue::makeNum(a.num + b.num);
		case BinOp::Sub: return ExprValue::makeNum(a.num - b.num);
		case BinOp::Mul: return ExprValue::makeNum(a.num * b.num);
		case BinOp::Div:
			if (b.num == 0.0) { throw IllegalArgumentException("expression division by zero"); }
			return ExprValue::makeNum(a.num / b.num);
		case BinOp::Mod:
			if (b.num == 0.0) { throw IllegalArgumentException("expression modulo by zero"); }
			return ExprValue::makeNum(std::fmod(a.num, b.num));
		case BinOp::Lt: requireFiniteForCompare(a, b); return ExprValue::makeBool(a.num < b.num);
		case BinOp::Gt: requireFiniteForCompare(a, b); return ExprValue::makeBool(a.num > b.num);
		case BinOp::Le: requireFiniteForCompare(a, b); return ExprValue::makeBool(a.num <= b.num);
		case BinOp::Ge: requireFiniteForCompare(a, b); return ExprValue::makeBool(a.num >= b.num);
		case BinOp::Eq:
		case BinOp::Ne: {
			/* == / != 同类可比（数值/文本/布尔），跨类报错——静默的
			 * "1=='1' 恒不等" 与隐式转换一样，让拼错的条件以错误理由成立。 */
			if (a.kind != b.kind) {
				throw IllegalArgumentException(std::string("expression operator '")
					+ binOpText(op) + "' cannot compare a " + exprTypeName(a)
					+ " with a " + exprTypeName(b) + "; both operands must have the same type");
			}
			if (a.isNum()) { requireFiniteForCompare(a, b); }
			bool eq = a.isBool() ? (a.flag == b.flag)
				: a.isText() ? (a.text == b.text) : (a.num == b.num);
			return ExprValue::makeBool(op == BinOp::Eq ? eq : !eq);
		}
		case BinOp::And:
		case BinOp::Or:
			break;	/* 已在上方短路层处理，到这里即内部错误 */
		}
		throw IllegalArgumentException("expression internal error: unknown operator");
	}
	void collect(std::set<std::string>& out) const override { l->collect(out); r->collect(out); }
};

bool isDigit(char c) { return c >= '0' && c <= '9'; }
bool isIdentStart(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
bool isIdentChar(char c) { return isIdentStart(c) || isDigit(c); }

/* 报错里的原文引用（2026-09-20 重构阶段 4.4 首落地，审计 C4 后收敛到单点）：
 * 旧实现把整条表达式原样拼进报错，而表达式长度只受动作脚本 8 MiB 上限约束
 * ——一条语法错误即可把用户可控的兆级字节灌进 stderr（实测 10k 层括号 → 20KB），
 * 且原文可携带 ANSI 控制序列直写操作者终端。
 * 现统一走 util_str.hpp 的 echoSource（转义不可打印字节 + 截断到 kMaxEchoChars +
 * 省略标记）：矩阵单元格报错（hardware.cpp）与表达式报错共用同一判据，
 * 不再出现「同类缺陷只修了一条路径」。 */

/* 递归下降解析器。两处深度上限：
 * ① 括号递归（depth_）：8 MiB 脚本字节上限下，数万层 '(' 会打爆宿主栈；
 * ② 运算符链（ops_）：平铺的 '+'/'*'/'&&' 链不经过括号递归，由 parseSum/
 *    parseTerm/parseAnd/parseOr 的循环就地折叠成左深树——kMaxDepth 拦不住
 *    它，而 BinNode::eval 的递归深度等于树深，无界链会在求值期 SIGSEGV（且
 *    崩溃点在硬件 build 之后，绕过 deactivate 清理链）。限制单表达式运算符
 *    总数（含比较/逻辑）后，树深上界为 kMaxDepth + kMaxOps，求值递归安全。 */
class ExprParser {
	const std::string& s_;
	std::size_t pos_ = 0;
	int depth_ = 0;
	int ops_ = 0;
	static constexpr int kMaxDepth = 128;
	static constexpr int kMaxOps = 512;

	[[noreturn]] void fail(const std::string& msg) const {
		throw IllegalArgumentException("invalid expression '" + echoSource(s_) + "': " + msg
			+ " at position " + std::to_string(pos_));
	}
	char peek() const { return pos_ < s_.size() ? s_[pos_] : '\0'; }
	char peekAt(std::size_t off) const { return pos_ + off < s_.size() ? s_[pos_ + off] : '\0'; }
	void skipWs() {
		while (pos_ < s_.size()) {
			char c = s_[pos_];
			if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { ++pos_; }
			else { break; }
		}
	}

	using Node = std::shared_ptr<const Expression::Impl>;

	/* 自顶向下的优先级层（2026-10-10 @if 特性新增比较/逻辑层）：
	 *   parseOr(||) → parseAnd(&&) → parseCmp(比较) → parseSum(加减)
	 *   → parseTerm(乘除模) → parseUnary → parsePrimary
	 * 与 C 一致（&& 高于 ||；比较高于逻辑；算术高于比较）。 */
	Node parseOr() {
		Node node = parseAnd();
		for (;;) {
			skipWs();
			if (!(peek() == '|' && peekAt(1) == '|')) { break; }
			pos_ += 2;
			if (++ops_ > kMaxOps) { fail("too many operators in one expression"); }
			node = std::make_shared<BinNode>(BinOp::Or, std::move(node), parseAnd());
		}
		return node;
	}

	Node parseAnd() {
		Node node = parseCmp();
		for (;;) {
			skipWs();
			if (!(peek() == '&' && peekAt(1) == '&')) { break; }
			pos_ += 2;
			if (++ops_ > kMaxOps) { fail("too many operators in one expression"); }
			node = std::make_shared<BinNode>(BinOp::And, std::move(node), parseCmp());
		}
		return node;
	}

	/* 比较层：链式写法（a<b<c）语法上可解析——左结合成 (a<b)<c，Bool 参与
	 * 数值比较在求值期被类型防线拒绝，无需解析期特判。 */
	Node parseCmp() {
		Node node = parseSum();
		for (;;) {
			skipWs();
			char c = peek();
			BinOp op;
			if (c == '<') {
				if (peekAt(1) == '=') { pos_ += 2; op = BinOp::Le; }
				else { ++pos_; op = BinOp::Lt; }
			} else if (c == '>') {
				if (peekAt(1) == '=') { pos_ += 2; op = BinOp::Ge; }
				else { ++pos_; op = BinOp::Gt; }
			} else if (c == '=' && peekAt(1) == '=') {
				pos_ += 2;
				op = BinOp::Eq;
			} else if (c == '!' && peekAt(1) == '=') {
				pos_ += 2;
				op = BinOp::Ne;
			} else {
				/* 单 '=' 不是运算符（无赋值语法）——在此显式点名，
				 * 比「unexpected character」可救红。 */
				if (c == '=') { fail("single '=' is not an operator; equality is '=='"); }
				break;
			}
			if (++ops_ > kMaxOps) { fail("too many operators in one expression"); }
			node = std::make_shared<BinNode>(op, std::move(node), parseSum());
		}
		return node;
	}

	Node parseSum() {
		Node node = parseTerm();
		for (;;) {
			skipWs();
			char c = peek();
			if (c != '+' && c != '-') { break; }
			++pos_;
			if (++ops_ > kMaxOps) { fail("too many operators in one expression"); }
			node = std::make_shared<BinNode>(c == '+' ? BinOp::Add : BinOp::Sub,
				std::move(node), parseTerm());
		}
		return node;
	}

	Node parseTerm() {
		Node node = parseUnary();
		for (;;) {
			skipWs();
			char c = peek();
			BinOp op;
			if (c == '*') { op = BinOp::Mul; }
			else if (c == '/') { op = BinOp::Div; }
			else if (c == '%') { op = BinOp::Mod; }
			else { break; }
			++pos_;
			if (++ops_ > kMaxOps) { fail("too many operators in one expression"); }
			node = std::make_shared<BinNode>(op, std::move(node), parseUnary());
		}
		return node;
	}

	/* 一元正负与逻辑非：迭代收集（避免长串 '-----x'/'!!!x' 递归打爆栈）。
	 * '!' 与正负可混排（'!-x'），求值期按各自操作数类型分别拒绝——
	 * '!' 只收 Bool、'-' 只收 Num，混用即响亮报错。 */
	Node parseUnary() {
		bool neg = false;
		int nots = 0;
		for (;;) {
			skipWs();
			char c = peek();
			if (c == '+') { ++pos_; }
			else if (c == '-') { neg = !neg; ++pos_; }
			else if (c == '!' && peekAt(1) != '=') { ++nots; ++pos_; }
			else { break; }
		}
		Node node = parsePrimary();
		if (neg) { node = std::make_shared<UnNode>(UnOp::Minus, std::move(node)); }
		if (nots % 2 == 1) { node = std::make_shared<UnNode>(UnOp::Not, std::move(node)); }
		return node;
	}

	Node parsePrimary() {
		skipWs();
		char c = peek();
		if (c == '\0') { fail("unexpected end of expression"); }
		if (c == '(') {
			++pos_;
			if (++depth_ > kMaxDepth) { fail("expression nesting too deep"); }
			Node node = parseOr();
			skipWs();
			if (peek() != ')') { fail("expected ')'"); }
			++pos_;
			--depth_;
			return node;
		}
		if (isDigit(c) || (c == '.' && isDigit(pos_ + 1 < s_.size() ? s_[pos_ + 1] : '\0'))) {
			return parseNumber();
		}
		if (c == '"') { return parseString(); }
		if (isIdentStart(c)) { return parseVar(); }
		fail(std::string("unexpected character '") + c + "'");
	}

	/* 字符串字面量："..."，转义 \n \t \r \\ \" 解码成对应字节，未知转义响亮
	 * 报错（不静默吞反斜杠——"C:\tmp" 悄悄变 "C:tmp" 是以错误理由成立）；
	 * 未闭合即语法错（见 StrNode 的语义注释）。转义是唯一能在 .mt 单元格里
	 * 写出换行/引号的通道（切格/';' 约束在矩阵层，字面换行会截格，故 $(...)
	 * 与 @if(...) 里的控制字符一律写转义形态）。 */
	Node parseString() {
		++pos_;	/* 吃开引号 */
		std::string v;
		for (;;) {
			if (pos_ >= s_.size()) { fail("unterminated string literal (missing closing '\"')"); }
			char c = s_[pos_++];
			if (c == '"') { break; }	/* 吃闭引号 */
			if (c != '\\') { v += c; continue; }
			if (pos_ >= s_.size()) { fail("unterminated string literal (missing closing '\"')"); }
			char e = s_[pos_++];
			switch (e) {
			case 'n': v += '\n'; break;
			case 't': v += '\t'; break;
			case 'r': v += '\r'; break;
			case '\\': v += '\\'; break;
			case '"': v += '"'; break;
			default:
				fail(std::string("unknown escape sequence '\\") + e
					+ "' (supported escapes: \\n \\t \\r \\\\ \\\")");
			}
		}
		return std::make_shared<StrNode>(std::move(v));
	}

	Node parseNumber() {
		std::size_t start = pos_;
		while (isDigit(peek())) { ++pos_; }
		if (peek() == '.') {
			++pos_;
			while (isDigit(peek())) { ++pos_; }
		}
		if (peek() == 'e' || peek() == 'E') {
			std::size_t save = pos_;
			++pos_;
			if (peek() == '+' || peek() == '-') { ++pos_; }
			if (isDigit(peek())) {
				while (isDigit(peek())) { ++pos_; }
			} else {
				pos_ = save;	/* 不是指数，回退（如 "1e" 视为 1） */
			}
		}
		std::string tok = s_.substr(start, pos_ - start);
		double v = 0.0;
		if (parseFiniteDouble(tok, v) != ParseFiniteStatus::OK) {
			fail("invalid numeric literal");
		}
		return std::make_shared<NumNode>(v);
	}

	Node parseVar() {
		std::size_t start = pos_;
		++pos_;
		while (isIdentChar(peek())) { ++pos_; }
		return std::make_shared<VarNode>(s_.substr(start, pos_ - start));
	}

public:
	explicit ExprParser(const std::string& s) : s_(s) {}

	Node parse() {
		skipWs();
		if (pos_ >= s_.size()) { fail("empty expression"); }
		Node node = parseOr();
		skipWs();
		if (pos_ != s_.size()) { fail("unexpected trailing input"); }
		return node;
	}
};

} // namespace

Expression Expression::parse(const std::string& text) {
	Expression e;
	e.impl_ = ExprParser(text).parse();
	return e;
}

ExprValue Expression::eval(const ExprValueResolver& resolve) const {
	if (!impl_) { throw IllegalArgumentException("evaluation of an empty expression"); }
	ExprValue v = impl_->eval(resolve);
	/* 有限值防线：字面量在 parseNumber 已拒 inf/nan，但中间结果仍可能溢出
	 * （如 1e308*1e308 → inf；inf-inf → nan）。IEEE 语义下任何非有限中间
	 * 结果必然传播到根节点，故在出口处一次检查即可封死旁路——否则 inf/nan
	 * 会经 JsonFloat/lua_pushnumber 流入驱动参数（正是 hardware.cpp 字面量
	 * 防线要拦的形态，TCP 模式下可由远程动作脚本触发）。文本与布尔结果中
	 * 不可能藏非有限数值：拼接经 rendered() 渲染数值真值、比较分支就地拒绝
	 * 非有限操作数（见 requireFiniteForCompare），两处同样拒绝。 */
	if (v.isNum() && !std::isfinite(v.num)) {
		throw IllegalArgumentException("expression evaluates to a non-finite value"
			" (inf/nan), which is rejected");
	}
	return v;
}

void Expression::collectVars(std::set<std::string>& out) const {
	if (impl_) { impl_->collect(out); }
}

std::optional<std::string> exprBody(const std::string& value) {
	if (value.size() >= 3 && value[0] == '$' && value[1] == '(' && value.back() == ')') {
		return value.substr(2, value.size() - 3);
	}
	return std::nullopt;
}

} // namespace bot
