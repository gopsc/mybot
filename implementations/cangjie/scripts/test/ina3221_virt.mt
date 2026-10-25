# INA3221 无硬件端到端（proto=virt，三通道字寻址 16 位寄存器器件）：
# 首行 t0 预热 200ms 等守护 setup（真实 build 含复位睡 10ms + avg16
# 三通道完整转换循环睡 108ms），随后 16 拍 ×50ms：pump Ema（引用快照
# 注入，play 一次推进一拍 V1 滤波）并消费两个 Monitor——mon0 透传守护
# raw 六字段快照（V1/I1/V2/I2/V3/I3）与 count，monf 输出 ev 滤波后
# ch1 母线电压与阈值 level。守护 interval=20ms（call 零睡眠），一拍一拍
# 对应 virt_tick（三通道合成同相正弦：ch1 11.6~12.4V/0.2~0.8A、
# ch2 11.6~12.4V/0.6~1.4A、ch3 4.8~5.2V/0.152~0.448A，32 拍周期，
# build 前预武装，连续模式无转换门）。
# 用法：cat scripts/test/ina3221_virt.mt | bash _run.sh --robot=robots/test/ina3221_virt.sql
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
