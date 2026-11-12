# APDS-9900 无硬件端到端（proto=virt，环境光 ALS + 近距 PROX）：
# 首行 t0 预热 200ms 等守护 setup——真实驱动 build/call 全程零
# milli_sleep，200ms 余量充裕；随后 16 拍 ×50ms：pump Ema（引用
# 快照注入，play 一次推进一拍 LUX 滤波）并消费两个 Monitor——mon0
# 透传守护 raw 四字段快照（LUX/CH0/CH1/PROX）与 count，monf 输出
# ev 滤波后照度与阈值 level。守护 interval=20ms（call 零睡眠），
# 一拍对应一次 virt_tick（CH0 6000~14000 同相正弦、32 拍周期，
# build 前预武装；LUX 约 1354~3160 lux）。
# 用法：cat scripts/test/apds9900_virt.mt | ./build/mybot --robot=robots/test/apds9900_virt.sql
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
