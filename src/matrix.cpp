#include "matrix.hpp"

namespace mt {

/* ------------- MatrixObject 冷路径方法（2026-10-01 自 matrix.hpp 下放）-------------
 * 本头被 11 个 TU 包含，大段 inline 只在各 TU 里膨胀二进制与编译时间；
 * 这些方法（惰性继承填充/列定位/存盘/增删行）都是解析期或生命周期级调用，
 * 不在逐格热路径上——热路径 operator()/inherited/indexOfCol 留在头内 inline。
 * 实现与下放前逐字一致。 */

void MatrixObject::buildInherited() const {
	inherited_.clear();
	inheritedReady_ = false;
	const std::size_t nrow = values_.size();
	const std::size_t ncol = cols();
	inherited_.reserve(nrow * ncol);
	for (std::size_t r = 0; r < nrow; ++r) {
		for (std::size_t c = 0; c < ncol; ++c) {
			/* 语义与旧的逐格递归完全一致：row<=1 的 "-" 不继承，
			 * 原样保留字面值，由调用方决定含义（inherited 返 "-"、parseMtDouble 返 0.0；
			 * 动作派发另把「首数据行即 '-'」判为未起拍、不投递该参数，见 robot.cpp）。 */
			if (r > 1 && values_[r][c] == "-") {
				inherited_.push_back(inherited_[(r - 1) * ncol + c]);
			} else {
				inherited_.push_back(values_[r][c]);
			}
		}
	}
	inheritedReady_ = true;
}

std::int64_t MatrixObject::requireCol(std::size_t row, const std::string& key,
		const std::string& what) const {
	std::int64_t idx = indexOfCol(row, key);
	if (idx < 0) {
		throw bot::IllegalArgumentException(what + " '" + name_ + "' has no '"
			+ key + "' column.");
	}
	return idx;
}

void MatrixObject::save(std::ostream& out) const {
	out << "@" << getName() << "\n";
	for (const auto& vec : values_) {
		for (const auto& item : vec) {
			out << item << " ";
		}
		out << ";\n";
	}
	/* @块嵌套：控制块（@if/@while）自身网格为空、体在 children——递归写出子块，
	 * 再以裸 '@' 收口。叶子块 children 恒空，行为与旧版逐字一致。 */
	for (const auto& child : children_) {
		child.save(out);
	}
	out << "@\n";
}

void MatrixObject::appendRow(std::vector<std::string> row, std::int64_t count) {
	if (!values_.empty() && row.size() != values_.back().size()) {
		throw DoesNotSync(count, values_.back().size(), row.size());
	}
	values_.push_back(std::move(row));
	inheritedReady_ = false;	/* 行数变了，继承缓存作废 */
}

void MatrixObject::popRows(std::size_t count) {
	if (count > values_.size()) {
		throw bot::IllegalArgumentException("MatrixObject::popRows(" + std::to_string(count)
			+ ") exceeds " + std::to_string(values_.size()) + " row(s)");
	}
	values_.resize(values_.size() - count);
	inheritedReady_ = false;
}

void MatrixObject::removeRows(const std::vector<std::size_t>& rows) {
	if (rows.empty()) { return; }
	std::vector<char> doomed(values_.size(), 0);
	for (std::size_t r : rows) {
		if (r == 0) {
			throw bot::IllegalArgumentException(
				"MatrixObject::removeRows: row 0 is the column header and cannot be removed");
		}
		if (r >= values_.size()) {
			throw bot::IllegalArgumentException("MatrixObject::removeRows: row "
				+ std::to_string(r) + " is out of range (" + std::to_string(values_.size())
				+ " row(s))");
		}
		if (doomed[r] != 0) {
			throw bot::IllegalArgumentException("MatrixObject::removeRows: row "
				+ std::to_string(r) + " listed twice");
		}
		doomed[r] = 1;
	}
	std::vector<std::vector<std::string>> kept;
	kept.reserve(values_.size() - rows.size());
	for (std::size_t r = 0; r < values_.size(); ++r) {
		if (doomed[r] == 0) { kept.push_back(std::move(values_[r])); }
	}
	values_ = std::move(kept);
	inheritedReady_ = false;	/* 行数变了，继承缓存作废 */
}

/* 解析器主体：一个 _next 消费一个字符，返回更新后的行号。
 *
 * 2026-10-12 @块嵌套：从「单块 + flag_」升级为帧栈（stack_）。状态位仍是
 * nl_（行首）/cm_（注释）/nm_（正在读块头名字 token），但「@ 是开还是闭」不再
 * 靠 hasName 区分，而是**读完 '@' 后的名字 token 再决策**（Reader 无 peek）：
 * 空名（裸 @）= 闭合最内层帧；if(/while( = 开控制帧；其余 = 开叶子帧（commitHeader）。
 * 数据行路由到栈顶帧的构建器（dataBuilder）：叶子 → self 网格；控制 → pendingAction
 * （连续直接行，遇子块或闭合时冲刷成隐式 @Action 子块）；栈空 → scratch_（游离数据，
 * 永不具名 → parse 返 nullopt，与旧行为一致）。
 *
 * 状态转移表（全部并列分支）：
 *   输入            │ 条件                      │ 动作
 *   ────────────────┼───────────────────────────┼──────────────────────────────
 *   '#'             │ 非注释态                  │ 进注释态；名字态 commitHeader，
 *                   │                           │ 数据态提交挂起单元（C-M）
 *   '\n'            │ 注释态                    │ 退注释态，行号 +1
 *   其他            │ 注释态                    │ 忽略
 *   空白/'\r'       │ 行首态（nl_）             │ 忽略
 *   '\n'            │ 行首态                    │ 行号 +1
 *   '@'             │ 行首态                    │ 进名字态、清 hdr_（开/闭延后到 token 结束）
 *   其他            │ 行首态                    │ 退行首态，字符起头新单元（dataBuilder）
 *   空白/换行       │ 名字态（nm_）             │ commitHeader(hdr_)，回行首态
 *   其他            │ 名字态                    │ 追加进 hdr_（含 ';'：块头不以 ';' 收口）
 *   空白/换行       │ 数据态                    │ 提交单元（dataBuilder）
 *   ';'             │ 数据态                    │ 提交单元并收口一行；控制帧置 pendingHasRows
 *   其他            │ 数据态                    │ 追加进当前单元（dataBuilder）
 *
 * 与旧机的唯一可见偏差都落在畸形输入上（旧机把 "@Name;" 的名字当父块数据格、
 * 把块前游离数据混进后续块）——新机分别按「';' 属块头名字」「游离数据进 scratch_」
 * 处理，更自洽；良构脚本（每块 @名字…@ 成对、行以 ';' 收口）逐字不变。 */
std::int64_t MatrixParser::next_(char c, std::int64_t count) {
	/* ------------ COMMENTS ------------ */
	if (!cm_ && c == '#') {
		cm_ = true;
		/* C-M：注释起始须先提交挂起内容，否则注释结束后文本拼回同一单元
		 * （"50#c\n60" → "5060"），动作数值被静默篡改。名字态先落定块头
		 * （开块/闭合）；数据态仅提交挂起单元，行继续由 ';' 收口。 */
		if (nm_) {
			commitHeader(hdr_);
			hdr_.clear();
			nm_ = false;
		} else {
			dataBuilder().submitItem();
		}
	}
	else if (cm_ && c == '\n') {
		nl_ = true;
		cm_ = false;
		count += 1;
	}
	/* 注释中段与行首空白都是「跳过该字符」——合并为同一分支（两判据互不冲突，
	 * 主体同为空），避免条件链出现克隆分支 */
	else if ((cm_ && c != '\n') || (nl_ && (c == ' ' || c == '\t' || c == '\r'))) { ; }
	else if (nl_ && c == '\n') { count += 1; }
	else if (nl_ && c == '@') {
		/* 进名字态、清 hdr_：开块还是闭合，等名字 token 读完（空白/换行/注释/EOF）
		 * 由 commitHeader 按 hdr_ 空否决策。 */
		nl_ = false;
		nm_ = true;
		hdr_.clear();
	}
	else if (nl_ && c != '@') {
		nl_ = false;
		dataBuilder().addRune(c);
	}
	/* ------------- not nl ------------- */
	else if (!nl_ && nm_ && (c == ' ' || c == '\t' || c == '\r' || c == '\n')) {
		/* '\r' 也算块头名字的终止符：CRLF 脚本里 "@Timer\r\n" 的名字 token 到 '\r'
		 * 即收口（名字干净、不带 '\r'），且裸 "@\r\n" 因此得到空 hdr → 判定为闭合。
		 * 少了 '\r'，裸闭合符会被读成 hdr="\r"（非空）→ 误判为在叶子块内嵌套而报错。 */
		commitHeader(hdr_);
		hdr_.clear();
		nm_ = false;
		nl_ = true;
		if (c == '\n') { count += 1; }	/* @Name 行末的换行同样计数，否则后续行号全部少 1 */
	}
	else if (!nl_ && nm_) {
		hdr_ += c;	/* 块头名字字符（含 ';'：块头不以 ';' 收口，与数据态区分） */
	}
	else if (!nl_ && (c == ' ' || c == '\t' || c == '\n')) {
		dataBuilder().submitItem();
		if (c == '\n') { count += 1; }
	}
	else if (!nl_ && c == ';') {
		dataBuilder().submitItem();
		dataBuilder().submitLine(count);
		/* 控制帧的直接行落进 pendingAction：标记有行，供 flushPending 合成隐式 @Action */
		if (!stack_.empty() && stack_.back().isControl) { stack_.back().pendingHasRows = true; }
		nl_ = true;
	}
	else if (!nl_) {
		dataBuilder().addRune(c);
	}
	return count;
}

/* 当前接收数据行的构建器：控制帧 → pendingAction（隐式 @Action 行run），
 * 叶子帧 → self（网格），栈空 → scratch_（顶层游离数据，永不具名）。 */
MatrixBuilder& MatrixParser::dataBuilder() {
	if (stack_.empty()) { return scratch_; }
	Frame& f = stack_.back();
	return f.isControl ? f.pendingAction : f.self;
}

/* 控制帧：把当前直接行run冲刷成一个隐式 @Action 子块（名字已在开帧时置 "Action"），
 * 并复位 pendingAction 以接收下一段行run（子块之后的直接行 → 下一个隐式 @Action）。 */
void MatrixParser::flushPending(Frame& f) {
	if (f.isControl && f.pendingHasRows) {
		f.children.push_back(f.pendingAction.take());
		f.pendingAction = MatrixBuilder();
		f.pendingAction.name("Action");
		f.pendingHasRows = false;
	}
}

/* 块头名字 token 读完：空名（裸 @）= 闭合最内层；非空 = 开块（控制/叶子）。 */
void MatrixParser::commitHeader(const std::string& hdr) {
	if (hdr.empty()) {
		/* 裸 @：闭合最内层帧。栈空即多余的闭合符——响亮拒绝（旧机静默忽略，
		 * 但那正是「内层 @ 被当外层闭合符 → 后续静默截断」的根源，不再容忍）。 */
		if (stack_.empty()) {
			throw bot::IllegalArgumentException("多余的 '@'：此处没有待闭合的块"
				"（每个 @名字 … @ 必须成对）");
		}
		closeFrame();
		return;
	}
	/* 开块 */
	if (!stack_.empty()) {
		if (!stack_.back().isControl) {
			throw bot::IllegalArgumentException("叶子块 @" + stack_.back().name
				+ " 内不能嵌套 @" + hdr + "：只有 @if/@while 能含子块，"
				+ "@Action/@Alias/@Vars 等叶子块的体只能是数据行");
		}
		if (stack_.size() + 1 > kMaxBlockDepth) {
			throw bot::IllegalArgumentException("@块嵌套深度超过上限 "
				+ std::to_string(kMaxBlockDepth) + "（在 @" + hdr + "）");
		}
		flushPending(stack_.back());	/* 子块打断父控制帧当前的直接行run */
	}
	Frame f;
	f.name = hdr;
	f.isControl = isControlBlockName(hdr);
	if (f.isControl) { f.pendingAction.name("Action"); }
	else { f.self.name(hdr); }
	stack_.push_back(std::move(f));
}

/* 闭合最内层帧：叶子取自身网格；控制先冲刷尾部行run，再组装成「名字 + children、
 * 网格为空」的 MatrixObject。产物挂到父控制帧的 children，或在栈空时成为 parse() 结果。 */
void MatrixParser::closeFrame() {
	Frame f = std::move(stack_.back());
	stack_.pop_back();
	MatrixObject m;
	if (f.isControl) {
		flushPending(f);	/* 收尾：尾部直接行run → 最后一个隐式 @Action 子块 */
		MatrixBuilder b;
		b.name(f.name);
		for (auto& ch : f.children) { b.addChild(std::move(ch)); }
		m = b.take();
	} else {
		m = f.self.take();
	}
	if (stack_.empty()) {
		result_ = std::move(m);
		done_ = true;
	} else {
		/* 父帧必为控制帧：叶子父帧在 commitHeader 开子块时已响亮拒绝 */
		stack_.back().children.push_back(std::move(m));
	}
}

/* 一次只解析一个顶层块（可能带 children）；无新的矩阵式对象（意外终止）返回空 */
std::optional<MatrixObject> MatrixParser::parse() {
	std::int64_t count = 1;
	/* 每个顶层块独立解析：全部状态复位。栈/scratch_/hdr_/done_/result_ 与三个
	 * 状态位一起清——残留会把下一个块的起始 '@' 当数据吞进名字（旧机同一理由）。 */
	stack_.clear();
	scratch_ = MatrixBuilder();
	hdr_.clear();
	done_ = false;
	result_.reset();
	nl_ = true;
	cm_ = false;
	nm_ = false;

	/* 读取初始状态，循环直到 done_（顶层帧闭合）或 EOF。done_ 必须在 read() 之前
	 * 检查：闭合 '@' 的名字 token 结束即置 done_，若再读一个字符会丢掉下一个块的
	 * 前导字符（单换行分隔时恰好少掉换行，触发名字污染）。 */
	for (;;) {
		if (done_) { break; }
		int c = input_.read();
		if (c < 0) {
			/* EOF 前若正读块头名字 token（nm_），先落定它——脚本以裸 '@' 收尾
			 * 且无尾随换行时，闭合符否则永远等不到终止空白而被误判「未闭合」。 */
			if (nm_) {
				try {
					commitHeader(hdr_);
				} catch (const bot::IllegalArgumentException& e) {
					throw bot::IllegalArgumentException("Parse failed at line "
						+ std::to_string(count) + ": " + e.what());
				}
				hdr_.clear();
				nm_ = false;
			}
			/* EOF 时栈非空 = 有块未闭合：响亮报错，根治旧机「内层 @ 当外层闭合符
			 * → 后续脚本静默截断」。 */
			if (!stack_.empty()) {
				throw bot::IllegalArgumentException("脚本结束（EOF，第 "
					+ std::to_string(count) + " 行）但块 @" + stack_.back().name
					+ " 未闭合：每个 @名字 … @ 必须成对（缺一个闭合的 '@'）");
			}
			break;
		}
		try {
			count = next_(static_cast<char>(c), count);
		} catch (const MatrixParseExcept&) {
			throw;	/* DoesNotSync 等已自带行号与语义，原样上抛，不降级成无信息异常 */
		} catch (const bot::IllegalArgumentException& e) {
			/* N-2：包装保留原文——被包异常往往含列名/具体原因，只留行号
			 * 会让用户拿着「Parse failed at line N」无从排障。 */
			throw bot::IllegalArgumentException("Parse failed at line "
				+ std::to_string(count) + ": " + e.what());
		}
		/* 阶段 5：UnknowExcept 兜底分支删除——非 IAE 的 std 异常（bad_alloc/
		 * length_error 等）原被降级成「I don't understand what happened」，
		 * 掩盖真实成因；按 fail-fast 原则原样上抛。 */
	}

	if (done_ && result_) { return std::move(*result_); }
	return std::nullopt;
}

/* 逐个解析矩阵外表直到 EOF（N-11：自 ScriptLoader::readMatrix 下沉，
 * mtmerge 与 mybot 运行端共用同一入口） */
void readMatrix(bot::Reader& file, std::vector<MatrixObject>& out) {
	MatrixParser parser(file);
	while (auto mat = parser.parse()) {
		out.push_back(std::move(*mat));
	}
}

/* WHERE 等值匹配（契约见 matrix.hpp 声明处）：先 requireCol 定位（缺失即抛，
 * 调用方不必预检），再对每个数据行的 inherited 值做精确比较。 */
std::vector<std::size_t> matchRows(const MatrixObject& m, const std::string& col,
		const std::string& val) {
	const std::int64_t idx = m.requireCol(0, col, "Table");
	std::vector<std::size_t> hits;
	for (std::size_t r = 1; r < m.rows(); ++r) {
		if (m.inherited(r, static_cast<std::size_t>(idx)) == val) { hits.push_back(r); }
	}
	return hits;
}

/* 多条件 AND（契约见 matrix.hpp 声明处）：先一次性解析各条件的列号
 * （requireCol 的报错因此在行循环之外抛出——坏列名不随行数重复构造），
 * 再逐行短路判定：AND 语义下任一条件不成立即可跳过该行。空条件表 = 无条件，
 * 循环体不执行、每行都命中（这正是 `DELETE FROM t;` 的语义）。 */
std::vector<std::size_t> matchAll(const MatrixObject& m,
		const std::vector<std::pair<std::string, std::string>>& conds) {
	std::vector<std::int64_t> idxs;
	idxs.reserve(conds.size());
	for (const auto& c : conds) { idxs.push_back(m.requireCol(0, c.first, "Table")); }

	std::vector<std::size_t> hits;
	for (std::size_t r = 1; r < m.rows(); ++r) {
		bool all = true;
		for (std::size_t k = 0; k < conds.size(); ++k) {
			if (m.inherited(r, static_cast<std::size_t>(idxs[k])) != conds[k].second) {
				all = false;
				break;
			}
		}
		if (all) { hits.push_back(r); }
	}
	return hits;
}

} // namespace mt