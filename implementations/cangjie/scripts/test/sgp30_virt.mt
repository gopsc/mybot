# SGP30 无硬件端到端（proto=virt，16 位命令字+CRC-8/载荷命令式器件）：
# 首行 t0 预热 400ms 等守护 setup（真实 build 含 Measure_test 222ms +
# Init 12ms 真实睡眠），随后 16 拍 ×50ms：pump Ema（引用快照注入，
# play 一次推进一拍 CO2 滤波）并消费两个 Monitor——mon0 透传守护 raw
# 三字段快照与 count，monf 输出 ec 滤波后 CO2eq（ppm）与阈值 level。
# 守护 interval=50ms（call 内含 14ms 测量真实等待），一拍一拍对应
# virt_tick（合成正弦 CO2eq 400~700ppm、TVOC 40~200ppb，32 拍周期，
# warm 已度过 15s 启动相、预武装零转换等待）。
# 用法：cat scripts/test/sgp30_virt.mt | bash _run.sh --robot=robots/test/sgp30_virt.sql
@Action
t0.delay  ec.out  mon0.go  monf.go;
   400       -        -         -    ;
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
