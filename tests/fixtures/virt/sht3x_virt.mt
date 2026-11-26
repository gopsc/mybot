# SHT3X 无硬件端到端（proto=virt，首个 16 位命令字 + CRC-8 命令式器件）：
# 首行 t0 预热 300ms 等守护 setup（真实 build 仅软复位 2+1ms 真实睡眠，
# 状态读首次即有数据），随后 16 拍 ×50ms：pump Ema（引用快照注入，
# play 一次推进一拍温度滤波）并消费两个 Monitor——mon0 透传守护 raw
# 三字段快照与 count，monf 输出 et 滤波后 T（°C）与阈值 level。
# 守护 interval=50ms（call 内含 16ms 高重复性转换真实等待），一拍一拍
# 对应 virt_tick（合成正弦 T 20~30°C、RH 30~70%，32 拍周期）。
# 用法：cat scripts/test/sht3x_virt.mt | ./build/mybot --robot=robots/test/sht3x_virt.sql
@Action
t0.delay  et.out  mon0.go  monf.go;
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
