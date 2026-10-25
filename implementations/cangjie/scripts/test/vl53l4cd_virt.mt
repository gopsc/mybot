# VL53L4CD 无硬件端到端（proto=virt，首个 16 位指针 ptr16 I2C 器件）：
# 首行 t0 预热 300ms 等守护 setup（真实驱动 build 含 91 字节配置流与
# SetRangeTiming 编码，但 virt_tick 预武装使 VHV/首测量轮询首次即就绪，
# 仅软复位 1+5ms 真实睡眠），随后 16 拍 ×50ms：pump Ema（引用快照注入，
# play 一次推进一拍距离滤波）并消费两个 Monitor——mon0 透传守护 raw
# 四字段快照与 count，monf 输出 ed 滤波后 v0（距离 mm）与阈值 level。
# 守护 interval=20ms，一拍消费间隔内约推进 2 个波形点
#（合成正弦 100~1100mm，32 拍周期）。
# 用法：cat scripts/test/vl53l4cd_virt.mt | bash _run.sh --robot=robots/test/vl53l4cd_virt.sql
@Action
t0.delay  ed.out  mon0.go  monf.go;
   300       -        -         -    ;
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
