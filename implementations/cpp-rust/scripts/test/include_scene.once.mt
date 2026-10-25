# 组合片段（include-once）：没有自有 @Action，只做归并编排。
# 注意片段的 @Merge 以【自身所在目录】为基准（可整体搬移），
# 与主脚本的通道基准（stdin=CWD）不同。
@Merge
path;
  include_a.mt;
  include_b.mt;
@
