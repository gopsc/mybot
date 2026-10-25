# MAX30102 无硬件端到端（proto=virt，环形 FIFO/rollover/18 位流口器件）：
# 首行 t0 预热 200ms 等守护 setup——真实 build 的 RESET 位后 milli_sleep
# 5ms 是【真实睡眠】（守护不注入 milli_sleep 桩，虚拟时钟不被推进），
# 200ms 余量充裕；随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次
# 推进一拍 IR 计数滤波）并消费两个 Monitor——mon0 透传守护 raw IR/RED
# 计数快照与 count，monf 输出 eir 滤波后 IR 计数。
# 守护 SpO2/100sps/n=2；模型 virt_tick 每拍直接向环形 FIFO 推一拍正弦
# 计数（RED 50000±18000、IR 60000±22000，32 拍周期），call 读 FIFO_DATA
# 流式口即有样本、零真实睡眠；一拍对应一个 virt_tick，空 FIFO 拍跳过。
# 用法：cat scripts/test/max30102_virt.mt | bash _run.sh --robot=robots/test/max30102_virt.sql
@Action
t0.delay  eir.out  mon0.go  monf.go;
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
