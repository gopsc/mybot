# 主脚本没有 @Action：首个 include 顶替累加器（相位 5 无对齐目标不生效），
# 第二个 include 与它按相位 0 归并——两条 Relay 都应被驱动
@Merge
path phase;
  scripts/test/include_a.mt 5;
  scripts/test/include_b.mt 0;
@
