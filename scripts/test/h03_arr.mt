# H-03 修复验证：h03 驱动 call 一次，打印应含 values_n=4 / values_sum / list=[10,20,30]
# 单行动作：t0.delay=200ms 先暖机（等 arr_src 守护首发，规避首发竞态），再读 h03
# 注意列间以 ";" 分块，占位符 "-" 语义是继承上一行而非跳过，故 h03 仅放本行
@Action
t0.delay  h03.test;
   200       -     ;
@