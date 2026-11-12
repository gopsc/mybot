/* mtmerge_core.cpp —— 归并核心实现（从 mtmerge.cpp 匿名命名空间原样搬出，
 * 逻辑零改动；F1/N-30 使其可被 test/cpp/test_mtmerge.cpp 白盒覆盖）。 */

#include "mtmerge_core.hpp"

#include <algorithm>
#include <iostream>
#include <map>
#include <set>
#include <utility>

#include "util_except.hpp"
#include "util_str.hpp"

namespace mtmerge {

const mt::MatrixObject& requireAction(const std::vector<mt::MatrixObject>& parsed,
		const std::string& path) {
	const mt::MatrixObject* act = mt::findByName(parsed, "Action");
	if (act == nullptr) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			"'", path, "': no @Action matrix found"));
	}
	return *act;
}

mt::MatrixObject mergeScalarRows(const mt::MatrixObject& acc, const mt::MatrixObject& next,
		const std::string& label, const std::string& pa, const std::string& pb) {
	if (acc.cols() != next.cols()) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			label, " matrix column count differs: '", pa, "' has ", std::to_string(acc.cols()), ", '", pb, "' has ",
			std::to_string(next.cols())));
	}
	for (std::size_t j = 0; j < acc.cols(); ++j) {
		if (acc(0, j) != next(0, j)) {
			throw bot::IllegalArgumentException(bot::concatMsg(label,
				" matrix header differs at column ", std::to_string(j), ": '",
				acc(0, j), "' (", pa, ") vs '", next(0, j), "' (", pb, ")"));
		}
	}
	std::int64_t idxName = acc.indexOfCol(0, "name");
	if (idxName < 0) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			label, " matrix has no 'name' column"));
	}

	mt::MatrixBuilder b;
	b.name(acc.getName());
	for (std::size_t j = 0; j < acc.cols(); ++j) { b.item(acc(0, j)); }
	b.line(0);

	std::set<std::string> seen;
	auto appendRows = [&](const mt::MatrixObject& m) {
		for (std::int64_t r = 1; r < static_cast<std::int64_t>(m.rows()); ++r) {
			const std::string& name = m(r, idxName);
			if (!seen.insert(name).second) {
				throw bot::IllegalArgumentException(bot::concatMsg("duplicate ", label,
					" name '", name, "' (merging '", pa, "' and '", pb,
					"'; names must be unique",
					" across merged scripts)"));
			}
			for (std::size_t j = 0; j < m.cols(); ++j) {
				b.item(m(static_cast<std::size_t>(r), j));
			}
			b.line(0);
		}
	};
	appendRows(acc);
	appendRows(next);
	return b.take();
}

std::optional<mt::MatrixObject> foldNamed(const std::vector<mt::MatrixObject>& parsed,
		const std::string& name, const std::string& path) {
	std::optional<mt::MatrixObject> acc;
	for (const auto& m : parsed) {
		if (bot::trim(m.getName()) != name) { continue; }
		if (!acc) {
			acc = m;
		} else {
			acc = mergeScalarRows(*acc, m, name, path, path);
		}
	}
	return acc;
}

void checkDisjoint(const mt::MatrixObject& a, const mt::MatrixObject& b,
		const std::string& pa, const std::string& pb) {
	std::map<std::string, std::string> seen;	/* device -> 首个列头原文 */
	for (std::size_t j = 0; j < a.cols(); ++j) {
		auto [dev, param] = mt::splitActionColumn(a(0, j));
		seen.emplace(dev, a(0, j));
	}
	for (std::size_t j = 0; j < b.cols(); ++j) {
		auto [dev, param] = mt::splitActionColumn(b(0, j));
		auto it = seen.find(dev);
		if (it != seen.end()) {
			throw bot::IllegalArgumentException(bot::concatMsg("device '", dev,
				"' appears in both scripts: '", it->second, "' (", pa, ") and '",
				b(0, j), "' (", pb, ")"));
		}
	}
}

mt::MatrixObject mergeTwo(const mt::MatrixObject& acc, const mt::MatrixObject& next,
		std::int64_t phase, const std::string& pa, const std::string& pb) {
	/* 归并 ⟂ 嵌套（2026-10-12 @块嵌套）：归并操作数必须是纯矩阵叶子表。控制块
	 * （@if/@while）自身网格为空、体在 children——把它当归并操作数没有意义
	 * （相位补 "-" 按网格行走，空网格会被静默合并、children 被丢弃）。响亮拒绝，
	 * 与「设备集相交报错」同一严格风格：归并与嵌套是两条正交的能力，不得混用。 */
	if (acc.hasChildren() || next.hasChildren()) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			"cannot merge a control block (@if/@while) as a matrix operand: '",
			acc.hasChildren() ? pa : pb,
			"' carries nested sub-blocks; @Merge operands must be plain .mt matrix"
			" tables (nesting and merging are orthogonal)"));
	}
	checkDisjoint(acc, next, pa, pb);

	mt::MatrixObject out;
	/* 列 = acc 全列（原序） ∪ next 全列（原序）；表头行照抄 */
	mt::MatrixBuilder b;
	b.name(acc.getName());
	for (std::size_t j = 0; j < acc.cols(); ++j) { b.item(acc(0, j)); }
	for (std::size_t j = 0; j < next.cols(); ++j) { b.item(next(0, j)); }
	b.line(0);

	const std::int64_t rowsAcc = static_cast<std::int64_t>(acc.rows()) - 1;	/* 去表头 */
	const std::int64_t rowsNext = static_cast<std::int64_t>(next.rows()) - 1;

	/* 负相位把 next 整体上移：其开头 |phase| 行落到输出窗口之外而被丢弃。
	 * 部分丢弃只告警（产物仍含该输入的其余动作）；**全部**丢弃则报错退出 2
	 * （N-8）：产物不含该输入的任何动作、脚本管道化后警告必被淹没——与
	 * 「设备集相交报错退出 2」同一严格风格，拒绝静默丢动作。 */
	if (phase < 0) {
		const std::int64_t dropped = std::min(-phase, rowsNext);
		if (dropped == rowsNext && rowsNext > 0) {
			throw bot::IllegalArgumentException(bot::concatMsg(
				"phase ", std::to_string(phase), " drops all ", std::to_string(rowsNext), " row(s) of '", pb,
				"' (the merged output would contain no action from this input);", " use a smaller negative phase"));
		}
		if (dropped > 0) {
			std::cerr << "mtmerge: 警告：相位 " << phase << " 使 '" << pb << "' 的前 "
				<< dropped << " 行被丢弃" << std::endl;
		}
	}

	const std::int64_t total = std::max(rowsAcc, rowsNext + phase);
	/* 产物预算（判据与取值理由见 mtmerge_core.hpp 的 kMaxMerged*）：必须在**写任何
	 * 一行之前**判，否则内存先被吃掉、报错反而可能来不及产生（OOM 是 SIGKILL 语义，
	 * 会连 deactivate 一起跳过）。行数判据排在乘法之前：既让 int64 乘法不可能溢出
	 * （total 已被夹住），也让报错指向真正的成因（相位过大 vs 列太宽）。 */
	const std::int64_t outCols = static_cast<std::int64_t>(acc.cols() + next.cols());
	if (total > kMaxMergedRows) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			"merged output of '", pa, "' + '", pb, "' would have ", std::to_string(total),
			" row(s), exceeding the limit of ", std::to_string(kMaxMergedRows), " (phase ", std::to_string(phase),
			" alone contributes ", std::to_string(rowsNext + phase), "); reduce the phase or split the action script"));
	}
	const std::int64_t cells = total * outCols;
	if (cells > kMaxMergedCells) {
		throw bot::IllegalArgumentException(bot::concatMsg(
			"merged output of '", pa, "' + '", pb, "' would have ", std::to_string(cells), " cell(s) (",
			std::to_string(total), " rows x ", std::to_string(outCols), " cols), exceeding the limit of ",
			std::to_string(kMaxMergedCells), "; split the action script or reduce the number of @Merge fragments"));
	}
	for (std::int64_t r = 1; r <= total; ++r) {
		/* acc 侧：r 恒在 [1, rowsAcc] 内当 r<=rowsAcc，否则补 "-" */
		if (r <= rowsAcc) {
			for (std::size_t j = 0; j < acc.cols(); ++j) {
				b.item(acc(static_cast<std::size_t>(r), j));
			}
		} else {
			for (std::size_t j = 0; j < acc.cols(); ++j) { b.item("-"); }
		}
		/* next 侧：行号 r - phase，越界补 "-"（开头未起拍 / 结尾已耗尽） */
		std::int64_t rn = r - phase;
		if (rn >= 1 && rn <= rowsNext) {
			for (std::size_t j = 0; j < next.cols(); ++j) {
				b.item(next(static_cast<std::size_t>(rn), j));
			}
		} else {
			for (std::size_t j = 0; j < next.cols(); ++j) { b.item("-"); }
		}
		b.line(0);
	}
	return b.take();
}

} // namespace mtmerge
