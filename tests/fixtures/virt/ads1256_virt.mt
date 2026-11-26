# ADS1256 无硬件端到端（proto=virt，首个 SPI 虚拟器件）：
# 首行 t0 预热 300ms 等守护 setup+首发（真实驱动 build 含 5+5+50ms 等待，
# 每拍 call 含 SYNC 1ms + 转换周期等待，1000SPS 约 2ms），随后 16 拍 ×50ms：
# 按列序 pump Ema（引用快照注入，play 一次推进一拍滤波）并消费两个
# Monitor——mon0 透传守护 raw/voltage 快照与 count，monf 输出 ev 滤波后
# v1（电压 V）与阈值 level。守护 interval=20ms，一拍消费间隔内约推进 2~3
# 个波形点（合成正弦 0.25~2.25V，32 拍周期）。
# 用法：cat scripts/test/ads1256_virt.mt | ./build/mybot --robot=robots/test/ads1256_virt.sql
@Action
t0.delay  ev.out  mon0.go  monf.go;
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
