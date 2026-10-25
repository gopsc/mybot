/* mtinclude.cpp —— @Merge 展开（实现契约见 mtinclude.hpp）
 *
 * 结构：Expander 持一次 expandIncludes 调用的全部跨层状态（visited 表、
 * 行数/字节预算），按层递归——每层（主脚本或某个片段）把**自己的**
 * @Alias/@Vars/@Action 作为累加器初值，再按声明序并入自己 @Merge 行
 * 指向的子片段的有效产物；「自己的定义」名字集在并入子片段前快照，
 * 作为主从覆盖的判定依据（同层自己获胜，子片段互相之间报错）。
 *
 * 信任边界（务必与 docs/dsl.md 保持一致）：--tcp 下发的动作脚本可借
 * @Merge 触达本地文件。防线按层：
 *   1) 词法：路径必须是相对名——拒绝绝对路径、'..' 分量、空段、NUL，
 *      只放行 .mt 后缀（规则集与 agent::resolveActionScriptPath 同族）；
 *   2) 硬限：全树 @Merge 行数 ≤ kMaxIncludes（该预算**同时**界定了嵌套深度——
 *      每层递归至少消耗一行 @Merge，故深度 ≤ kMaxIncludes；仓库里并没有独立的
 *      深度常量，旧注释写的 kMaxIncludeDepth 是不存在的防线，已按实况改掉）、
 *      字节总量 ≤ 8 MiB、单文件 ≤ 8 MiB；
 *   2b) 产物预算：归并产物的行数 ≤ mtmerge::kMaxMergedRows、单元格数 ≤
 *      mtmerge::kMaxMergedCells（判据在 mergeTwo 单点，mtmerge 工具与本展开共用）。
 *      没有它，一行 `@Merge path=..., phase=100000` 就能把终态撑到 ~1e5 行 ×
 *      数十列（数百 MB）⇒ 树莓派上 OOM，而 OOM 是 SIGKILL 语义，deactivate()
 *      整体被跳过；
 *   3) O_NOFOLLOW：拒绝符号链接（残余同 agent::readFileLimited 的声明：
 *      路径中间的目录软链仍可穿越——能写 base 树的进程本就能直接改脚本，
 *      不构成增量能力）；
 *   4) 内容不回显：读取/解析失败只报路径类信息，被包含文件的内容不会
 *      进入报错文本。
 */

#include "mtinclude.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iostream>	/* std::cerr：此前靠 util_env.hpp 传导 */
#include <map>
#include <optional>
#include <set>
#include <unistd.h>

#include "mtmerge_core.hpp"
#include "scriptlimit.hpp"	/* kMaxScriptBytes / ScriptTooLarge（限流原语叶子头） */
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_file.hpp"
#include "util_num.hpp"
#include "util_path.hpp"
#include "util_str.hpp"

namespace mtinclude {

namespace {

constexpr std::size_t kMaxIncludeTotalBytes = bot::kMaxScriptBytes;

/* include-once 复用标记：文件名后缀（与 _VIRT 工厂后缀同族的命名约定）。
 * 放在文件而非包含行：片段自己声明复用策略，所有包含点免于各自记忆。 */
bool endsWithOnceSuffix(const std::string& path) {
	const std::string suffix = ".once.mt";
	return path.size() >= suffix.size()
		&& path.compare(path.size() - suffix.size(), suffix.size(), suffix) == 0;
}

/* include/merge 路径词法校验（M2/B2-1：段判据单点 util::checkRelPath，与
 * agent::resolveActionScriptPath、luasandbox 同源；报错文案留在此处）。
 * directive 只用于报错文案（"@Include" / "@Merge"），规则两者同一套。
 * 通过则原样返回，失败抛 IllegalArgumentException。 */
std::string validateIncludePath(const std::string& requested, const char* directive) {
	if (requested.empty()) {
		throw bot::IllegalArgumentException(std::string(directive) + " path is empty"
			" (the 'path' column must carry a relative .mt path)");
	}
	switch (bot::checkRelPath(requested)) {
	case bot::RelPathCheck::ABSOLUTE:
		throw bot::IllegalArgumentException(std::string(directive) + " path must be relative to the"
			" include base directory, absolute path rejected: " + requested);
	case bot::RelPathCheck::NUL:
		throw bot::IllegalArgumentException(std::string(directive) + " path contains NUL");
	case bot::RelPathCheck::EMPTY_OR_DOT:
		throw bot::IllegalArgumentException(std::string(directive) + " path contains an empty or '.'"
			" segment: " + requested);
	case bot::RelPathCheck::DOTDOT:
		throw bot::IllegalArgumentException(std::string(directive) + " path must not traverse outside"
			" the include base directory: " + requested);
	default:
		break;
	}
	std::size_t slash = requested.rfind('/');
	std::string last = (slash == std::string::npos) ? requested : requested.substr(slash + 1);
	if (last.size() < 3 || last.compare(last.size() - 3, 3, ".mt") != 0) {
		throw bot::IllegalArgumentException(std::string(directive) + " only accepts .mt action scripts: "
			+ requested);
	}
	return requested;
}

/* 读取被包含文件（M2/B2-3 单点）：FD 骨架收敛到 util::readFdNoFollowLimited，
 * 单文件上限 kMaxScriptBytes / 多文件总量 kMaxIncludeTotalBytes 双预算在此配。
 * 超限即抛（先拒绝后使用——整读进内存再判上限形同虚设）。 */
std::string readIncludeFile(const std::string& path, std::size_t& totalBytes) {
	std::string data;
	switch (bot::readFdNoFollowLimited(path, bot::kMaxScriptBytes, data,
			&totalBytes, kMaxIncludeTotalBytes)) {
	case bot::FdReadStatus::SYMLINK:
		throw bot::IllegalArgumentException("include rejected: symbolic link: " + path);
	case bot::FdReadStatus::OPEN_FAILED:
		throw bot::IllegalArgumentException("cannot open include file: " + path
			+ " (" + bot::errnoText(errno) + ")");
	case bot::FdReadStatus::READ_FAILED:
		throw bot::IllegalArgumentException("read include file failed: " + path);
	case bot::FdReadStatus::TOO_LARGE:
		throw bot::ScriptTooLarge(bot::kMaxScriptBytes, "included action script");
	case bot::FdReadStatus::TOTAL_TOO_LARGE:
		throw bot::ScriptTooLarge(kMaxIncludeTotalBytes,
			"total size of included action scripts");
	case bot::FdReadStatus::OK:
		return data;
	}
	return data;
}

/* @Merge 矩阵单块行读取：列头白名单（path 必需、phase 可选）+ 每行的
 * 路径/相位解析。phase 沿用矩阵 "-" 继承语义（继承上一行相位，首行 "-" = 0），
 * 数值域与 mtmerge --phase 同界（mtmerge::kMaxPhase）。 */
struct IncludeRow {
	std::string path;	/* 词法校验后的相对路径 */
	std::int64_t phase = 0;
};

class IncludeBlockReader {
	const mt::MatrixObject& block_;
	std::int64_t idxPath_;
	std::int64_t idxPhase_;

public:
	explicit IncludeBlockReader(const mt::MatrixObject& block) : block_(block) {
		for (std::size_t j = 0; j < block.cols(); ++j) {
			std::string head = bot::trim(block(0, j));
			if (head != "path" && head != "phase") {
				throw bot::IllegalArgumentException("@Merge matrix column '" + head
					+ "' is not supported (only 'path' and 'phase')");
			}
		}
		idxPath_ = block.requireCol(0, "path", "@Merge matrix");
		idxPhase_ = block.indexOfCol(0, "phase");
	}

	std::size_t rowCount() const {
		return block_.rows() > 0 ? static_cast<std::size_t>(block_.rows()) - 1 : 0;
	}

	IncludeRow row(std::int64_t r) const {
		IncludeRow out;
		out.path = validateIncludePath(bot::trim(block_(r, idxPath_)), "@Merge");
		if (idxPhase_ >= 0) {
			std::string ph = bot::trim(block_.inherited(r, idxPhase_));
			if (ph != "-") {	/* "-"：继承上一行相位；首行 "-" = 缺省 0 */
				auto [st, num] = bot::parseLongStrict(ph);
				if (st != bot::IntParse::OK) {
					throw bot::IllegalArgumentException("@Merge phase is not an integer: '"
						+ ph + "' (row " + std::to_string(r) + ")");
				}
				if (num > mtmerge::kMaxPhase || num < -mtmerge::kMaxPhase) {
					throw bot::IllegalArgumentException("@Merge phase out of range ±"
						+ std::to_string(mtmerge::kMaxPhase) + ": " + ph);
				}
				out.phase = num;
			}
		}
		return out;
	}
};

/* @Include 块的 path 列读取（内容拷贝，无相位）：只允许 'path' 列——'phase'
 * 对纯拷贝无意义，出现即响亮拒绝（指引改用 @Merge）。返回逐行词法校验后的路径。 */
std::vector<std::string> readIncludePaths(const mt::MatrixObject& block) {
	std::int64_t idxPath = -1;
	for (std::size_t j = 0; j < block.cols(); ++j) {
		const std::string head = bot::trim(block(0, j));
		if (head == "path") {
			idxPath = static_cast<std::int64_t>(j);
		} else if (head == "phase") {
			throw bot::IllegalArgumentException("@Include is a plain content copy and does"
				" not accept a 'phase' column (use @Merge for phase-based merging)");
		} else {
			throw bot::IllegalArgumentException("@Include matrix column '" + head
				+ "' is not supported (only 'path')");
		}
	}
	if (idxPath < 0) {
		throw bot::IllegalArgumentException("@Include matrix has no 'path' column");
	}
	std::vector<std::string> out;
	for (std::int64_t r = 1; r < static_cast<std::int64_t>(block.rows()); ++r) {
		out.push_back(validateIncludePath(
			bot::trim(block(static_cast<std::size_t>(r), static_cast<std::size_t>(idxPath))),
			"@Include"));
	}
	return out;
}

/* 一个文件（主脚本或片段）展开后的有效产物。path 供上层归并的报错/注记归因。 */
struct ScriptParts {
	std::optional<mt::MatrixObject> alias, vars, action;
	std::string path;
};

/* 一层的归并累加器 + 来源标签（报错文案指明冲突两侧）。 */
struct MergeAcc {
	std::optional<mt::MatrixObject> alias, vars, action;
	std::string aliasPath = "<main script>", varsPath = "<main script>",
		    actionPath = "<main script>";
};

/* 本层「自己的定义」名字集：并入子片段前快照，主从覆盖的判定依据。 */
struct LevelOwned {
	std::set<std::string> alias, vars;
};

LevelOwned ownedNamesOf(const MergeAcc& acc) {
	LevelOwned out;
	auto collect = [](const std::optional<mt::MatrixObject>& m, std::set<std::string>& into) {
		if (!m) { return; }
		std::int64_t idx = m->indexOfCol(0, "name");
		if (idx < 0) { return; }
		for (std::int64_t r = 1; r < static_cast<std::int64_t>(m->rows()); ++r) {
			into.insert((*m)(static_cast<std::size_t>(r), static_cast<std::size_t>(idx)));
		}
	};
	collect(acc.alias, out.alias);
	collect(acc.vars, out.vars);
	return out;
}

/* 主从覆盖的执行点：丢弃 next 中与本层自有定义同名的行（stderr 注记），
 * 其余行原样进入后续归并（子片段互相之间的同名由此仍走 mergeScalarRows
 * 的重复报错）。全未命中时原样拷贝返回。 */
mt::MatrixObject dropOwnedRows(const mt::MatrixObject& m, const std::set<std::string>& owned,
		const std::string& file, const char* kind) {
	std::int64_t idxName = m.indexOfCol(0, "name");
	if (idxName < 0) { return m; }	/* 缺 name 列：原样放行，由 mergeScalarRows 报正错 */
	bool anyDropped = false;
	for (std::int64_t r = 1; r < static_cast<std::int64_t>(m.rows()); ++r) {
		const std::string& name = m(static_cast<std::size_t>(r), static_cast<std::size_t>(idxName));
		if (owned.count(name) > 0) {
			anyDropped = true;
			std::cerr << "mtinclude: " << kind << " '" << name << "' from '" << file
				<< "' ignored; a definition closer to the main script wins" << std::endl;
		}
	}
	if (!anyDropped) { return m; }
	mt::MatrixBuilder b;
	b.name(m.getName());
	for (std::size_t j = 0; j < m.cols(); ++j) { b.item(m(0, j)); }
	b.line(0);
	for (std::int64_t r = 1; r < static_cast<std::int64_t>(m.rows()); ++r) {
		const std::string& name = m(static_cast<std::size_t>(r), static_cast<std::size_t>(idxName));
		if (owned.count(name) > 0) { continue; }
		for (std::size_t j = 0; j < m.cols(); ++j) {
			b.item(m(static_cast<std::size_t>(r), j));
		}
		b.line(0);
	}
	return b.take();
}

/* 展开器：一次 expandIncludes 调用的全部跨层状态（visited 表/预算）。 */

/* 片段层「疑似 @if 块」的判据（宽松版，与 action_runner 的 parseIfBlockName
 * 精确版**故意不同**）：trim 后等于 "if" 或以 "if(" 开头即拒——凡是看起来
 * 想写 @if 的都拒下（含未闭合等非法形态），主脚本侧才做精确解析分派。
 * 宽松版永不比精确版窄，两份判据不构成漂移。拒绝的理由：片段的 @Action
 * 按相位**归并**进主脚本 @Action，没有独立的执行位置，@if 放进片段只能
 * 静默丢弃（@Reflex 已是这个坑——本仓不再重蹈）。 */
namespace {
bool looksLikeIfBlock(const std::string& rawName) {
	const std::string n = bot::trim(rawName);
	return n == "if" || n.compare(0, 3, "if(") == 0;
}
/* @while 同型判据（与 looksLikeIfBlock 同一理由：片段的 @Action 按相位归并，
 * @while 放进片段没有独立执行位置，只能静默丢弃——响亮拒绝）。 */
bool looksLikeWhileBlock(const std::string& rawName) {
	const std::string n = bot::trim(rawName);
	return n == "while" || n.compare(0, 6, "while(") == 0;
}
} // namespace

class Expander {
public:
	explicit Expander(const std::string& mainBase) : mainBase_(mainBase) {}

	void run(std::vector<mt::MatrixObject>& parsed) {
		MergeAcc acc;
		if (auto* act = mt::findByName(parsed, "Action")) { acc.action = *act; }
		if (auto al = mtmerge::foldNamed(parsed, "Alias", acc.aliasPath)) {
			acc.alias = std::move(*al);
		}
		if (auto va = mtmerge::foldNamed(parsed, "Vars", acc.varsPath)) {
			acc.vars = std::move(*va);
		}
		LevelOwned owned = ownedNamesOf(acc);	/* 快照：仅本层自有定义 */
		runLevel(parsed, mainBase_, acc, owned);

		/* 产物：@Alias、@Vars、其余主脚本块按**原书写顺序**透传。
		 * 2026-10-10 @if 特性起顺序不再是「无关」：runAction 按书写顺序
		 * 交错执行 "Action" 与 "if(...)" 名块，合并 @Action 锚在主脚本
		 * **第一个** @Action 块的位置（其余主脚本多余 Action 块维持既有
		 * 丢弃语义——只有第一个进合并）；主脚本自己没有 @Action（动作全
		 * 靠片段供给）时合并块退回旧位置（紧随 Vars、透传块之前）。 */
		std::vector<mt::MatrixObject> out;
		if (acc.alias) { out.push_back(std::move(*acc.alias)); }
		if (acc.vars) { out.push_back(std::move(*acc.vars)); }
		bool mainHasAction = false;
		for (const auto& m : parsed) {
			if (bot::trim(m.getName()) == "Action") { mainHasAction = true; break; }
		}
		bool actionPlaced = false;
		if (acc.action && !mainHasAction) {
			out.push_back(std::move(*acc.action));
			actionPlaced = true;
		}
		for (auto& m : parsed) {
			std::string n = bot::trim(m.getName());
			if (n == "Alias" || n == "Vars" || n == "Merge") { continue; }
			if (n == "Action") {
				if (!actionPlaced && acc.action) {
					out.push_back(std::move(*acc.action));
					actionPlaced = true;
				}
				continue;
			}
			out.push_back(std::move(m));
		}
		parsed = std::move(out);
	}

	/* @Include：C 式内容拷贝（顶层专属，2026-10-12）。把每个 @Include 块替换成
	 * 目标文件解析出的顶层矩阵，按序插到原位置；被拷贝内容里的 @Include 以【该
	 * 文件自身目录】为基准递归展开。行数/字节与 @Merge 共享预算（kMaxIncludes /
	 * 8 MiB）——自包含/互包含的拷贝在触达行数上限时响亮终止（C 式允许重复拷贝，
	 * 故不设 visited 集，靠预算兜底）。无 @Include 时逐字不动。 */
	void spliceIncludes(std::vector<mt::MatrixObject>& seq, const std::string& baseDir) {
		bool any = false;
		for (const auto& m : seq) {
			if (bot::trim(m.getName()) == "Include") { any = true; break; }
		}
		if (!any) { return; }

		std::vector<mt::MatrixObject> out;
		for (auto& m : seq) {
			if (bot::trim(m.getName()) != "Include") {
				out.push_back(std::move(m));
				continue;
			}
			if (m.rows() == 0) { continue; }	/* 只有名字没有内容的退化块 */
			for (const std::string& rel : readIncludePaths(m)) {
				if (++rowCount_ > kMaxIncludes) {
					throw bot::IllegalArgumentException("@Include declares "
						+ std::to_string(rowCount_ - 1) + " rows before this one,"
						+ " exceeding the limit of " + std::to_string(kMaxIncludes)
						+ " across the whole include tree (each row reads a local file)");
				}
				const std::string resolved = baseDir + "/" + rel;
				std::string data = readIncludeFile(resolved, totalBytes_);
				bot::MemoryReader in(std::move(data));
				std::vector<mt::MatrixObject> inc;
				mt::readMatrix(in, inc);
				spliceIncludes(inc, dirOf(resolved));	/* 被拷贝内容的 @Include 递归展开 */
				for (auto& x : inc) { out.push_back(std::move(x)); }
			}
		}
		seq = std::move(out);
	}

	/* @Include / @Merge 的位置约束（响亮拒绝，不静默）：
	 *   - @Include 只能出现在最外层（像 C 的 #include）——出现在控制块 children
	 *     里没有意义（拷贝进来的块会被归并/执行序打散），拒绝；
	 *   - @Merge 在 children 里由 mergeNestedDirectives 位置局部归并后消费掉，
	 *     正常不会走到这里；保留兜底拒绝以免静默丢弃。 */
	void rejectNestedDirectives(const std::vector<mt::MatrixObject>& seq) const {
		for (const auto& m : seq) {
			const std::string n = bot::trim(m.getName());
			if (n == "Include") {
				throw bot::IllegalArgumentException("@Include 只能出现在最外层（像 C 的"
					" #include）：不能嵌在 @if/@while 子块里；如需在子块内归并动作表请用 @Merge");
			}
			if (n == "Merge") {
				throw bot::IllegalArgumentException("@Merge 暂不支持出现在 @if/@while 子块内"
					"（嵌套归并尚未实现）：请把该 @Merge 挪到最外层");
			}
			rejectNestedDirectives(m.children());
		}
	}

	/* 嵌套 @Merge 的位置局部归并（2026-10-12，用户选定「位置局部归并」语义）：
	 * 只在【控制块 children 序列】内生效——顶层 @Merge 仍走 run() 的累加器机制
	 * （@Alias/@Vars 主从折叠、@Action 锚定、块重排）。
	 *
	 * 语义：children 序列里的 @Merge 块，把它引用的目标文件【纯矩阵表】按声明序
	 * 用 mergeTwo（相位补 '-'、设备集不相交、拒绝控制块操作数）并入【同一序列里
	 * 紧邻其下的那张叶子表】；连续多个 @Merge 累加进同一张下表；随后 @Merge 块被
	 * 消费掉、从序列移除。块序保持书写序（execSequence 的交错执行依赖此序）。
	 *
	 * 目标文件必须只含纯矩阵表：携带 @Alias/@Vars（嵌套标量 robot_actions 不注册）
	 * 或控制块（mergeTwo 拒）即响亮拒绝。递归下钻所有 children。baseDir 用主脚本
	 * 目录（片段内嵌套 @Merge 的相对解析属进一步特性，误配只会得到响亮的开文件错）。 */
	void mergeNestedDirectives(std::vector<mt::MatrixObject>& seq, const std::string& baseDir) {
		std::vector<mt::MatrixObject> out;
		std::vector<const mt::MatrixObject*> pending;	/* 等待「下表」的 @Merge 块 */
		for (auto& m : seq) {
			if (bot::trim(m.getName()) == "Merge") {
				pending.push_back(&m);
				continue;
			}
			if (pending.empty()) {
				out.push_back(std::move(m));
				continue;
			}
			/* m 是紧邻 @Merge 之下的表：必须是纯矩阵叶子 */
			if (m.hasChildren()) {
				throw bot::IllegalArgumentException("@Merge 下面必须紧跟一张纯矩阵表："
					"找到的却是控制块 @" + bot::trim(m.getName())
					+ "（嵌套 @Merge 只把目标纯矩阵并入其下紧邻的叶子表）");
			}
			mt::MatrixObject acc = std::move(m);
			std::string accPath = "<inline table>";
			for (const mt::MatrixObject* mb : pending) {
				if (mb->rows() == 0) { continue; }	/* 退化块：无事可做 */
				IncludeBlockReader rows(*mb);
				for (std::int64_t r = 1; r < static_cast<std::int64_t>(mb->rows()); ++r) {
					if (++rowCount_ > kMaxIncludes) {
						throw bot::IllegalArgumentException("@Merge declares "
							+ std::to_string(rowCount_ - 1) + " rows before this one,"
							+ " exceeding the limit of " + std::to_string(kMaxIncludes)
							+ " across the whole include tree (each row reads a local file)");
					}
					IncludeRow spec = rows.row(r);
					const std::string resolved = baseDir + "/" + spec.path;
					std::string data = readIncludeFile(resolved, totalBytes_);
					bot::MemoryReader in(std::move(data));
					std::vector<mt::MatrixObject> tgt;
					mt::readMatrix(in, tgt);
					if (tgt.empty()) {
						throw bot::IllegalArgumentException("'" + resolved + "': no matrix found");
					}
					for (const auto& t : tgt) {
						const std::string tn = bot::trim(t.getName());
						if (tn == "Alias" || tn == "Vars") {
							throw bot::IllegalArgumentException("嵌套 @Merge 目标只能是纯矩阵表：'"
								+ resolved + "' 含 @" + tn + "（@if/@while 子块内的 @Merge 不注册"
								"标量，请把这些 @Alias/@Vars 挪到最外层，或用顶层 @Merge）");
						}
						acc = mtmerge::mergeTwo(acc, t, spec.phase, accPath, resolved);
						accPath = resolved;
					}
				}
			}
			pending.clear();
			out.push_back(std::move(acc));
		}
		if (!pending.empty()) {
			throw bot::IllegalArgumentException("@Merge 后面没有可归并的纯矩阵表"
				"（出现在 children 序列末尾）：@Merge 必须紧跟一张要并入的表");
		}
		seq = std::move(out);
		for (auto& m : seq) {
			if (m.hasChildren()) { mergeNestedDirectives(m.children(), baseDir); }
		}
	}

private:
	std::string mainBase_;
	std::map<std::string, bool> visited_;	/* resolved 路径 → 是否 include-once 片段 */
	std::size_t totalBytes_ = 0;
	std::size_t rowCount_ = 0;

	/* 处理一层：parsed 的 @Merge 行按声明序展开并并入 acc。
	 * owned 是本层「自己的定义」（主从覆盖判据），调用方在并入前快照。 */
	void runLevel(const std::vector<mt::MatrixObject>& parsed, const std::string& baseDir,
			MergeAcc& acc, const LevelOwned& owned) {
		for (const auto& m : parsed) {
			if (bot::trim(m.getName()) != "Merge") { continue; }
			if (m.rows() == 0) { continue; }	/* 只有名字没有内容的退化块：无事可做 */
			IncludeBlockReader rows(m);
			for (std::int64_t r = 1; r < static_cast<std::int64_t>(m.rows()); ++r) {
				if (++rowCount_ > kMaxIncludes) {
					throw bot::IllegalArgumentException("@Merge declares "
						+ std::to_string(rowCount_ - 1) + " rows before this one,"
						+ " exceeding the limit of " + std::to_string(kMaxIncludes)
						+ " across the whole include tree (each row reads a local file)");
				}
				IncludeRow spec = rows.row(r);	/* 词法校验先于该行 IO */
				ScriptParts parts = expandFile(spec.path, baseDir);
				mergeParts(parts, spec.phase, acc, owned);
			}
		}
	}

	/* 展开一个文件引用（relPath 已词法校验）：visited 表在此实现终止性——
	 * 每个文件至多展开一次；*.once.mt 再触达跳过（注记），普通文件再触达
	 * 报错（抓笔误）。递归深度由行数上限界定（每层嵌套消耗一行）。 */
	ScriptParts expandFile(const std::string& relPath, const std::string& dir) {
		bool once = endsWithOnceSuffix(relPath);
		std::string resolved = dir + "/" + relPath;
		if (visited_.count(resolved) > 0) {
			if (once) {
				std::cerr << "mtinclude: '" << resolved
					<< "' already included, skipped (include-once fragment)" << std::endl;
				return {};
			}
			throw bot::IllegalArgumentException("'" + resolved
				+ "' is included more than once; if it is a shared fragment,"
				" rename it to '*.once.mt' (include-once)");
		}
		visited_[resolved] = once;	/* 入口即标记：自包含/互包含在第二次触达时终止 */

		std::string data = readIncludeFile(resolved, totalBytes_);
		bot::MemoryReader in(std::move(data));
		std::vector<mt::MatrixObject> incParsed;
		mt::readMatrix(in, incParsed);
		if (incParsed.empty()) {
			throw bot::IllegalArgumentException("'" + resolved + "': no matrix found");
		}

		/* 片段层「疑似 @if 块」先行拒绝（判据与理由见 looksLikeIfBlock）：
		 * 响亮报错优于静默丢弃——放进片段的 @if 永远不会执行。嵌套的
		 * 子片段由各自递归的 expandFile 用同一判据检查。 */
		for (const auto& m : incParsed) {
			if (looksLikeIfBlock(m.getName())) {
				throw bot::IllegalArgumentException("@if 块不支持出现在 @Merge 片段 '"
					+ resolved + "' 中：片段的 @Action 按相位归并进主脚本 @Action，"
					"没有独立的执行位置；请把该 @if 块挪到主脚本");
			}
			if (looksLikeWhileBlock(m.getName())) {
				throw bot::IllegalArgumentException("@while 块不支持出现在 @Merge 片段 '"
					+ resolved + "' 中：片段的 @Action 按相位归并进主脚本 @Action，"
					"没有独立的执行位置；请把该 @while 块挪到主脚本");
			}
		}

		/* 片段自成一层：自己的标量/动作是累加器初值，自己的 @Merge 行
		 * （以自身目录为基准）按同一套规则并入。被包含文件可以没有
		 * @Action（纯标量/纯组合片段合法）——整体缺失由派发期报错。 */
		MergeAcc frag;
		frag.aliasPath = resolved;
		frag.varsPath = resolved;
		frag.actionPath = resolved;
		if (auto al = mtmerge::foldNamed(incParsed, "Alias", resolved)) {
			frag.alias = std::move(*al);
		}
		if (auto va = mtmerge::foldNamed(incParsed, "Vars", resolved)) {
			frag.vars = std::move(*va);
		}
		if (auto* act = mt::findByName(incParsed, "Action")) { frag.action = *act; }
		LevelOwned owned = ownedNamesOf(frag);
		runLevel(incParsed, dirOf(resolved), frag, owned);

		return ScriptParts{std::move(frag.alias), std::move(frag.vars),
			std::move(frag.action), resolved};
	}

	/* 子片段的有效产物并入本层累加器：标量走主从覆盖（同层自有定义获胜、
	 * 子片段互相同名报错），动作走设备集不相交归并（相位归属包含行）。 */
	void mergeParts(ScriptParts& parts, std::int64_t phase, MergeAcc& acc,
			const LevelOwned& owned) {
		if (parts.alias) {
			mt::MatrixObject filtered = dropOwnedRows(*parts.alias, owned.alias,
				parts.path, "Alias");
			if (filtered.rows() > 1) {
				if (acc.alias) {
					acc.alias = mtmerge::mergeScalarRows(*acc.alias, filtered, "Alias",
						acc.aliasPath, parts.path);
					acc.aliasPath += "+" + parts.path;
				} else {
					acc.alias = std::move(filtered);
					acc.aliasPath = parts.path;
				}
			}
		}
		if (parts.vars) {
			mt::MatrixObject filtered = dropOwnedRows(*parts.vars, owned.vars,
				parts.path, "Vars");
			if (filtered.rows() > 1) {
				if (acc.vars) {
					acc.vars = mtmerge::mergeScalarRows(*acc.vars, filtered, "Vars",
						acc.varsPath, parts.path);
					acc.varsPath += "+" + parts.path;
				} else {
					acc.vars = std::move(filtered);
					acc.varsPath = parts.path;
				}
			}
		}
		if (parts.action) {
			if (acc.action) {
				acc.action = mtmerge::mergeTwo(*acc.action, *parts.action, phase,
					acc.actionPath, parts.path);
				acc.actionPath += "+" + parts.path;
			} else {
				acc.action = std::move(*parts.action);
				acc.actionPath = parts.path;
			}
		}
	}

	static std::string dirOf(const std::string& resolved) {
		std::size_t slash = resolved.find_last_of('/');
		return slash == std::string::npos ? std::string(".") : resolved.substr(0, slash);
	}
};

} // namespace

void expandIncludes(std::vector<mt::MatrixObject>& parsed, const std::string& baseDir) {
	std::string base = baseDir.empty() ? "." : baseDir;
	while (base.size() > 1 && base.back() == '/') { base.pop_back(); }

	Expander exp(base);

	/* Pass 1：@Include 内容拷贝（顶层专属，递归展开被拷贝内容的 @Include）。
	 * 无 @Include 时逐字不动。 */
	exp.spliceIncludes(parsed, base);

	/* Pass 1a：嵌套 @Merge 位置局部归并——只下钻顶层块的 children（顶层 @Merge
	 * 归 Pass 2 的累加器机制，不在此处理）。消费掉 children 里的 @Merge 块。 */
	for (auto& m : parsed) {
		if (m.hasChildren()) { exp.mergeNestedDirectives(m.children(), base); }
	}

	/* Pass 1b：位置约束——@Include 不允许出现在控制块 children（响亮拒绝）；
	 * 嵌套 @Merge 已在 Pass 1a 消费，此处的 @Merge 分支只是兜底。 */
	for (const auto& m : parsed) { exp.rejectNestedDirectives(m.children()); }

	/* Pass 2：@Merge 归并（fast path：无 @Merge 时逐字不动——既有脚本的解析产物
	 * 原样返回，行为零变化，也保住既有守门对报错文案/时序的全部假设）。 */
	bool hasMerge = false;
	for (const auto& m : parsed) {
		if (bot::trim(m.getName()) == "Merge") { hasMerge = true; break; }
	}
	if (hasMerge) { exp.run(parsed); }
}

} // namespace mtinclude
