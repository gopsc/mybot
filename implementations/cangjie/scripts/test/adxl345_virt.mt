# ADXL345 无硬件端到端（proto=virt，小端三轴 IMU）：
# 首行 t0 预热 200ms 等守护 setup+首发（build 含 22ms 等两个测量周期睡眠，
# 余量充裕），随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍
# ACCEL_X 滤波）并消费两个 Monitor——mon0 透传统一守护 raw 三字段快照
#（ACCEL_X/Y/Z 均为 sign='16' 展开的有符号整数码）与 count，monf 输出
# eax 滤波后 v0 与阈值 level。守护 interval=20ms（call 零睡眠），一拍消费
# 间隔内约推进 2~3 个 virt_tick 波形点（32 拍周期三轴正弦，X/Y ±0.30g、
# Z 带 1g 重力偏置）。
# 用法：cat scripts/test/adxl345_virt.mt | bash _run.sh --robot=robots/test/adxl345_virt.sql
@Action
t0.delay  eax.out  mon0.go  monf.go;
   200       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
    50       -        -         -    ;
@
