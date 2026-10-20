# MH-Z19B 无硬件端到端（proto=virt，NDIR CO₂ 传感器 UART 9600 8N1）：
# 首行 t0 预热 200ms 等守护 uart_open+首发（真实驱动 build/call 均零睡眠：
# 无转换门、无 milli_sleep，虚拟 uart_read 即时 drain，200ms 余量充裕），
# 随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍浓度滤波）
# 并消费两个 Monitor——mon0 透传统一守护 raw 三字段快照（CO2:f 整数 ppm、
# TEMP 近似摄氏度、S 状态字节）与 count，monf 输出 ev 滤波后浓度（带小数
# 即证明 :f 未被取整）。守护 interval=20ms，一拍消费间隔内约推进 2~3 个
# 模型点（virt_tick 32 拍一周爬坡 400~4368ppm，128ppm 步进）。
# 用法：cat scripts/test/mhz19_virt.mt | ./build/mybot --robot=robots/test/mhz19_virt.sql
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
