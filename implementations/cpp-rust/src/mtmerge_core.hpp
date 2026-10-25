#pragma once
/* mtmerge_core.hpp —— .mt 动作脚本归并核心（F1/N-30：从 mtmerge.cpp 抽出，独立可测）
 *
 * 这些函数此前是 mtmerge.cpp 匿名命名空间里的私有实现：mtmerge 是唯一有独立
 * 编译目标却零白盒单测的模块，归并算法/相位补 "-"/列头校验只能靠 shell 黑盒
 * 间接覆盖（N-30）。抽出后 mtmerge（可执行）与 mybot_tests（白盒单测）共用
 * 同一份实现，单测编译的正是发布二进制里跑的那套逻辑。
 * 只依赖 matrix/util，不触碰 LuaJIT。
 */

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "matrix.hpp"

namespace mtmerge {

/* 相位合法范围（±10 万行）：相位参与输出行数计算（rowsNext + phase，曾有
 * 有符号溢出 UB）与逐行循环，无界值会把产物撑到无界内存；语义上相位是
 * 「滞后/提前行数」，10 万行已是极端值。mtmerge 的 --phase 与动作脚本
 * @Merge 的 phase 列共用本界（单一事实源，两入口不得漂移）。 */
inline constexpr std::int64_t kMaxPhase = 100000;

/* ---- 产物预算（2026-09-21 第七轮审计）----
 * @Merge / mtmerge 的**输入侧**已有三道限（@Merge/@Include 行数 ≤ kMaxIncludes=32、
 * 字节总量 ≤ 8 MiB、|phase| ≤ kMaxPhase），但**产物侧一条都没有**：
 * 产物行数 = max(rowsAcc, rowsNext + phase)、列数随包含数线性增长，于是几十字节的
 * 动作脚本写一行 `@Merge path=..., phase=100000` 就能把终态撑到 ~1e5 行 × 数十列
 * ≈ 数百万单元格（数百 MB 量级）——树莓派上直接 OOM，而 OOM 是 SIGKILL 语义，
 * `deactivate()` 整体被跳过，正是「断电是生命周期不变式」要防的那个后果。
 * 判据放在 mergeTwo（两两归并的单点），mtmerge 工具与 mybot 的 @Merge 展开
 * 共用，因此累积放大在**第一次越限的那次归并**上就被拦住，不会先吃掉内存再报错。
 * 取值给真实用量留了两个数量级以上的余量：仓库内 195 个 .mt 实测最多 200 数据行、
 * 20 列、760 单元格。 */
inline constexpr std::int64_t kMaxMergedRows = 20000;
inline constexpr std::int64_t kMaxMergedCells = 200000;

/* @Action：找到列头即最终形态（别名替换由 mybot 在装配期完成）。找不到即报错。 */
const mt::MatrixObject& requireAction(const std::vector<mt::MatrixObject>& parsed,
		const std::string& path);

/* @Alias / @Vars：按行叠加（不含相位）。列头必须完全一致；name 列（首个名为
 * 'name' 的列）出现同名行即报错——同一名字不能映射到两个不同的值/别名。 */
mt::MatrixObject mergeScalarRows(const mt::MatrixObject& acc, const mt::MatrixObject& next,
		const std::string& label, const std::string& pa, const std::string& pb);

/* 收集同一输入内所有 <name> 矩阵并按行叠加（一个 .mt 里可以出现多个 @Alias/@Vars
 * 块，mybot 会全部注册；mtmerge 不能只看第一个而静默丢掉其余块）。 */
std::optional<mt::MatrixObject> foldNamed(const std::vector<mt::MatrixObject>& parsed,
		const std::string& name, const std::string& path);

/* 校验设备集不相交：相交即抛，指明冲突设备与两侧列头（装配期静态可判，
 * 不静默串行化——把竞态伪装成功能是本项目一贯拒绝的行为）。 */
void checkDisjoint(const mt::MatrixObject& a, const mt::MatrixObject& b,
		const std::string& pa, const std::string& pb);

/* 一次两两归并：acc（已合并结果）与 next 合成新矩阵。
 * 相位 p>0 表示 next 整体滞后 p 行；数据行 1-based：
 *   acc 行取 r，next 行取 r - p；越界（<1 或 >行数）填 "-"。
 * 总行数 = max(acc 行数, next 行数 + p)（数据行，不含表头）。
 * 负相位把 next 开头 |p| 行移出输出窗口：部分丢弃在 stderr 告警，
 * 全部丢弃抛异常（拒绝静默丢动作）。 */
mt::MatrixObject mergeTwo(const mt::MatrixObject& acc, const mt::MatrixObject& next,
		std::int64_t phase, const std::string& pa, const std::string& pb);

} // namespace mtmerge
