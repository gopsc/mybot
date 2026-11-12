# BME280 无硬件端到端（proto=virt）：首行 t0 预热 200ms 等守护 setup+首发
# （驱动 build 含 3ms 软复位等待，每拍 call 含真实 5ms 转换等待），随后
# 16 拍 ×50ms：按列序 pump 三个 Ema（引用快照注入，play 一次推进一拍滤波）
# 并消费两个 Monitor——mon0 透传守护三字段 raw 快照与 count，monf 输出 et
# 滤波后 v0（温度 °C）与阈值 level。守护 interval=20ms，一拍消费间隔内约
# 推进 2~3 个波形点。
# 用法：cat scripts/test/bme280_virt.mt | ./build/mybot --robot=robots/test/bme280_virt.sql
@Action
t0.delay  et.out  ep.out  eh.out  mon0.go  monf.go;
   2000       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
    50       -       -       -        -         -    ;
@
