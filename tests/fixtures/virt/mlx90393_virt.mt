# MLX90393 无硬件端到端（proto=virt，三轴磁力计）：
# 首行 t0 预热 200ms 等守护 setup——真实驱动 build 约 8ms milli_sleep
# （RT 5ms + HR 2ms + 预武装试测轮询 1ms），200ms 余量充裕；随后
# 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍 X 轴滤波）
# 并消费两个 Monitor——mon0 透传守护 raw 快照（X/Y/Z µT、T °C +
# XR/YR/ZR/TR/status 与 count），monf 输出 ev 滤波后 X 磁场与阈值
# level。守护 interval=20ms（call 预武装下仅 1ms 睡眠），一拍对应一次
# virt_tick（X ±30µT 正弦含负值、32 拍周期，build 前预武装）。
# 用法：cat scripts/test/mlx90393_virt.mt | ./build/mybot --robot=robots/test/mlx90393_virt.sql
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
