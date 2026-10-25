#pragma once
/* action_runner.hpp —— @Action 派发计划与逐行重放（拆自 robot.hpp，2026-09-29 A2；
 * 实现在 action_runner.cpp） */

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "expr.hpp"
#include "hardware.hpp"
#include "hw_registry.hpp"
#include "json.hpp"
#include "matrix.hpp"

namespace bot {

/* ---- @Action 单元格捕获指令（.mt 数据格 `$var=field.path`）----
 * 把「本格所在列设备」本帧 play 返回值里的某个字段，赋给 @Vars/@Alias 变量。
 * 捕获格**不向设备传参**（列头 param 位对此格无意义），只在该设备 play 之后
 * 落地赋值：var = 目标变量名（安全标识符）；path = 点号分隔的字段路径；
 * colHead = 原始列头文本，仅供报错归因。 */
struct Capture {
	std::string var;
	std::string path;
	std::string colHead;
};

/* ---- @Action 派发计划（拆自 runAction 的纯计算前段）----
 * 列头只解析一次（C-M3）：原实现在 order/相位检测/每行每格三处
 * 重复做 <device>.<param> 切分（切分规则单点在 mt::splitActionColumn）。
 * 设备列解析（resolveActionDevice）与参数位解析（resolveActionParam）：
 * 解析后的名字是派发身份——分组、顺序、相位、查重全部按解析名；
 * colHeads 保留原文供报错归因。
 * build 是纯计算（只读注册表，不碰硬件、不派发），可白盒单测。 */
struct ActionPlan {
	std::vector<std::pair<std::string, std::string>> colHeads;	/* 原始列头 <device>.<param> */
	std::vector<std::string> devs;	/* 解析后设备名（派发身份） */
	std::vector<std::string> params;	/* 解析后参数名 */
	std::vector<std::string> order;	/* 设备首现顺序（派发序） */
	/* 解析名查重（撞设备第二层防线）：归并期 checkDisjoint 只见列头文本，
	 * 不同别名/表达式指到同一 (设备, 参数) 只有这里可见。键 = 解析后的
	 * (设备, 参数)——同设备不同参数是合法的一拍多参（合并进同一次 play）；
	 * 同键重复则逐行静默覆盖（含 "-" 继承把两条时间线写进同一键），必须
	 * 显式报错。 */
	std::map<std::pair<std::string, std::string>, std::string> seenCell;
	/* 相位设备：该设备的参数列里存在真实数值行（典型来自 mtmerge 相位归并，
	 * 前导行是无可继承的 "-"、后续行有数值）。只有这类设备做未起拍跳过；
	 * 整列 "-" 的无参设备（旧式写法）保持旧行为——靠 0.0 照常 play，
	 * 否则依赖 play 触发读数/副作用的所有 E2E（守护快照等）会整体失效。 */
	std::set<std::string> phaseDevices;

	static ActionPlan build(const HwLookup& registry, const mt::MatrixObject& defs);
};

/* ---- 动作重放：@Action 逐行 play（R-1 拆自 RobotStruct）---- */
class ActionRunner {
	HwRegistry& registry_;

	/* C-M3：$(...) 表达式 AST 按列缓存——"-" 继承链上同一表达式文本
	 * 原实现每行每格重解析一次（O(行数²) 字符扫描）。body 为上次解析的
	 * 表达式文本，不同则重解析（继承传播的是同一文本，命中即 O(1)）。 */
	struct ColExprCache {
		std::string body;
		Expression ast;
	};

	/* N-10：按名查矩阵与列头切分下沉 mt 层（findByName / splitActionColumn） */
	void parseActionCell(Json& set, const mt::MatrixObject& actionDefs,
			std::int64_t i, std::int64_t j, const std::set<std::string>& phaseDevices,
			const std::string& resolvedParam,
			const std::string& resolvedDev, ColExprCache& exprCache,
			std::map<std::string, std::vector<Capture>>& captures);

	/* ---- 捕获赋值（play 之后落地）----
	 * applyCapture：从返回值 res 按 cap.path（点号路径）取字段，赋给 cap.var。
	 * 目标已存在按其种类校验（@Vars 收数值 / @Alias 收文本 / 非标量拒绝）；
	 * 未声明则按字段类型自动新建（数值→@Vars、文本→@Alias，其余拒绝）。
	 * 赋值经 registry_.override 写进会话覆盖层（遮蔽同名结构定义，run() 结束
	 * 回滚）；被引用为 controller/trigger 的名字由 override 拒绝（安全不变式）。 */
	void applyCapture(const Json& res, const Capture& cap, std::int64_t row);

public:
	explicit ActionRunner(HwRegistry& registry) : registry_(registry) {}

	/* ---- @Action 设备列解析单点（公开静态：白盒单测直接锚定）----
	 * 设备位允许写 @Alias（2026-09-19 设计评估）：解析穿透——别名不是播放
	 * 目标而是名字绑定，read() 出目标名后必须命中**非标量**硬件变量
	 * （驱动/守护），一层为止（别名指向别名报错）。未知名字原样返回：派发期
	 * 按既有「not defined (row N)」报错，保留行号上下文。@Vars 是数值常量，
	 * 永远不可能合法命名设备，显式拒绝而非落到 not defined。
	 * 设备位也接受 $(...) 表达式（2026-09-20 设计评估）：求值产物作为设备名
	 * 候选，走与裸名完全相同的解析——命中别名再解一层（$(p) ≡ p），产物
	 * 本身不再递归求值（别名值即使形如 "$(…)" 也只按文本查找，环无从建立）。
	 * 求值在派发期：主从覆盖改绑后的真值在此生效。
	 * 撞设备两层防线：归并期 checkDisjoint 按列头文本（同名在两个输入里都
	 * 出现），不同别名/表达式指到同一设备只有派发期可见——runAction 在解析
	 * 后按 (设备, 参数) 查重，是第二层的落点。 */
	static std::string resolveActionDevice(const HwLookup& registry, const std::string& dev);

	/* ---- @Action 参数位解析单点（公开静态：白盒单测直接锚定）----
	 * 参数位允许写 @Alias/@Vars 名（既有语义：命中标量文本即以其值为参数名）
	 * 与 $(...) 表达式（2026-09-20 设计评估）：求值产物即参数名，**不再解析**
	 * （参数名不是名字绑定）。派发期内别名/变量不变，每列解析一次。 */
	static std::string resolveActionParam(const HwLookup& registry, const std::string& param);

	/* ---- @if(条件) 块头解析单点（公开静态：白盒单测直接锚定）----
	 * 块名形态（MatrixParser 的名字态把整串收进 name，括号是普通字符）：
	 *   "if(cond)" → cond（trim 后）；"if" 裸名 / "if(" 未闭合 / 条件为空
	 *   → IllegalArgumentException（意图明显的坏形态响亮救红，不静默当
	 *   未知块透传——透传即永不执行，等于把条件块静默丢弃）；
	 *   其余（含 "ifx(a)" 这类前缀不同名）→ nullopt（不是 if 块）。
	 * 块头内不能有空格（与 $(...) 同约束：MatrixParser 名字态遇空白即止，
	 * "@if(a > b)" 会被切成名字 "if(a" + 数据行）——报错文案要带此提示。 */
	static std::optional<std::string> parseIfBlockName(const std::string& rawName);

	/* ---- @while(条件) 块头解析单点（公开静态：白盒单测直接锚定）----
	 * 与 parseIfBlockName 同型的「关键字 + 括号条件」文本协议，关键字换成
	 * "while"：命中返回 trim 后的条件体；裸 "while" / 未闭合 / 条件为空 →
	 * IllegalArgumentException（响亮救红）；其余（含 "whilex(a)"）→ nullopt。
	 * 两者共用一个文件内 helper（parseCondBlockName），报错文案按关键字参数化，
	 * "if" 分支逐字复现既有 @if 文案（白盒单测锚定的子串不变）。 */
	static std::optional<std::string> parseWhileBlockName(const std::string& rawName);

	/* ---- @Action 数据格捕获形态解析单点（公开静态：白盒单测直接锚定）----
	 * 输入是一个数据格原文（已解析 "-" 继承）：
	 *   非 '$' 开头 / "$(" 开头（表达式）→ nullopt（不是捕获，交回既有路径）；
	 *   其余 "$..." → 必须是 `$<var>=<field.path>`，解析成 Capture 返回。
	 * 坏形态响亮报错（IllegalArgumentException）：缺 '='、var 为空或非安全
	 * 标识符、path 为空或含空段。var/path 两侧不做 trim（矩阵按空白切格，
	 * 数据格内本就无空白）。 */
	static std::optional<Capture> parseCaptureCell(const std::string& raw,
			const std::string& colHead);

	/* 单矩阵动作派发核心：@Action 与 #34 @Reflex 共用同一派发逻辑 */
	void dispatchMatrix(const mt::MatrixObject& actionDefs);

	/* 递归执行一段块序列（顶层序列，或某控制块的 children）：按书写顺序，
	 * "Action" 叶子块直接 dispatchMatrix；@if/@while 控制块求值后**递归进入其
	 * children**（2026-10-12 @块嵌套：控制块自身网格为空，体在 children 里）。
	 * 每块前查 stopRequested（Ctrl-C 逐层及时跳出）。返回值 = 本层是否遇到可执行
	 * 块（Action/if/while）——仅顶层 runAction 用于 "No @Action" 判定。 */
	bool execSequence(const std::vector<mt::MatrixObject>& seq);

	/* @if(...) 条件求值（块级，轮到该块执行时）：复用 makeActionExprResolver
	 * （标识符只认 @Vars 数值/@Alias 文本——条件引用实时传感器值走「守护
	 * 采样 + 消费驱动」的既定链路，不在表达式面开取数通道）。结果必须是
	 * Bool：数值/文本条件（如 @if(threshold)）不是「非零即真」——类型
	 * 严格，显式比较（threshold>0）才可判定。 */
	bool evalIfCondition(const std::string& cond) const;

	/* @Action/@if 逐行重放（play 直通事件发生器；ERR 即 halt-on-error）：
	 * 顶层矩阵序列按**书写顺序**交错执行——"Action" 名块与 "if(...)" 名块
	 * 轮到谁派发谁（展开层把合并 @Action 锚在主脚本首个 @Action 的书写
	 * 位置，见 mtinclude）；if 条件不成立跳过该块（stderr 注记）并继续。 */
	void runAction(std::vector<mt::MatrixObject>& actionMatrices);

	/* #34 条件反射：@Trigger 逐行触发 @Reflex 动作序列，触发参数以临时
	 * 会话 @Alias 绑定（子作用域，执行完逐个撤销）；无 @Trigger 时反射
	 * 定义惰性存在（不执行、不校验引用）。 */
	void runReflex(std::vector<mt::MatrixObject>& actionMatrices);
};

} // namespace bot
