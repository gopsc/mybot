# AMG8833 无硬件端到端（proto=virt，像素块 burst/帧周期门器件）：
# 首行 t0 预热 200ms 等守护 setup——真实 build 的 RST 后 milli_sleep 5ms
# 与等首帧 milli_sleep 120ms 都是【真实睡眠】（守护不注入 milli_sleep 桩，
# 虚拟时钟不被推进），200ms 余量充裕；随后 16 拍 ×50ms：pump Ema（引用
# 快照注入，play 一次推进一拍 AVGT 滤波）并消费两个 Monitor——mon0 透传
# 守护 raw 聚合快照（MAXT/AVGT/MAXR/MAXC/THERM），monf 输出 eavg 滤波
# 后平均温度。
# 守护 10Hz/interval=20ms；模型 virt_tick 每拍直接装入一拍移动热点热图
# （25°C 背景 + 旋转热点，热敏 30±2°C），call 读 8 个 16B 像素块即有
# 数据、零真实睡眠；一拍对应一个 virt_tick。
# 用法：cat scripts/test/amg8833_virt.mt | bash _run.sh --robot=robots/test/amg8833_virt.sql
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
