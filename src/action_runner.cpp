/* action_runner.cpp —— @Action 逐行重放（拆自 robot.cpp 阶段 R-1）
 * ActionPlan：列头解析 + 撞设备查重 + 相位设备判定的纯计算产物；
 * runAction：行循环派发（stop 检查 + 单元格解析 + 按 order play）。 */

#include "action_runner.hpp"

#include <algorithm>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string_view>
#include <utility>

#include "util_env.hpp"
#include "util_num.hpp"

namespace bot {

/* ---- 设备列解析单点（契约见 robot.hpp 的声明处）---- */
std::string ActionRunner::resolveActionDevice(const HwLookup& registry, const std::string& dev) {
	/* $(...) 设备位：求值产物作为设备名候选，走与裸名相同的解析。产物本身
	 * 不再递归求值——别名值即使形如 "$(…)" 也只按文本查找（下方 read() 出的
	 * target 直接 find，不过 exprBody），自引用环无从建立。 */
	std::string name = dev;
	if (auto body = exprBody(dev)) {
		ExprValue v = Expression::parse(*body).eval(registry.makeActionExprResolver());
		if (v.isBool()) {
			throw IllegalArgumentException("@Action 设备列的 $(...) 不能产出布尔结果"
				"（比较/逻辑表达式属于 @if(...) 条件）；设备位需要设备名（文本）");
		}
		name = v.rendered();
	}
	MatrixVars_Hardware* hv = registry.find(name);
	if (hv == nullptr || !hv->isScalarText()) { return name; }
	if (std::string_view(hv->kindName()) == "vars") {
		throw IllegalArgumentException("@Vars '" + name
			+ "' is a numeric constant and cannot name a device in an @Action"
			" column; use an @Alias or the device name itself.");
	}
	std::string target = hv->read().asString().getValue();
	MatrixVars_Hardware* resolved = registry.find(target);
	if (resolved == nullptr) {
		throw IllegalArgumentException("@Action device column '" + dev
			+ "' resolves via @Alias to '" + target + "', but '" + target
			+ "' is not a defined hardware variable.");
	}
	if (resolved->isScalarText()) {
		throw IllegalArgumentException("@Action device column '" + dev
			+ "' resolves via @Alias to '" + target + "', which is itself a"
			" scalar (@Alias/@Vars); the device part must name a driver or daemon"
			" variable (one level of alias indirection is supported).");
	}
	return target;
}

/* ---- 参数位解析单点（契约见 robot.hpp 的声明处）----
 * 派发期内别名/变量不变（标量文本无副作用、$(...) 是纯求值），每列解析一次；
 * 解析产物即参数名，不再解析（参数名不是名字绑定）。 */
std::string ActionRunner::resolveActionParam(const HwLookup& registry, const std::string& param) {
	if (auto body = exprBody(param)) {
		ExprValue v = Expression::parse(*body).eval(registry.makeActionExprResolver());
		if (v.isBool()) {
			throw IllegalArgumentException("@Action 参数位的 $(...) 不能产出布尔结果"
				"（比较/逻辑表达式属于 @if(...) 条件）；参数位需要参数名（文本）");
		}
		return v.rendered();
	}
	MatrixVars_Hardware* hv = registry.find(param);
	if (hv != nullptr && hv->isScalarText()) {
		return hv->read().asString().getValue();
	}
	return param;
}

/* ---- 派发计划构建：列头解析 + 撞设备查重 + 相位设备判定（纯计算）---- */
ActionPlan ActionPlan::build(const HwLookup& registry, const mt::MatrixObject& actionDefs) {
	ActionPlan plan;
	plan.colHeads.reserve(static_cast<std::size_t>(actionDefs.cols()));
	plan.devs.reserve(static_cast<std::size_t>(actionDefs.cols()));
	plan.params.reserve(static_cast<std::size_t>(actionDefs.cols()));
	for (std::int64_t j = 0; j < static_cast<std::int64_t>(actionDefs.cols()); ++j) {
		plan.colHeads.push_back(mt::splitActionColumn(actionDefs(0, j)));
		plan.devs.push_back(ActionRunner::resolveActionDevice(registry, plan.colHeads.back().first));
		plan.params.push_back(ActionRunner::resolveActionParam(registry, plan.colHeads.back().second));
		if (std::find(plan.order.begin(), plan.order.end(), plan.devs.back()) == plan.order.end()) {
			plan.order.push_back(plan.devs.back());
		}
		auto cell = plan.seenCell.emplace(
			std::make_pair(plan.devs.back(), plan.params.back()),
			actionDefs(0, j));
		if (!cell.second) {
			throw IllegalArgumentException("Action column '" + actionDefs(0, j)
				+ "' targets " + plan.devs.back() + "." + plan.params.back()
				+ ", already targeted by column '" + cell.first->second
				+ "'; a device parameter may appear in only one @Action column"
				+ " (duplicates would silently overwrite each other row by row).");
		}
	}

	for (std::int64_t j = 0; j < static_cast<std::int64_t>(actionDefs.cols()); ++j) {
		const std::string& name_dev = plan.devs[static_cast<std::size_t>(j)];
		if (plan.phaseDevices.count(name_dev) > 0) { continue; }
		for (std::int64_t r = 1; r < static_cast<std::int64_t>(actionDefs.rows()); ++r) {
			const std::string& v = actionDefs(r, j);
			if (v != "-" && !v.empty()) { plan.phaseDevices.insert(name_dev); break; }
		}
	}
	return plan;
}

/* ---- 单矩阵动作派发核心（@Action 与 #34 @Reflex 共用；runAction 找
 * "Action" 表、runReflex 按触发取反射定义表，派发逻辑完全同一份）---- */
void ActionRunner::dispatchMatrix(const mt::MatrixObject& actionDefs) {
	/* 列头解析 / 撞设备查重 / 相位设备判定（纯计算，单点在 ActionPlan::build） */
	ActionPlan plan = ActionPlan::build(registry_, actionDefs);

	std::vector<ColExprCache> exprCache(static_cast<std::size_t>(actionDefs.cols()));
	for (std::int64_t i = 1; i < static_cast<std::int64_t>(actionDefs.rows()); ++i) {
		/* D4：SIGINT/SIGTERM 后停止派发新动作帧，让 deactivate 清理链正常执行 */
		if (stopRequested()) {
			std::cerr << "Stop requested, halting action dispatch (row " << i << ")" << std::endl;
			break;
		}
		Json set = JsonObject();
		std::map<std::string, std::vector<Capture>> captures;
		for (std::int64_t j = 0; j < static_cast<std::int64_t>(actionDefs.cols()); ++j) {
			parseActionCell(set, actionDefs, i, j, plan.phaseDevices,
				plan.params[static_cast<std::size_t>(j)],
				plan.devs[static_cast<std::size_t>(j)],
				exprCache[static_cast<std::size_t>(j)],
				captures);
		}
		for (const std::string& name_dev : plan.order) {
			MatrixVars_Hardware* hv = registry_.find(name_dev);
			if (hv == nullptr) {
				throw IllegalArgumentException("Hardware variable '" + name_dev
					+ "' is used in @Action (row " + std::to_string(i)
					+ ") but not defined in your hardware declaration section.");
			}
			const auto capIt = captures.find(name_dev);
			const bool hasCaps = capIt != captures.end() && !capIt->second.empty();
			auto paramsOpt = set.get(name_dev);
			if (!paramsOpt && !hasCaps) {
				/* 该设备本行所有参数列都未起拍（无可继承的 "-"，典型来自 mtmerge
				 * 相位前导）且无捕获 → 不派发。旧行为会以 0.0 误发一次指令，把「还没
				 * 轮到」伪装成「指令为 0」；耗尽侧的行尾 "-" 会继承前值，不会走到这里。 */
				continue;
			}
			/* 捕获格不传参：只有捕获而无普通参数的设备仍需 play（以空参数触发一次
			 * 读取/调用），否则无从拿到返回值来提取字段。 */
			if (!paramsOpt) { paramsOpt = JsonObject(); }
			Json res = hv->play(*paramsOpt);
			MatrixVars_Hardware::ensureOk(res, "play " + name_dev + " (row " + std::to_string(i) + ")");
			if (hasCaps) {
				for (const Capture& cap : capIt->second) {
					applyCapture(res, cap, i);
				}
			}
		}
	}
}

/* ---- @if(条件)/@while(条件) 块头解析共用 helper ----
 * 「关键字 + 括号参数」文本协议：trim、rfind(')') 必须行尾闭合、参数体 trim。
 * 块名来自 MatrixParser 名字态（无空格），但白盒单测可直接喂任意串，形态校验
 * 按文本自洽做。kw = 关键字（"if"/"while"），报错文案按它参数化——"if" 分支
 * 逐字复现既有 @if 文案（test_action_if.cpp 锚定的子串不变）。 */
static std::optional<std::string> parseCondBlockName(const std::string& rawName,
		const char* kw) {
	const std::string name = bot::trim(rawName);
	const std::string at = std::string("@") + kw;
	const std::size_t lp = name.find('(');
	if (lp == std::string::npos) {
		if (name == kw) {
			throw IllegalArgumentException(at + " 块缺条件表达式，写法 " + at
				+ "(<条件>)（条件如 " + at + "(threshold>0)）");
		}
		return std::nullopt;
	}
	if (name.compare(0, lp, kw) != 0) { return std::nullopt; }
	const std::size_t rp = name.rfind(')');
	if (rp == std::string::npos || rp != name.size() - 1) {
		throw IllegalArgumentException(at + " 块头未在块头内闭合：'" + name
			+ "'。注意块头内不能有空格（矩阵解析把空白当分隔，" + at
			+ "(a > b) 会被切成块名 \"" + kw + "(a\" 和数据行），请写成 "
			+ at + "(a>b)");
	}
	const std::string cond = bot::trim(name.substr(lp + 1, rp - lp - 1));
	if (cond.empty()) {
		throw IllegalArgumentException(at + "() 的条件为空；写法 " + at
			+ "(<条件>)，如 " + at + "(threshold>0)");
	}
	return cond;
}

std::optional<std::string> ActionRunner::parseIfBlockName(const std::string& rawName) {
	return parseCondBlockName(rawName, "if");
}

std::optional<std::string> ActionRunner::parseWhileBlockName(const std::string& rawName) {
	return parseCondBlockName(rawName, "while");
}

/* ---- @if 条件求值（块级，轮到该块执行时）---- */
bool ActionRunner::evalIfCondition(const std::string& cond) const {
	ExprValue v = Expression::parse(cond).eval(registry_.makeActionExprResolver());
	if (!v.isBool()) {
		throw IllegalArgumentException("@if(...) 的条件必须是逻辑表达式"
			"（比较/逻辑运算，如 @if(threshold>0)），当前结果类型是 "
			+ std::string(exprTypeName(v))
			+ "；数值/文本没有隐式真值语义，请写出显式比较");
	}
	return v.flag;
}

/* ---- @Action 数据格捕获形态解析（契约见 action_runner.hpp 声明处）---- */
std::optional<Capture> ActionRunner::parseCaptureCell(const std::string& raw,
		const std::string& colHead) {
	if (raw.empty() || raw[0] != '$') { return std::nullopt; }
	/* "$(" 是 $(...) 表达式（由 exprBody 先接管）；白盒直喂时也在此让路。 */
	if (raw.size() >= 2 && raw[1] == '(') { return std::nullopt; }
	const std::size_t eq = raw.find('=');
	if (eq == std::string::npos) {
		throw IllegalArgumentException("@Action 单元格 '" + raw + "'（列 '" + colHead
			+ "'）以 '$' 开头，但既不是 $(...) 表达式、也不是捕获 '$var=field'"
			+ "（列头设备位/参数位或数据格请写数值、$(...)、或 $var=字段名）");
	}
	Capture cap;
	cap.colHead = colHead;
	cap.var = raw.substr(1, eq - 1);
	cap.path = raw.substr(eq + 1);
	if (!isSafeIdent(cap.var)) {
		throw IllegalArgumentException("@Action 捕获目标变量名不是安全标识符：'" + cap.var
			+ "'（列 '" + colHead + "'，形态 $var=field）");
	}
	if (cap.path.empty()) {
		throw IllegalArgumentException("@Action 捕获 '" + raw + "'（列 '" + colHead
			+ "'）缺少字段名，形态 $var=field");
	}
	if (cap.path.front() == '.' || cap.path.back() == '.'
			|| cap.path.find("..") != std::string::npos) {
		throw IllegalArgumentException("@Action 捕获字段路径 '" + cap.path + "'（列 '"
			+ colHead + "'）含空段（点号分隔的每一段都不得为空）");
	}
	return cap;
}

namespace {

/* 按点号路径从返回值下钻取字段：中途非对象、或某段缺失都响亮报错（halt-on-error）。
 * ctx 是报错归因前缀（行号 + 列头 + 捕获原文）。返回叶子值的拷贝（字段一般很小）。 */
Json extractFieldPath(const Json& res, const std::string& path, const std::string& ctx) {
	const Json* cur = &res;
	std::size_t start = 0;
	while (true) {
		const std::size_t dot = path.find('.', start);
		const std::string seg = path.substr(start,
			dot == std::string::npos ? std::string::npos : dot - start);
		if (!cur->isObj()) {
			throw IllegalArgumentException("capture " + ctx + ": cannot descend into field '"
				+ seg + "' — the value at that level is not an object (path '" + path + "')");
		}
		const Json* next = cur->find(seg);
		if (next == nullptr) {
			throw IllegalArgumentException("capture " + ctx + ": field '" + seg
				+ "' is not present in the return value (path '" + path + "')");
		}
		cur = next;
		if (dot == std::string::npos) { break; }
		start = dot + 1;
	}
	return *cur;
}

/* 字段值 → @Alias 文本：Str 原样、数值以 formatNumber（%.15g）渲染、Bool 渲染
 * "true"/"false"；obj/arr/null 无法有意义文本化，拒绝。 */
std::string fieldToText(const Json& v, const std::string& ctx) {
	switch (v.type) {
	case Json::T::Str: return v.s;
	case Json::T::Int: return formatNumber(static_cast<double>(v.i));
	case Json::T::Float: return formatNumber(v.d);
	case Json::T::Bool: return v.b ? "true" : "false";
	default:
		throw IllegalArgumentException("capture " + ctx + ": the field value cannot be"
			+ std::string(" assigned to an @Alias (text) variable; only string/number/bool"
				" fields are accepted (object/array/null are not)"));
	}
}

double jsonNum(const Json& v) {
	return v.isInt() ? static_cast<double>(v.getInt()) : v.getFloat();
}

} // namespace

/* ---- 捕获赋值（play 之后落地；契约见 action_runner.hpp 声明处）---- */
void ActionRunner::applyCapture(const Json& res, const Capture& cap, std::int64_t row) {
	const std::string ctx = "(row " + std::to_string(row) + ", column '" + cap.colHead
		+ "', $" + cap.var + "=" + cap.path + ")";
	const Json val = extractFieldPath(res, cap.path, ctx);

	MatrixVars_Hardware* existing = registry_.find(cap.var);
	std::unique_ptr<MatrixVars_Hardware> nv;
	if (existing != nullptr) {
		const std::string_view kind = existing->kindName();
		if (kind == "vars") {
			if (!val.isInt() && !val.isFloat()) {
				throw IllegalArgumentException("capture " + ctx + ": target @Vars '" + cap.var
					+ "' requires a numeric field, but the captured value is not a number");
			}
			nv = MtVars_Vars::Make(jsonNum(val));
		} else if (kind == "alias") {
			nv = MtVars_Alias::Make(fieldToText(val, ctx));
		} else {
			throw IllegalArgumentException("capture " + ctx + ": target '" + cap.var
				+ "' is not an @Vars/@Alias scalar; a driver/daemon variable has no"
				" settable text value (cannot capture into it)");
		}
	} else if (val.isInt() || val.isFloat()) {
		nv = MtVars_Vars::Make(jsonNum(val));
	} else if (val.isStr()) {
		nv = MtVars_Alias::Make(val.getValue());
	} else {
		throw IllegalArgumentException("capture " + ctx + ": variable '" + cap.var
			+ "' is not declared, and its kind cannot be inferred from a bool/object/"
			"array/null field; declare it as @Vars (numeric) or @Alias (text) first");
	}
	/* 写进会话覆盖层：遮蔽同名结构定义（本次 run 内），run() 结束回滚。
	 * 被引用为 controller/trigger 的名字由 override 拒绝（安全不变式）。 */
	registry_.override(cap.var, std::move(nv));
}

namespace {

/* @if 跳过注记的行数：统计一段 children 里所有 @Action 后代块的数据行（去表头）
 * 合计。@块嵌套后控制块自身网格为空、体在 children，故须下钻——扁平场景下与旧
 * 「@if 自身网格行数」等值。递归深度受解析期 kMaxBlockDepth 界定。 */
std::size_t countActionRows(const std::vector<mt::MatrixObject>& seq) {
	std::size_t n = 0;
	for (const auto& m : seq) {
		if (bot::trim(m.getName()) == "Action" && m.rows() > 1) { n += m.rows() - 1; }
		n += countActionRows(m.children());
	}
	return n;
}

} // namespace

/* ---- 递归执行一段块序列（@块嵌套，2026-10-12）----
 * seq 是顶层矩阵序列、或某控制块的 children。按书写顺序遍历：
 *   - "Action" 叶子块：dispatchMatrix 直接派发；
 *   - @if(cond)：条件成立则**递归进入 m.children()**（控制块自身网格为空，
 *     体在 children 里——隐式 @Action 行run 与显式子块按书写顺序并列），
 *     不成立则 stderr 注记跳过（跳过行数 = children 里 @Action 后代的数据行合计）；
 *   - @while(cond)：每轮先查 stopRequested（Ctrl-C 及时跳出）、再判条件
 *     （成立才递归 children，故是 while 而非 do-while）、递归后回到判条件。
 *     条件每轮经 makeActionExprResolver 重求值，读得到块体内捕获格写进会话
 *     覆盖层的新值——「捕获改 @Vars → 条件转假」是收敛的 idiomatic 手段。
 *     无迭代上限（仅 Ctrl-C 终止）：静态真条件且块体不推进即热循环。
 * 返回本层是否遇到可执行块（Action/if/while）——仅顶层用于 "No @Action" 判定。 */
bool ActionRunner::execSequence(const std::vector<mt::MatrixObject>& seq) {
	bool sawActionable = false;
	for (const mt::MatrixObject& m : seq) {
		if (stopRequested()) { break; }	/* Ctrl-C：逐层及时跳出，不再进后续块 */
		const std::string name = bot::trim(m.getName());
		if (name == "Action") {
			dispatchMatrix(m);
			sawActionable = true;
			continue;
		}
		if (auto cond = parseIfBlockName(m.getName())) {
			sawActionable = true;
			if (evalIfCondition(*cond)) {
				execSequence(m.children());
			} else {
				std::cerr << "[if] condition not met: '" << echoSource(*cond)
					<< "', skipping " << countActionRows(m.children())
					<< " action row(s)" << std::endl;
			}
			continue;
		}
		if (auto cond = parseWhileBlockName(m.getName())) {
			sawActionable = true;
			std::int64_t iters = 0;
			bool stopped = false;
			for (;;) {
				if (stopRequested()) { stopped = true; break; }
				if (!evalIfCondition(*cond)) { break; }
				execSequence(m.children());
				++iters;
			}
			if (stopped) {
				std::cerr << "[while] stop requested, exiting after " << iters
					<< " iteration(s)" << std::endl;
			} else if (iters == 0) {
				std::cerr << "[while] condition not met: '" << echoSource(*cond)
					<< "', 0 iterations" << std::endl;
			} else {
				std::cerr << "[while] condition became false, exited after "
					<< iters << " iteration(s)" << std::endl;
			}
			continue;
		}
	}
	return sawActionable;
}

/* ---- @Action/@if/@while 执行入口（顶层）----
 * 递归展开见 execSequence；本函数只负责顶层 "No @Action matrix found" 判定：
 * 整棵顶层序列没有任何可执行块（Action/if/while）时，若有 @Trigger 则反射
 * 独立成立（直接返回，runReflex 接手），否则响亮报错。 */
void ActionRunner::runAction(std::vector<mt::MatrixObject>& actionMatrices) {
	bool sawActionable = execSequence(actionMatrices);
	if (!sawActionable) {
		if (mt::findByName(actionMatrices, "Trigger") != nullptr) { return; }
		throw IllegalArgumentException("No @Action matrix found in the script. Please define @Action in your .mt file.");
	}
}

/* ---- @Action 单元格解析（数值/文本求值 + 分组）----
 * resolvedDev / resolvedParam 是列头经 resolveActionDevice / resolveActionParam
 * 解析后的派发身份，set 的分组键与未起拍判定都用它们；colHeads 保留原文
 * 仅供诊断。参数值可为数值（JsonFloat）或文本（JsonString，$(...) 拼接
 * 产物）——文本参数与 SQL 元数据列同型，驱动 Lua 侧无感。 */
void ActionRunner::parseActionCell(Json& set, const mt::MatrixObject& actionDefs,
		std::int64_t i, std::int64_t j, const std::set<std::string>& phaseDevices,
		const std::string& resolvedParam,
		const std::string& resolvedDev, ColExprCache& exprCache,
		std::map<std::string, std::vector<Capture>>& captures) {
	const std::string& name_param = resolvedParam;

	/* 未起拍：本格 "-" 且无前值可继承（首数据行），且该设备属于相位设备
	 * （后续行有真实数值，典型来自 mtmerge 相位前导）。不向该设备投递该参数
	 * ——若整行都未起拍，runAction 会整体跳过它，而不是以 0.0 误发一次指令。
	 * 整列 "-" 的无参设备不属于 phaseDevices，保持旧语义照常 play。 */
	if (phaseDevices.count(resolvedDev) > 0 && actionDefs.inherited(i, j) == "-") { return; }

	/* 单元格：$(...) 表达式按求值结果（数值→JsonFloat、文本→JsonString，
	 * 拼接由 '+' 的类型分派产生）；`$var=field` 是捕获指令（不传参，记入
	 * captures，待该设备 play 后落地）；否则走既有数值/继承解析。
	 * inherited 已解析 "-" 继承（上一行是表达式/捕获时按上一行文本再处理一次）。 */
	Json paramVal;
	const std::string& raw = actionDefs.inherited(i, j);
	if (auto body = exprBody(raw)) {
		/* C-M3：AST 按列缓存——"-" 继承链上同一表达式文本原每行重解析 */
		if (exprCache.body != *body) {
			exprCache.body = *body;
			exprCache.ast = Expression::parse(*body);
		}
		ExprValue v = exprCache.ast.eval(registry_.makeActionExprResolver());
		if (v.isBool()) {
			throw IllegalArgumentException("@Action 单元格的 $(...) 不能产出布尔结果"
				"（比较/逻辑表达式属于 @if(...) 条件）；单元格接受数值或文本参数");
		}
		paramVal = v.isText() ? JsonString(v.text) : JsonFloat(v.num);
	} else if (auto cap = parseCaptureCell(raw, actionDefs(0, j))) {
		/* 捕获格：锚定本格所在列的设备（resolvedDev），不向它投递任何参数——
		 * 该设备 play 之后由 applyCapture 从返回值提取 cap.path 赋给 cap.var。 */
		captures[resolvedDev].push_back(std::move(*cap));
		return;
	} else {
		paramVal = JsonFloat(MatrixVars_Hardware::parseMtDouble(actionDefs, i, j));
	}

	/* C-M3：getPtr 就地取子对象更新字段，消除逐拍 get 拷出 + put 写回的
	 * 两次深拷贝（原 asObject() 引用临时副本会悬垂，只能整份拷贝写回） */
	Json* set_params = set.getPtr(resolvedDev);
	if (set_params == nullptr) {
		set.put(resolvedDev, JsonObject());
		set_params = set.getPtr(resolvedDev);
	}
	set_params->put(name_param, paramVal);
}


/* ---- #34 条件反射：@Trigger 逐行触发 @Reflex 动作序列 ----
 * 矩阵格式（贴 @Alias 惯例，名字只能吃到行首空白）：
 *   @Reflex                   @Trigger
 *   name  relay0.deg;         trigger;
 *   blink $(bright);          blink(bright=1);
 *   blink 0;                  blink(angle=90);
 * Reflex：列 0 = 反射名（name），列 1.. = 动作列（<设备>.<参数>）；
 * 同 name 多行 = 同一反射的多拍（按行序执行）。
 * Trigger：每行一个触发行 `reflexName(k=v, k=v)`（k = 临时变量名，
 * v = 实参文本；无括号 = 无参数触发）。
 * 执行：每次触发把该反射的行组装成动作矩阵（列头 = 动作列），实参以
 * MtVars_Alias 注册进会话覆盖层（子作用域）——动作行里的 $(k) 经
 * makeActionExprResolver 命中临时别名；dispatchMatrix 派发；无论成败
 * 撤销绑定（不污染后续触发）。无 @Trigger 时反射惰性（不执行不校验）。 */
namespace {

/* ---- runReflex 的触发行解析（2026-09-29 A3 拆出，纯函数）----
 * 解析 `reflexName(k=v, k=v)`：无括号 = 无参数触发；k=v 两侧 trim、k 须为
 * 安全标识符、重复绑定拒绝、名字为空拒绝。报错文案与行号口径逐字保持
 * （row = Trigger 矩阵数据行号）。 */
struct TriggerCall {
	std::string name;
	std::vector<std::pair<std::string, std::string>> args;
};

TriggerCall parseTriggerLine(const std::string& line, std::int64_t row) {
	TriggerCall out;
	const std::size_t lp = line.find('(');
	if (lp == std::string::npos) {
		out.name = bot::trim(line);
	} else {
		const std::size_t rp = line.rfind(')');
		if (rp == std::string::npos || rp != line.size() - 1) {
			throw IllegalArgumentException("Trigger 行（row " + std::to_string(row)
				+ "）必须以闭合 ')' 结尾：'" + line + "'");
		}
		out.name = bot::trim(line.substr(0, lp));
		std::string rest = bot::trim(line.substr(lp + 1, rp - lp - 1));
		if (!rest.empty()) {
			std::stringstream ss(rest);
			std::string seg;
			while (std::getline(ss, seg, ',')) {
				const std::string a = bot::trim(seg);
				if (a.empty()) { continue; }
				const std::size_t eq = a.find('=');
				if (eq == std::string::npos || eq == 0 || eq + 1 >= a.size()) {
					throw IllegalArgumentException("Trigger 参数（row " + std::to_string(row)
						+ "）须为 k=v 形式：'" + a + "'");
				}
				const std::string k = bot::trim(a.substr(0, eq));
				const std::string v = bot::trim(a.substr(eq + 1));
				if (!bot::isSafeIdent(k)) {
					throw IllegalArgumentException("Trigger 参数名（row " + std::to_string(row)
						+ "）不是安全标识符：'" + k + "'");
				}
				out.args.emplace_back(k, v);
			}
		}
	}
	if (out.name.empty()) {
		throw IllegalArgumentException("Trigger 行（row " + std::to_string(row)
			+ "）缺少反射名");
	}
	for (std::size_t a = 0; a < out.args.size(); ++a) {
		for (std::size_t b = a + 1; b < out.args.size(); ++b) {
			if (out.args[a].first == out.args[b].first) {
				throw IllegalArgumentException("Trigger（row " + std::to_string(row)
					+ "）重复绑定参数 '" + out.args[a].first + "'");
			}
		}
	}
	return out;
}

} // namespace

void ActionRunner::runReflex(std::vector<mt::MatrixObject>& actionMatrices) {
	const mt::MatrixObject* trig = mt::findByName(actionMatrices, "Trigger");
	if (trig == nullptr) { return; }	/* 无触发：反射惰性 */

	const mt::MatrixObject* reflexDefs = mt::findByName(actionMatrices, "Reflex");
	if (reflexDefs == nullptr) {
		throw IllegalArgumentException("@Trigger 矩阵存在但没有任何 @Reflex 定义"
			"（动作序列），请先用 @Reflex 表定义再触发");
	}
	const std::int64_t idxName = reflexDefs->requireCol(0, "name", "Reflex matrix");

	/* 反射分组（保序）：同 name 行 = 多拍 */
	std::map<std::string, std::vector<std::int64_t>> groups;
	std::vector<std::string> order;
	for (std::int64_t i = 1; i < static_cast<std::int64_t>(reflexDefs->rows()); ++i) {
		const std::string nm = bot::trim(reflexDefs->operator()(i, idxName));
		if (nm.empty()) { continue; }
		if (groups.find(nm) == groups.end()) { order.push_back(nm); }
		groups[nm].push_back(i);
	}
	if (groups.empty()) {
		throw IllegalArgumentException("@Reflex 表没有任何定义行（列 0 = 反射名）");
	}

	const std::int64_t idxTrig = trig->requireCol(0, "trigger", "Trigger matrix");
	for (std::int64_t i = 1; i < static_cast<std::int64_t>(trig->rows()); ++i) {
		const std::string line = bot::trim(trig->inherited(i, idxTrig));
		if (line.empty()) { continue; }	/* 空行跳过（宽松） */
		const TriggerCall call = parseTriggerLine(line, i);

		const auto git = groups.find(call.name);
		if (git == groups.end()) {
			std::string all;
			for (const auto& n : order) { all += (all.empty() ? "" : ", ") + n; }
			throw IllegalArgumentException("Trigger 引用了未定义的反射 '" + call.name
				+ "'（row " + std::to_string(i) + "），@Reflex 定义："
				+ (all.empty() ? "（无）" : all));
		}

		/* 组装该反射的动作矩阵（列 1.. 为动作列；组内行序 = 拍序） */
		mt::MatrixBuilder b;
		b.name("Action");
		const std::int64_t ncols = static_cast<std::int64_t>(reflexDefs->cols());
		for (std::int64_t j = 1; j < ncols; ++j) { b.item(reflexDefs->operator()(0, j)); }
		b.line(1);
		for (const std::int64_t row : git->second) {
			for (std::int64_t j = 1; j < ncols; ++j) { b.item(reflexDefs->operator()(row, j)); }
			b.line(row);
		}
		mt::MatrixObject actionDefs = b.take();

		/* 子作用域：绑定临时别名 → 执行 → 撤销（异常路径同样撤销） */
		std::vector<std::string> bound;
		try {
			for (const auto& kv : call.args) {
				registry_.override(kv.first, MtVars_Alias::Make(kv.second));
				bound.push_back(kv.first);
			}
			dispatchMatrix(actionDefs);
		} catch (...) {
			for (const auto& k : bound) { registry_.removeSessionOverride(k); }
			throw;
		}
		for (const auto& k : bound) { registry_.removeSessionOverride(k); }
	}
}

} // namespace bot
