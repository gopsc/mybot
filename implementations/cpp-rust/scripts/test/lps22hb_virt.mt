# LPS22HB 无硬件端到端（proto=virt，小端 24 位气压 + 16 位温度气压计）：
# 首行 t0 预热 200ms 等守护 setup+首发（build 前 virt_tick(0) 预武装，
# SWRESET/ONE_SHOT 即时完成，build/call 均零真实睡眠，余量充裕），随后
# 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍气压滤波）并消费
# 两个 Monitor——mon0 透传统一守护 raw 两字段快照（P/T 均为 :f 浮点：
# P 1008.25~1018.25hPa、T 20~24°C 同相正弦）与 count，monf 输出 ebp
# 滤波后 v0 与阈值 level。守护 interval=50ms（武装 call 零睡眠），一拍
# 消费间隔内约推进 1 个 virt_tick 波形点（32 拍周期正弦）。
# 用法：cat scripts/test/lps22hb_virt.mt | ./build/mybot --robot=robots/test/lps22hb_virt.sql
@Action
t0.delay  ebp.out  mon0.go  monf.go;
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
