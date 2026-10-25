# SDS011 无硬件端到端（proto=virt，激光 PM2.5/PM10 颗粒物传感器 UART 9600 8N1）：
# 首行 t0 预热 200ms 等守护 uart_open + build（切被动模式 + 读固件版本两条命令、
# 真实驱动 build/call 均零睡眠：无转换门、无 milli_sleep，虚拟 uart_read 即时
# drain，200ms 余量充裕），随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次
# 推进一拍浓度滤波）并消费两个 Monitor——mon0 透传统一守护 raw 两字段快照
# （PM25:f、PM10:f 浮点 µg/m³）与 count，monf 输出 ev 滤波后浓度。
# 守护 interval=20ms，一拍消费间隔内约推进 2~3 个模型点（virt_tick 5 拍一周
# 扬尘爬坡：PM25 10.5→13.7、PM10 16.3→19.5，0.8µg/m³ 步进，raw 码 mod 10 恒非
# 0 ⇒ 每个读数必带一位小数，直接证明 :f 未被取整）。真机 interval 须 >=1s。
# 用法：cat scripts/test/sds011_virt.mt | ./build/mybot --robot=robots/test/sds011_virt.sql
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
