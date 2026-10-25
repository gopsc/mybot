/* meta_provider.cpp —— MetaProvider：元数据收集（拆自 robot.cpp 阶段 P8/M2）
 * 字面列与 "-" 继承结果首采冻结，之后每次浅拷贝重放；
 * "-" 整列缺省 → 跳过（Lua 侧 tonumber(nil) or 缺省）；
 * name 列、结构引用列（controller/trigger，按保留列名识别）→ 跳过；
 * 引用列（值以 $ 前缀显式标记）→ 运行期每次实时 read() 快照，不入缓存；
 * $(...) 表达式引用 → seed 期解析/校验标识符，collect 期惰性求值。 */

#include "meta_provider.hpp"

#include "flowcolumn.hpp"

#include <memory>
#include <set>
#include <string_view>
#include <utility>

#include "debug_log.hpp"	/* logD */
#include "util_num.hpp"

namespace bot {

/* ---- seed：字面列冻结 + 引用列解析（build 前统一校验存在性）---- */
void MetaProvider::seed() {
	if (cols_) { return; }
	std::vector<std::string> cArr, vArr;
	std::vector<MetaRef> rArr;
	std::int64_t idxName = matrix_->indexOfCol(0, "name");
	for (std::int64_t j = 0; j < static_cast<std::int64_t>(matrix_->cols()); ++j) {
		const std::string& colName = (*matrix_)(0, j);
		std::string value = matrix_->inherited(row_, j);
		if (value == "-") { continue; }
		if (j == idxName || isFlowColumn(colName)) { continue; }
		if (value.rfind('$', 0) == 0) {
			if (auto body = exprBody(value)) {
				MetaRef ref;
				ref.col = colName;
				ref.expr = std::make_shared<Expression>(Expression::parse(*body));
				/* 标识符存在性：与 $name 一样在 build 前统一校验（允许前向引用） */
				std::set<std::string> names;
				ref.expr->collectVars(names);
				for (const std::string& nm : names) {
					if (!registry_->contains(nm)) {
						throw IllegalArgumentException(concatMsg("'", value,
							"' (column '", colName, "') in table '", matrix_->getName(),
							"' row ", std::to_string(row_), ": expression references '", nm,
							"', but it is not defined. ",
							"(identifiers in a $(...) expression are checked after all tables"
							" are registered and before any driver build.)"));
					}
				}
				rArr.push_back(std::move(ref));
			} else {
				std::string refName = value.substr(1);
				if (registry_->contains(refName)) {
					MetaRef ref;
					ref.col = colName;
					ref.var = refName;
					/* N-5：build 前锁定目标（seed 只在此处发生——validate() 于
					 * active() 内、全部变量注册后、任何 build/会话覆盖前调用），
					 * collect/destroy 期不再按名重查，会话别名覆盖不改变引用绑定 */
					ref.target = registry_->find(refName);
					rArr.push_back(std::move(ref));
				} else {
					throw IllegalArgumentException(concatMsg("'", value,
						"' (column '", colName, "') in table '", matrix_->getName(),
						"' row ", std::to_string(row_),
						": references hardware variable '", refName,
						"', but it is not defined. ('$' may forward-reference a variable declared later in the script, but the name must exist; checked after all tables are registered and before any driver build.)"));
				}
			}
		} else {
			cArr.push_back(colName);
			vArr.push_back(value);
		}
	}
	cols_ = std::move(cArr);
	vals_ = std::move(vArr);
	refs_ = std::move(rArr);
}

/* C1 防线：$ 引用列经 read() → getMetadata_() → collect() 互递归取实时快照，
 * 环配置（如 A.src=$B 且 B.src=$A，或自引用）会无限递归直到栈溢出。
 * 用线程局部深度计数兜底：正常引用链深度 1，超限即判定为环并清晰报错。
 * N-15：RAII 计数收敛为 util 的 RecursionGuard；重构计划 1-B2 把「超限
 * 检查 + 计数」合一为 DepthLimitGuard（destroy 收集只计数不设限，见下）。 */
namespace {
thread_local int t_refDepth = 0;
constexpr int kMaxRefDepth = 32;
} // namespace

Json MetaProvider::staticPart() {
	seed();
	Json obj = JsonObject();
	auto& colsArr = *cols_;
	auto& valsArr = *vals_;
	for (std::size_t k = 0; k < colsArr.size(); ++k) {
		obj.put(colsArr[k], JsonString(valsArr[k]));
	}
	return obj;
}

Json MetaProvider::collect() {
	return collectRefs(/*forDestroy=*/false);
}

/* N-16：collect 与 collectForDestroy 的公共内核（此前是 ~60 行双胞胎，
 * N-5 锁定指针等语义改动要改两处、靠评审对齐——现在只有一个实现）。
 * forDestroy 差异点：错误不再上抛（destroy 是清理路径，逐引用尽力而为）：
 * 表达式求值失败 / read 失败 / 非对象快照 → logD 跳过该列；ERR 快照跳过。 */
Json MetaProvider::collectRefs(bool forDestroy) {
	if (forDestroy) {
		/* F-04′：destroy 阶段的元数据收集——字面列 + 引用列的「尽力而为」快照。
		 *
		 * 为什么不能只取字面列（F-04 的原实现 collectStatic）：总线句柄 fd 与从机
		 * address 都不是字面列，而是器件行经 `$i2c-N` / `$uart-N` 从接口器件的快照
		 * 来的（modules/I2C.lua 的 call 下发 fd）。modules/lib/drv_common.lua 的
		 * i2c_pair 要用它们，于是丢字段的后果按驱动分两档：
		 *   * 走 i2c_pair 的 PCA9685 / MPU6050 / BH1750 —— destroy 响亮报错
		 *     （Deactive warning: ... Invalid Argument: fd or address）；
		 *   * 走 `if fd ~= nil ...` 守卫的 ADS1015 / ADS1115 / ADS1256 / APDS9900 /
		 *     BME280 / BME688 / MAX30102 / MCP3421 / SGP30 / VL53L0X / VL53L4CD /
		 *     SCSCL —— 静默跳过整个去初始化，器件滞留在最后指令状态且一声不响。
		 *
		 * 为什么可以放心解析引用：接口器件（I2C/SPI/UART）的 fd 只由它自己的 destroy
		 * 关闭，而「总线必须先于器件声明」在 build 期就被强制了——器件 build 要用 fd，
		 * 就必须让总线先 build（总线前向引用在 build 期即失败，见 ref_bus_forward 用例）。
		 * 于是倒序销毁天然保证总线最后关闭，器件 destroy 期间 fd 始终有效。
		 *
		 * 与 F-04 的原始诉求不冲突：要守的是「destroy 这个调用绝不被跳过」，不是
		 * 「不许解析引用」。这里对每个引用**单独** try——抛错（引用已被销毁）只跳过
		 * 该引用本身。会被跳过的只可能是「数据前向引用」链（如 Monitor→Ema→Daemon，
		 * 引用者在倒序里反而最后销毁），而 v0/out/count 这类字段本就不是器件去初始化
		 * 所需。ERR 快照同理跳过（守护槽已移交时 readSample 按 ERR 契约返回对象而非抛错，
		 * 把 message 混进去初始化参数没有意义）。 */
	}
	/* C1 防线：$ 引用列经 read() → getMetadata_() → collect() 互递归取实时
	 * 快照，环配置（如 A.src=$B 且 B.src=$A，或自引用）会无限递归直到栈
	 * 溢出——深度计数兜底，超限判环并清晰报错。（destroy 期不递归进入
	 * 本函数，被引用方的 collect 自带同一防线。）destroy 收集（forDestroy）
	 * 自身不设限只计数：它嵌套触发被引用方的非销毁收集，外层深度正是
	 * 内层超限判定的输入，故 limit 传 nullptr。 */
	DepthLimitGuard depthGuard(t_refDepth, forDestroy ? nullptr : &kMaxRefDepth,
		[&] {
			return "circular '$' reference detected: reference chain exceeds "
				+ std::to_string(kMaxRefDepth) + " levels while resolving table '" + matrix_->getName()
				+ "' row " + std::to_string(row_)
				+ ". Check that '$' reference columns do not form a cycle (a variable referencing itself, directly or indirectly).";
		});

	Json obj = staticPart();
	for (const MetaRef& ref : *refs_) {
		appendRef(obj, ref, forDestroy);
	}
	return obj;
}

/* ---- destroy 收集的「尽力而为」跳过日志——4 段同模板 logD 收敛单点 ---- */
void MetaProvider::logDestroySkip(const std::string& what, const std::string& why) {
	logD([&] {
		return "destroy metadata: '" + matrix_->getName() + "' row " + std::to_string(row_)
			+ " skipped " + what + " (" + why + ")";
	});
}

/* ---- 单个引用列的快照并入（阶段 3 拆分）----
 * 返回 false = destroy 收集跳过该引用（尽力而为，仅销毁路径）；
 * 非销毁路径的失败按 halt-on-error 直接抛。 */
bool MetaProvider::appendRef(Json& obj, const MetaRef& ref, bool forDestroy) {
	if (ref.expr) {
		/* $(...) 表达式：把求值结果格式化后写回承载 $ 的列。
		 * 表达式只引用 @Vars（无资源），destroy 期照常求值。
		 * 元数据列只收数值（拼接是 @Action 求值面的能力），requireNum 显式
		 * 拒绝文本结果。 */
		try {
			double v = requireNum(
				ref.expr->eval(numericResolver(registry_->makeVarsResolver())));
			obj.put(ref.col, JsonString(formatNumber(v)));
		} catch (const std::exception& e) {
			if (!forDestroy) { throw; }
			logDestroySkip("expression column '" + ref.col + "'", e.what());
			return false;
		}
		return true;
	}
	const std::string& colName = ref.col;
	const std::string& name = ref.var;
	/* N-5：seed 期锁定的目标指针——collect/destroy 期都不按名重查，
	 * 会话别名覆盖不影响引用绑定（含销毁期快照归属） */
	MatrixVars_Hardware* hv = ref.target;
	if (hv == nullptr) { return true; }
	Json snap;
	try {
		snap = hv->read();
	} catch (const std::exception& e) {
		if (!forDestroy) { throw; }
		logDestroySkip("$" + name, std::string("already released: ") + e.what());
		return false;
	}
	if (snap.isStr() && std::string_view(hv->kindName()) == "vars") {
		/* @Vars 数值常量：把值写回承载 $ 的列（如 Servo 的 max 列写 $smax） */
		obj.put(colName, snap);
		return true;
	}
	if (!snap.isObj()) {
		if (!forDestroy) {
			throw IllegalArgumentException("'$" + name
				+ "': referenced variable returned a non-object (scalar) snapshot; "
				+ "the '$' reference column '" + colName
				+ "' merges field snapshots (v0.., status, count). Only @Vars entries"
				+ " carry a numeric value that can fill a column; Alias/scalar variables are"
				+ " only supported via 'controller' columns.");
		}
		logDestroySkip("$" + name, "non-object snapshot");
		return false;
	}
	if (forDestroy) {
		auto rs = snap.get("result");
		if (rs && rs->isStr() && rs->asString().getValue() == "ERR") {
			logDestroySkip("$" + name, "reference reported ERR");
			return false;
		}
	}
	/* 正常路径下 ERR 快照**仍按普通字段合并**（不做上抛）：被引用方报 ERR
	 * 有其合法成因——守护尚未出首帧（"no sample yet"）、$ 前向引用的对象
	 * 此刻还没 build 起来（ref_forward 用例）——这些是瞬时状态，消费方
	 * （如 Monitor）自带缺字段守卫。**永久性**失败（守护 setup 失败）由
	 * 被引用方直接抛异常上达（见 daemonvar.cpp readSample），不靠这里甄别。 */
	jsonMergeInto(obj, snap.asObject());
	return true;
}

Json MetaProvider::collectForDestroy() {
	return collectRefs(/*forDestroy=*/true);
}

} // namespace bot
