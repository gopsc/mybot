# AS7262 无硬件端到端（proto=virt，硬件 3 寄存器+虚拟间接窗口/握手器件）：
# 首行 t0 预热 1200ms 等守护 setup——真实 build 的 RST 位后 milli_sleep
# 1000ms 是【真实睡眠】（守护不注入 milli_sleep 桩，虚拟时钟不被推进），
# 预热必须留足；随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次
# 推进一拍 V 通道计数滤波）并消费两个 Monitor——mon0 透传守护 raw
# 六通道计数快照与 count，monf 输出 ev 滤波后 V 计数与阈值 level。
# 守护 GAIN=16x / integ=50（连续全通道一轮约 280ms）；模型 virt_tick
# 每拍造六通道正弦计数（V 9000±3000，32 拍周期）并预武装 DATA_RDY，
# call 首读 CONTROL 即就绪、零真实睡眠；一拍对应一个 virt_tick。
# 用法：cat scripts/test/as7262_virt.mt | ./build/mybot --robot=robots/test/as7262_virt.sql
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
