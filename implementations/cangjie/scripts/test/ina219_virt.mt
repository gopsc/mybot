# INA219 无硬件端到端（proto=virt，字寻址 16 位寄存器器件）：
# 首行 t0 预热 200ms 等守护 setup（真实 build 含复位睡 10ms + avg16
# 转换循环睡 20ms），随后 16 拍 ×50ms：pump Ema（引用快照注入，
# play 一次推进一拍 V 滤波）并消费两个 Monitor——mon0 透传守护 raw
# 三字段快照（V/I/P）与 count，monf 输出 ev 滤波后母线电压与阈值 level。
# 守护 interval=20ms（call 零睡眠），一拍一拍对应 virt_tick（合成同相
# 正弦 V 11.6~12.4V、I 0.4~1.6A @R100，32 拍周期，build 前预武装，
# 连续模式无转换门）。
# 用法：cat scripts/test/ina219_virt.mt | bash _run.sh --robot=robots/test/ina219_virt.sql
@Action
t0.delay  ev.out  mon0.go  monf.go;
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
