# @Merge 归并正例（观察面专段用）：
# 主脚本只有 timer-0，r1 滞后 1 拍、r2 滞后 2 拍——合并后 5 拍时间轴上
# r1 的前导与 r2 的前导两行必须被跳过（不得以 0.0 误发），r1/r2 的全部
# 动作（100/110/200/210/220）都应出现。
# 用法：cat scripts/test/include_main.mt | ./build/mybot --robot=robots/test/include_demo.sql
@Merge
path phase;
  scripts/test/include_a.mt 1;
  scripts/test/include_b.mt 2;
@

@Action
timer-0.delay;
  200;
  200;
@
