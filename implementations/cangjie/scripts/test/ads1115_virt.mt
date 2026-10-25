# ADS1115 无硬件端到端（proto=virt，首个字寻址+oneshot 转换门/OS 握手器件）：
# 首行 t0 预热 200ms 等守护 setup（build 写 CONFIG+回读，零真实睡眠），
# 随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍电压
# 滤波）并消费两个 Monitor——mon0 透传守护 raw voltage 快照与 count，
# monf 输出 ev 滤波后电压（V）与阈值 level。
# 守护 PGA=2 ±2.048V / 128SPS / AIN0；模型 virt_tick 造正弦 1.65±0.25V
# （1.40~1.90V，32 拍周期）并预武装，call 启动转换首读 OS 即就绪，
# 零真实睡眠；一拍对应一个 virt_tick。
# 用法：cat scripts/test/ads1115_virt.mt | bash _run.sh --robot=robots/test/ads1115_virt.sql
@Action
t0.delay  ev.out  mon0.go  monf.go;
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
