# MT6826S 无硬件端到端（proto=virt，15 位磁编码器 SPI Mode3）：
# 首行 t0 预热 200ms 等守护 setup+首发（真实驱动 build/call 均零睡眠：
# 无转换门、无 milli_sleep，200ms 余量充裕），随后 16 拍 ×50ms：
# pump Ema（引用快照注入，play 一次推进一拍角度滤波）并消费两个
# Monitor——mon0 透传统一守护 raw 四字段快照（ANGLE:f 度数、RAW 15 位
# 码、STATUS、CRC_OK）与 count，monf 输出 ev 滤波后角度。守护
# interval=20ms，一拍消费间隔内约推进 2~3 个模型点（virt_tick 32 拍
# 线性爬坡 0~348.75°，11.25° 步进）。
# 用法：cat scripts/test/mt6826s_virt.mt | ./build/mybot --robot=robots/test/mt6826s_virt.sql
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
