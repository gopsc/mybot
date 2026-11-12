# BMM150 无硬件端到端（proto=virt，挂起态电源门/三段 trim NVM/13·15 位
# 数据块器件）：
# 首行 t0 预热 200ms 等守护 setup——真实 build 的 POWER_ON 后 milli_sleep
# 3ms STARTUP 是【真实睡眠】（守护不注入 milli_sleep 桩，虚拟时钟不被推
# 进），200ms 余量充裕；随后 16 拍 ×50ms：pump Ema（引用快照注入，play
# 一次推进一拍 Y 轴滤波）并消费两个 Monitor——mon0 透传守护 raw 快照
# （X/Y/Z µT），monf 输出 eavg 滤波后的 Y 轴。
# 守护 regular/interval=20ms；模型 virt_tick 每拍直接装入一拍地磁原始码
# （X≈30±20、Y≈-12±15、Z≈-42±18µT，RHALL 恒 512），call 单笔 8B burst
# 即有数据、零真实睡眠；一拍对应一个 virt_tick。
# 用法：cat scripts/test/bmm150_virt.mt | ./build/mybot --robot=robots/test/bmm150_virt.sql
@Action
t0.delay  eavg.out  mon0.go  monf.go;
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
