# EMC2101 无硬件端到端（proto=virt，智能风扇控制器混合器件）：
# 首行 t0 预热 200ms 等守护 setup——真实驱动 build 零 milli_sleep
# （set+双 ID 读+PWM_F 读+lut_disable RMW+初始占空比写），200ms
# 余量充裕；随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次
# 推进一拍外温滤波）并消费两个 Monitor——mon0 透传守护 raw 快照
# （TEMP_IN 整数 + TEMP_EXT:f/RPM:f 两浮点 + count），monf 输出
# ev 滤波后外温。
# 守护 interval=20ms（连续测量器件，无转换门），一拍对应一次
# virt_tick：32 拍确定性正弦（内温 35±5°C、外温 42±6°C、
# RPM 3000±1200 恒四位数，高温高转反相；build 前预武装拍 0）。
# 用法：cat scripts/test/emc2101_virt.mt | ./build/mybot --robot=robots/test/emc2101_virt.sql
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
