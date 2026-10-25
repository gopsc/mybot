#pragma once
/* mtinclude.hpp —— .mt 动作脚本 @Merge 展开（运行端动作脚本合并，v2：嵌套与复用）
 *
 * 归并内核复用 mtmerge_core（设备集相交/相位补 "-"/同名行报错与离线合成器
 * mtmerge 同源不漂移）。本模块在其上叠加三件运行端语义：
 *
 *  1) 嵌套合法：片段可再包含片段。终止性由「已展开文件表」（visited 集）保证
 *     ——每个文件至多展开一次，环/自包含在第二次触达时终止。
 *  2) include-once：*.once.mt 后缀的文件是「可复用片段」——被再次包含时
 *     跳过并打 stderr 注记（菱形依赖就此可表达）；普通 .mt 重复包含仍报错
 *     （抓笔误：同名不同物才是要拦的，同文件再包含是共享意图，但意图必须
 *     用后缀显式声明）。
 *  3) 主从覆盖：同名 @Alias/@Vars 行「更靠近主脚本的定义获胜」——主脚本覆盖
 *     片段、上层片段覆盖下层片段（stderr 注记）；片段互相之间同名仍报错。
 *     这是片段参数化的值通道：片段用 $(...) 单元格引用旋钮，主脚本改旋钮值。
 *
 * 基准目录：主脚本按输入通道取「脚本集合根」（--input=脚本所在目录、
 * agent=--scripts-dir、stdin/TCP=CWD）；片段以**自身所在目录**为基准
 * （库片段可整体搬移，不硬编码自己相对根的位置）。
 *
 * 预算与防线：@Merge 行数 ≤ kMaxIncludes（全树累计，同时界定递归深度）、
 * 字节总量 ≤ 8 MiB（kMaxScriptBytes）、单文件 ≤ 8 MiB；行级词法校验先于
 * 该行 IO；O_NOFOLLOW 拒绝软链。被包含文件可以没有 @Action（纯标量/纯组合
 * 片段合法）；整体没有 @Action 时由派发期报错（"No @Action matrix found"）。
 *
 * 只依赖 matrix / mtmerge_core / actionsource 头，不触碰 LuaJIT。
 */

#include <cstddef>
#include <string>
#include <vector>

#include "matrix.hpp"

namespace mtinclude {

/* @Merge 数据行数上限（全树累计）：每行触发一次本地文件读取，无界行数
 * 等价于「远端下发的脚本扇出读盘」（--tcp 通道的信任边界，见 docs/dsl.md）。
 * 该上限同时界定展开次数与递归深度——每层嵌套消耗一行，故无需独立的
 * 深度护栏（visited 集保证终止，行数上限保证栈有界）。 */
inline constexpr std::size_t kMaxIncludes = 32;

/* 展开主脚本矩阵中的全部 @Merge（原地替换 parsed）：
 *   - 无 @Merge 时逐字不动（fast path，既有脚本行为零变化）；
 *   - @Action 按设备集不相交两两归并（相位、负相位契约同 mtmerge）；
 *   - @Alias/@Vars 同名行按主从覆盖（见上），片段间同名报错；
 *   - 普通文件重复包含报错，*.once.mt 重复包含跳过。
 * 路径相对基准目录解析（主脚本按通道、片段按自身目录），词法规则见实现处。 */
void expandIncludes(std::vector<mt::MatrixObject>& parsed, const std::string& baseDir);

} // namespace mtinclude
