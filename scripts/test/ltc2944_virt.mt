# LTC2944 无硬件端到端（proto=virt，字节指针+16 位大端对模 26 器件）：
# 首行 t0 预热 200ms 等守护 setup（build/call 均零 milli_sleep，余量充裕），
# 随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍 V 滤波）
# 并消费两个 Monitor——mon0 透传守护 raw 四字段快照（CHARGE/V/I/T）与
# count，monf 输出 eavg 滤波后母线电压与阈值 level。
# 守护 interval=20ms（call 零睡眠），一拍多 tick 推进 virt_tick（合成同相
# 正弦 V 11.6~12.4V、I 0.4~1.2A @50mΩ、T 25~35°C，32 拍周期；累计电荷
# 200code/拍单调爬坡，build 前预武装，连续模式无转换门）。
# 用法：cat scripts/test/ltc2944_virt.mt | ./build/mybot --robot=robots/test/ltc2944_virt.sql
@Action
t0.delay  eavg.out  mon0.go  monf.go;
   2000       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
@
