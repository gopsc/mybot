# MS5611 无硬件端到端（proto=virt，首个通道+OSR 命令字/指针读/CRC4 器件）：
# 首行 t0 预热 300ms 等守护 setup（真实 build 软复位睡 3ms + 八字 PROM
# 指针读与 CRC-4 校验），随后 16 拍 ×50ms：pump Ema（引用快照注入，
# play 一次推进一拍气压滤波）并消费两个 Monitor——mon0 透传守护 raw
# P_HPA/T_C/ALT_M 三字段快照与 count，monf 输出 ep 滤波后气压（hPa）
# 与阈值 level。
# 守护 OSR4096（call 内 D1/D2 双段各 10ms 真实等待，共 20ms），
# interval=50ms 容纳；模型 virt_tick 预武装使转换门不门控，一拍对应
# 一个 virt_tick（合成正弦 P 1013.25±5hPa、T 22±2°C，32 拍周期）。
# 用法：cat scripts/test/ms5611_virt.mt | bash _run.sh --robot=robots/test/ms5611_virt.sql
@Action
t0.delay  ep.out  mon0.go  monf.go;
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
