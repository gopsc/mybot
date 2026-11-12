# BH1745NUC 无硬件端到端（proto=virt，四通道 R/G/B/C 颜色传感器）：
# 首行 t0 预热 500ms 等守护 setup——真实 build 的软复位后 milli_sleep(5)
# 与首拍等待 milli_sleep(162) 共 167ms 是【真实睡眠】（守护不注入
# milli_sleep 桩，虚拟时钟不被推进），预热必须留足；随后 16 拍 ×50ms：
# pump Ema（引用快照注入，play 一次推进一拍 R 通道计数滤波）并消费两个
# Monitor——mon0 透传守护 raw 四通道计数快照（R/G/B/C）与 count，monf
# 输出 ev 滤波后 R 计数与阈值 level。守护 interval=20ms（call 零睡眠），
# 一拍一拍对应 virt_tick（R 19000~25000 同相正弦，32 拍周期，build 前
# 预武装，MODE 写只清 VALID 不清数据区）。
# 用法：cat scripts/test/bh1745_virt.mt | ./build/mybot --robot=robots/test/bh1745_virt.sql
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
