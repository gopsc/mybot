# PCF8574 无硬件端到端（proto=virt，无寄存器图 P 口 IO 扩展器）：
# 首行 t0 预热 200ms 等守护 setup——真实 build 无 milli_sleep（纯读在位
# + 1B 锁存写），200ms 余量充裕；随后 16 拍 ×50ms：pump Ema（引用快照
# 注入，play 一次推进一拍 PINS 滤波）并消费两个 Monitor——mon0 透传守护
# raw 快照（PINS/OUT），monf 输出 eavg 滤波后的引脚码。
# 守护 interval=20ms；模型 virt_tick 每拍把外部拉低掩码置为 walking
# 低电平位（8 拍周期：PINS 254/253/251/247/239/223/191/127），纯读
# call 零真实睡眠；一拍对应一个 virt_tick。
# 用法：cat scripts/test/pcf8574_virt.mt | bash _run.sh --robot=robots/test/pcf8574_virt.sql
@Action
t0.delay  eavg.out  mon0.go  monf.go;
   200       -        -         -    ;
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
