# MPU6050 无硬件端到端（proto=virt）：首行 t0 预热 200ms 等守护 setup+首发
# （驱动 build 含 100ms milli_sleep），随后 20 拍 ×50ms：
# 按列序 pump 七个 Ema（引用快照注入，play 一次推进一拍滤波）并消费两个
# Monitor——mon0 透传统一守护七字段 raw 快照与 count，monf 输出 eax 滤波后
# v0 与阈值 level。守护 interval=10ms，一拍消费间隔内约推进 5 个波形点。
# 用法：cat scripts/test/mpu_virt.mt | ./build/mybot --robot=robots/test/mpu_virt.sql
@Action
t0.delay  eax.out  eay.out  eaz.out  egx.out  egy.out  egz.out  etmp.out  mon0.go  monf.go;
   2000       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
    50       -        -        -        -        -        -        -         -         -    ;
@
