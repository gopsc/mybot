#pragma once
/* matrix.hpp —— 矩阵式解析器（移植 mt2：MatrixObject / MatrixParser / MatrixSaver）
 * @ 开块、; 行尾、# 注释、空格/制表符分隔项、- 占位符由上层解析
 */

#include <cstdint>
#include <optional>
#include <ostream>
#include <string>
#include <vector>

#include "util_except.hpp"
#include "util_str.hpp"

namespace mt {

/* @块嵌套深度上限（2026-10-12 @块嵌套）：控制块（@if/@while）可含子块、子块可
 * 再含——深度无界会让解析器帧栈与执行器 execSequence 的调用栈随嵌套线性增长。
 * --tcp 下发的远端脚本能构造深嵌套，故设硬上限、超限在解析期响亮拒绝（与
 * @Merge/@Include 的 kMaxIncludes=32、表达式深度上限同一护栏取向）。32 层远超真实脚本
 * 所需；Stage 1 先立常量，判据在 Stage 2 解析器落地。 */
inline constexpr std::size_t kMaxBlockDepth = 32;

/* 重构计划 2.5：单一根异常——解析家族并入 bot::IllegalArgumentException。
 * 此前上层要「域错误全捕」必须双 catch（本族 + IAE）；归一后 catch(IAE)
 * 一处即可。matrix.cpp 的两段 catch 语义不变：本族原样上抛（自带行号）、
 * 其余 IAE 带行号包装——派生在前、基类在后，次序即语义。 */
class MatrixParseExcept : public bot::IllegalArgumentException {
public:
	explicit MatrixParseExcept(const std::string& m) : bot::IllegalArgumentException(m) {}
};

class DoesNotSync : public MatrixParseExcept {
public:
	DoesNotSync(std::int64_t line, std::size_t expected, std::size_t got)
		: MatrixParseExcept("Matrix Line Does Not Sync. we got line: " + std::to_string(line)
			+ ": this row has " + std::to_string(got) + " cell(s), but the row above has "
			+ std::to_string(expected) + " (every row must match the header column count)") {}
};

/* ------------- 矩阵对象 ------------- */
class MatrixObject {
	friend class MatrixBuilder;

	std::string name_;
	std::vector<std::vector<std::string>> values_;	/* 原始矩阵 */

	/* 嵌套子块（2026-10-12 @块嵌套）：仅控制块（@if/@while）使用——其体内的
	 * 连续直接行合成为隐式 @Action 子块、显式 @名字 子块按书写顺序并入此列。
	 * 叶子块（@Action/@Alias/@Vars…）恒为空。std::vector 支持不完整值类型
	 * （C++17），故可作 MatrixObject 自身的成员。Stage 1 惰性加入：解析器尚未
	 * 填充，行为零变化；填充与消费见 Stage 2/3。 */
	std::vector<MatrixObject> children_;

	/* "-" 占位符继承的解析结果，惰性前向填充（见 inherited()）。
	 * 按值存储而非存指针：MatrixObject 是可拷贝值类型（parse/take 均按值
	 * 交付），指向 values_ 内部字符串的指针在副本里会悬垂。 */
	mutable std::vector<std::string> inherited_;
	mutable bool inheritedReady_ = false;

	/* 冷路径实现下放 matrix.cpp（2026-10-01 编译扇出收窄：本头被 11 个 TU
	 * 包含，大段 inline 只在各 TU 里膨胀二进制与编译时间）——operator()/
	 * inherited/indexOfCol 是逐格热路径，留 inline。 */
	void buildInherited() const;

public:
	bool hasName() const { return !name_.empty(); }
	const std::string& getName() const { return name_; }

	/* 嵌套子块只读视图（仅控制块 @if/@while 非空；叶子块恒空）。执行器
	 * execSequence 递归消费（Stage 3）；Stage 1 惰性加入，尚无填充方。 */
	const std::vector<MatrixObject>& children() const { return children_; }
	/* 可变视图：@Merge 展开的嵌套归并 pass 需就地重写 children 序列
	 * （消费子块内的 @Merge 块、把目标纯矩阵并入其下紧邻的表）。 */
	std::vector<MatrixObject>& children() { return children_; }
	bool hasChildren() const { return !children_.empty(); }

	std::size_t rows() const { return values_.size(); }
	std::size_t cols() const {
		return rows() > 0 ? values_[0].size() : 0;
	}

	/* 取矩阵元素，只能取，不能修改 */
	const std::string& operator()(std::size_t row, std::size_t col) const {
		if (row >= values_.size() || col >= values_[row].size()) {
			throw bot::IllegalArgumentException(
				"Matrix access out of bounds: row=" + std::to_string(row) + " col=" + std::to_string(col));
		}
		return values_[row][col];
	}

	/* C5 防线：int64 下标判负——indexOfCol 未命中返回 -1，若隐式转 size_t
	 * 会回绕成 18446744073709551615，报错毫无指向性（缺 name 列的典型路径）。 */
	const std::string& operator()(std::int64_t row, std::int64_t col) const {
		if (row < 0 || col < 0) {
			throw bot::IllegalArgumentException(
				"Matrix access with negative index: row=" + std::to_string(row) + " col=" + std::to_string(col)
				+ " (a header column such as 'name' is likely missing)");
		}
		return (*this)(static_cast<std::size_t>(row), static_cast<std::size_t>(col));
	}

	/* 取 "-" 占位符解析后的值（首次访问触发一次前向填充，之后 O(1)）。
	 * 取代旧的逐格递归回溯：那既是 O(n²)，递归深度又随行数增长。 */
	const std::string& inherited(std::size_t row, std::size_t col) const {
		if (!inheritedReady_) { buildInherited(); }
		const std::size_t ncol = cols();
		if (row >= values_.size() || col >= ncol) {
			throw bot::IllegalArgumentException(
				"Matrix access out of bounds: row=" + std::to_string(row) + " col=" + std::to_string(col));
		}
		return inherited_[row * ncol + col];
	}

	const std::string& inherited(std::int64_t row, std::int64_t col) const {
		if (row < 0 || col < 0) {
			throw bot::IllegalArgumentException(
				"Matrix access with negative index: row=" + std::to_string(row) + " col=" + std::to_string(col)
				+ " (a header column such as 'name' is likely missing)");
		}
		return inherited(static_cast<std::size_t>(row), static_cast<std::size_t>(col));
	}

	/* 在某一行的列头中寻找 key 的列号 */
	std::int64_t indexOfCol(std::size_t row, const std::string& key) const {
		if (row >= values_.size()) { return -1; }
		const auto& line = values_[row];
		for (std::size_t col = 0; col < line.size(); ++col) {
			if (line[col] == key) { return static_cast<std::int64_t>(col); }
		}
		return -1;
	}

	/* 定位必须存在的列头，未命中就地抛。what 是文案主语（「Alias matrix」/
	 * 「Vars matrix」/「Table」），报文模板
	 * "{what} '{表名}' has no '{key}' column."——各调用点既有文案逐字保持。
	 * 与 C5 负下标防线的关系：那是漏网负下标的兜底（报错发生在访问点），
	 * 本方法把「缺列」的判定提到定位点、报错主语带表名，指向性更强。
	 * 容许缺列的场景（如把 name 列当跳过标记的元数据收集）仍用 indexOfCol。 */
	std::int64_t requireCol(std::size_t row, const std::string& key,
			const std::string& what) const;

	/* 储存对象 */
	void save(std::ostream& out) const;

	/* 解析期追加一行（R-4）：宽度一致性校验 + 继承缓存作废。
	 * 头行与 INSERT 行都经此入口，保证校验只此一处。 */
	void appendRow(std::vector<std::string> row, std::int64_t count);

	/* 丢弃尾部 count 行（2026-09-23 热插表）：**只给回滚路径用**。
	 * 结构表在装配期是只增的（顺序不变式见 RobotStruct::applySql），
	 * 唯一的删除需求是「热插批次失败 ⇒ 撤销刚追加的 INSERT 行」。
	 * count 超出行数即调用方算错（回滚记录与提交记录不匹配），响亮报错。 */
	void popRows(std::size_t count);

	/* 按行号删除任意行（2026-09-23 热删除）：**存活行相对顺序逐字不变**。
	 * 这不是实现细节而是不变式——行序就是声明序，而销毁序 = 声明序倒序
	 * （总线必须晚于挂在它上面的器件关闭 fd，见 RobotStruct::deactivate
	 * 的注释）。交换式删除（把尾行填进空位）会让存活器件的相对次序漂移，
	 * 于是「删一个中间器件」就能把整条拓扑序打乱，且症状是销毁期才显形的
	 * 资源错序——故这里一律 erase，认下 O(n) 搬移（结构表是百行级）。
	 *
	 * 行 0 是列头，不得删除（删掉列头会让所有列名定位失效）；重复行号与
	 * 越界同样报错——两者都是调用方算错，静默容忍只会让「删了几行」与
	 * 生效摘要对不上。删除在单趟内完成（按行号集合过滤一次重排），故传入
	 * 的行号无需有序、也无需倒序，调用方不必替本方法做排序。 */
	void removeRows(const std::vector<std::size_t>& rows);
};

/* ------------- 解析期增量构建器（R-4）-------------
 * 字符缓冲 + 整行缓冲是解析器状态机的专属物，此前挂在 MatrixObject
 * 上让它同时是「构建器」与「只读值」；拆开后 MatrixObject 只有
 * appendRow 一个收窄的写入口（SQL INSERT 追加行用）。 */
class MatrixBuilder {
	std::string tmp_;				/* 字符缓冲区 */
	std::vector<std::string> grp_;			/* 整行缓冲区 */
	MatrixObject obj_;

public:
	bool hasName() const { return obj_.hasName(); }

	void addRune(char c) { tmp_ += c; }

	void submitName() {
		if (tmp_.empty()) { return; }
		obj_.name_ = tmp_;
		tmp_.clear();
	}

	void submitItem() {
		if (tmp_.empty()) { return; }
		grp_.push_back(tmp_);
		tmp_.clear();
	}

	void submitLine(std::int64_t count) {
		if (grp_.empty()) { return; }
		obj_.appendRow(std::move(grp_), count);
		grp_.clear();
	}

	/* 整串直灌入口（SQL 事件路径：token 本就完整，无需逐字符） */
	void name(const std::string& n) { obj_.name_ = n; }
	void item(const std::string& s) { grp_.push_back(s); }
	void line(std::int64_t count) { submitLine(count); }

	/* 追加一个嵌套子块（Stage 2 解析器用：控制块体内合成的隐式 @Action 与
	 * 显式子块按书写顺序入列）。Stage 1 惰性加入，尚无调用方。 */
	void addChild(MatrixObject child) { obj_.children_.push_back(std::move(child)); }

	MatrixObject take() { return std::move(obj_); }
};

/* ------------- 矩阵式解析器 -------------
 * 2026-10-12 @块嵌套：从「单块 + flag_」升级为帧栈。行首 '@' 后读完名字 token
 * 再决策（Reader 无 peek）：空名（裸 @）= 闭合最内层帧；if(/while( = 开控制帧；
 * 其余 = 开叶子帧。控制帧体内连续直接行合成一个隐式 @Action 子块，遇 @名字 先
 * 冲刷再开子块——直接行与嵌套块按书写顺序交错入 children。叶子帧只吃行、不可含
 * 子块。裸 @ 闭合最内层对非嵌套脚本语义逐字不变（向后兼容）。 */

/* 控制块名判定（宽松形态，下沉 matrix 层供解析器与 mtinclude 共用，避免与
 * action_runner 的精确版 parseIfBlockName/parseWhileBlockName 漂移，也不让
 * matrix 反向依赖 action_runner）。凡「看起来想写 @if/@while」的都算控制块
 * （含裸 "if"/"while" 与未闭合等非法形态）——它们进控制帧，精确校验与响亮
 * 报错仍在执行期由 ActionRunner 的 parseCondBlockName 兜（报错文案不变）。 */
inline bool isControlBlockName(const std::string& rawName) {
	const std::string n = bot::trim(rawName);
	return n == "if" || n.compare(0, 3, "if(") == 0
		|| n == "while" || n.compare(0, 6, "while(") == 0;
}

class MatrixParser {
	bot::Reader& input_;

	/* 一个开着的块帧。叶子帧只用 self（网格）；控制帧用 children + pendingAction
	 * （当前隐式 @Action 行run），self 不用。 */
	struct Frame {
		std::string name;		/* 块名（"Action" / "if(x>0)" / "while(c<3)"） */
		bool isControl = false;
		MatrixBuilder self;		/* 叶子：网格（名字已置） */
		std::vector<MatrixObject> children;	/* 控制：按书写顺序的子块 */
		MatrixBuilder pendingAction;	/* 控制：当前隐式 @Action（名字已置 "Action"） */
		bool pendingHasRows = false;
	};
	std::vector<Frame> stack_;
	MatrixBuilder scratch_;		/* 栈空时的顶层游离数据（永不具名 → parse 返 nullopt，与旧行为一致） */
	std::string hdr_;		/* 行首 '@' 后正在读的块头名字 token */
	bool done_ = false;		/* 顶层帧已闭合，parse() 该返回 */
	std::optional<MatrixObject> result_;

	bool nl_ = true;	/* new line（行首态） */
	bool cm_ = false;	/* comment */
	bool nm_ = false;	/* 正在读块头名字 token */

	/* 当前接收数据行的构建器：控制帧 → pendingAction，叶子帧 → self，栈空 → scratch_ */
	MatrixBuilder& dataBuilder();
	void commitHeader(const std::string& hdr);	/* 块头名字读完：开块或闭合 */
	void flushPending(Frame& f);			/* 控制帧：把当前行run冲刷成隐式 @Action 子块 */
	void closeFrame();				/* 闭合最内层帧，产物挂到父帧或成为 parse 结果 */

	std::int64_t next_(char c, std::int64_t count);

public:
	explicit MatrixParser(bot::Reader& input) : input_(input) {}

	std::optional<MatrixObject> parse();
};

/* ------------- 共享查询与切分（N-10：单一事实源）-------------
 * 此前「按名查矩阵」在 ActionRunner/mtmerge/readSQL 各有一份、「列头切分」
 * 在 ActionRunner/mtmerge 各有一份，规则靠注释人工同步——mtmerge 产物一旦
 * 与运行端解释漂移，合成的脚本会被以不同方式解读。 */

/* 按矩阵名查找（trim 后比较）；不存在返回 nullptr。
 * 容器类型模板化（2026-09-23 热插表）：结构期矩阵表由 RobotStruct 以
 * std::deque 持有（两端插入不失效元素引用，MetaProvider 的 matrix_ 引用于是
 * 在热插入下仍有效），而 mtmerge/mtinclude/动作脚本路径仍用 std::vector——
 * 查找规则只此一处，不因容器而分叉。实参为 const 左值时由偏序规则选中
 * const 重载（`const C&` 比 `C&` 更特化），返回值随之带 const。 */
template <class Container>
inline const MatrixObject* findByName(const Container& ll, const std::string& name) {
	for (const auto& m : ll) {
		if (bot::trim(m.getName()) == name) { return &m; }
	}
	return nullptr;
}

template <class Container>
inline MatrixObject* findByName(Container& ll, const std::string& name) {
	for (auto& m : ll) {
		if (bot::trim(m.getName()) == name) { return &m; }
	}
	return nullptr;
}

/* WHERE 等值匹配单点（2026-09-23）：列头定位 + inherited 精确文本比较，返回
 * 命中数据行号（不含行 0 列头）。与 SELECT 渲染同源——比对 inherited（"-"
 * 占位继承解析后的显示值），查询结果与全列渲染看到的是同一份值。参数用基本
 * 类型而非 WhereEqual/WhereClause，避免 mt 层反向依赖 sqlparse 层。
 * matchRows = 单条件；matchAll = 多条件 AND（热删除用），后者按前者语义逐个
 * 收窄——两个入口一份判据，不各写一遍比较。 */
std::vector<std::size_t> matchRows(const MatrixObject& m, const std::string& col,
		const std::string& val);

/* 多条件 AND 匹配（2026-09-23 热删除）：返回**同时**满足全部 (列,值) 的数据
 * 行号（不含行 0）。空条件表返回全部数据行（= 无条件，`DELETE FROM t;`）。
 * 任一列不存在即按 requireCol 既有文案上抛（与单条件同口径，报错点名列名）。
 * 命中行号按行号升序（调用方若按行号倒序删除，天然无需再做排序）。 */
std::vector<std::size_t> matchAll(const MatrixObject& m,
		const std::vector<std::pair<std::string, std::string>>& conds);

/* @Action 列头解析：<device>.<param>（恰好一个点）。ActionRunner 派发与
 * mtmerge 相位归并共用同一切分规则与报错文案。 */
inline std::pair<std::string, std::string> splitActionColumn(const std::string& name_HV) {
	std::size_t dot = name_HV.find('.');
	if (dot == std::string::npos || name_HV.find('.', dot + 1) != std::string::npos) {
		throw bot::IllegalArgumentException("Action column '" + name_HV
			+ "' is not valid (expected format: <device>.<param>)");
	}
	return { name_HV.substr(0, dot), name_HV.substr(dot + 1) };
}

/* 读取矩阵式外表（@Action/@Alias/@Vars…）到 out：自省结局，不破坏读缓存。
 * 原 ScriptLoader::readMatrix——mtmerge 只需这一层，放回 matrix 后
 * mtmerge 不再链接 robot/LuaJIT（N-11）。 */
void readMatrix(bot::Reader& file, std::vector<MatrixObject>& out);

/* ------------- 矩阵式储存器 ------------- */
class MatrixSaver {
public:
	static void save(const std::vector<MatrixObject>& objects, std::ostream& out) {
		for (const auto& item : objects) {
			item.save(out);
			out << "\n";	/* 对象之间空一行 */
			out.flush();
		}
	}
};

} // namespace mt