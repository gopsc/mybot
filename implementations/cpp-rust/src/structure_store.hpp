#pragma once
/* structure_store.hpp —— 结构矩阵域（拆自 RobotStruct 私有容器，2026-10-03 阶段 4）
 *
 * 结构脚本解析出的矩阵表（声明序）此前以 RobotStruct::matrices_ 私有成员存在，
 * 而装配/热插/热删除/agent 视图四条路径都在 RobotStruct 内部直接读写它——跨域
 * 耦合点。本类把「结构矩阵域」收敛成一个门面：谁要碰结构表，一律经这里的方法，
 * RobotStruct 不再直接持有容器。
 *
 * 容器选型是**不变式**而非风格（2026-09-23 热插表）：MetaProvider 持指向此处
 * 元素的引用（matrix_），std::vector 在 append 扩容时会让全部旧引用悬垂；
 * std::deque 的 push_back/push_front 只失效迭代器，**元素引用保持有效**，
 * 故热插表可以在 active() 之后安全追加。此不变式保存在本类内部——引用稳定性
 * 的构造基础（deque）与依赖它的元数据域（MetaRegistry）分属两个门面，边界清晰。
 */

#include <cstddef>
#include <deque>
#include <string>
#include <vector>

#include "matrix.hpp"
#include "script_loader.hpp"

namespace bot {

class StructureStore {
public:
	/* 装载：结构 SQL 文本 → 声明序矩阵表（构造期唯一入口） */
	void load(bot::Reader& input) { ScriptLoader::readSQL(input, tables_); }

	/* 追加一张新表（整表声明：热插 CREATE、injectLuaDriver 合成表）。
	 * push_back 不影响既有元素引用——MetaProvider::matrix_ 的不变式见头注释。 */
	void append(mt::MatrixObject table) { tables_.push_back(std::move(table)); }
	const mt::MatrixObject& back() const { return tables_.back(); }

	/* 既有表追加数据行（矩阵是装配的输入），返回**首个新行的行号**（fromRow），
	 * 供装配方做增量 build。取值必须在追加之前——故由本方法内部先取再追加。 */
	std::int64_t appendRows(std::size_t idx, const std::vector<std::vector<std::string>>& rows) {
		mt::MatrixObject& t = tables_[idx];
		const std::int64_t from = static_cast<std::int64_t>(t.rows());
		for (const auto& row : rows) { t.appendRow(row, static_cast<std::int64_t>(t.rows())); }
		return from;
	}

	/* 回滚：丢弃尾部 count 行（热插批次失败，只给回滚路径用） */
	void popRows(std::size_t idx, std::size_t count) { tables_[idx].popRows(count); }

	/* 热删除：按原始行号擦除（保序，存活行相对顺序不动——销毁序不变式） */
	void removeRows(std::size_t idx, const std::vector<std::size_t>& rows) {
		tables_[idx].removeRows(rows);
	}

	/* 回滚：把本批次新增的整表退回（尾部截断） */
	void truncate(std::size_t n) { tables_.resize(n); }

	/* 整表撤下（DROP TABLE）：按下标摘除表壳 */
	void eraseTable(std::size_t idx) {
		tables_.erase(tables_.begin() + static_cast<std::ptrdiff_t>(idx));
	}

	std::size_t size() const { return tables_.size(); }
	bool empty() const { return tables_.empty(); }

	mt::MatrixObject& at(std::size_t idx) { return tables_[idx]; }
	const mt::MatrixObject& at(std::size_t idx) const { return tables_[idx]; }

	/* 按表名查找（trim 比较），不存在返回 nullptr。规则由 mt::findByName 单点。 */
	mt::MatrixObject* find(const std::string& name) { return mt::findByName(tables_, name); }
	const mt::MatrixObject* find(const std::string& name) const {
		return mt::findByName(tables_, name);
	}

	/* 结构脚本是否已声明名为 name 的变量（原 RobotStruct::declaresVariable，
	 * 2026-10-03 阶段 4 随公开访问面门面化迁入本域）。必须在 active() **之前**
	 * 可判定，故直接扫矩阵表的 name 列，而不是查注册表（注册表要 active() 里
	 * createHardVars 才装配）。agent 模式的摄像头/协议驱动存在性判据。 */
	bool declaresVariable(const std::string& name) const {
		for (const auto& table : tables_) {
			const std::int64_t idx = table.indexOfCol(0, "name");
			if (idx < 0) { continue; }
			for (std::int64_t i = 1; i < static_cast<std::int64_t>(table.rows()); ++i) {
				if (trim(table(i, idx)) == name) { return true; }
			}
		}
		return false;
	}

	/* 声明序只读视图：agent 视图取数（/sql 查询）与一致性自检遍历共用。
	 * 这是**读视图**，不是所有权移交——写操作仍须经本类方法。 */
	const std::deque<mt::MatrixObject>& all() const { return tables_; }

private:
	std::deque<mt::MatrixObject> tables_;
};

} // namespace bot