# LSM6DSV16X 无硬件端到端（proto=virt，双 6 字节小端六轴 IMU）：
# 首行 t0 预热 200ms 等守护 setup+首发（真实 build 实睡 110ms：
# 软复位首拍轮询 10ms + 陀螺仪起转 100ms，200ms 余量充裕），随后
# 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍 ACCEL_X
# 滤波）并消费两个 Monitor——mon0 透传统一守护 raw 六字段快照
#（ACCEL_X/Y/Z 与 GYRO_X/Y/Z 均为 sign='16' 展开的有符号整数码）
# 与 count，monf 输出 ei 滤波后 v0。守护 interval=50ms（call 零睡眠），
# 一拍即一个 virt_tick：32 拍周期六轴正弦（X 100~500、Y -350~-50、
# Z 3998~4198 ≈1g；GYR ±500/±400/±300）。
# 用法：cat scripts/test/lsm6dsv_virt.mt | ./build/mybot --robot=robots/test/lsm6dsv_virt.sql
@Action
t0.delay  ei.out  mon0.go  monf.go;
   2000       -        -         -    ;
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
