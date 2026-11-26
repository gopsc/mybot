# MCP3421 无硬件端到端（proto=virt，首个单字节配置+回显/RDY 握手器件）：
# 首行 t0 预热 300ms 等守护 setup（build 写配置+回显读，无真实睡眠），
# 随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍电压
# 滤波）并消费两个 Monitor——mon0 透传守护 raw voltage 快照与 count，
# monf 输出 ev 滤波后电压（V）与阈值 level。
# 守护 12bit/×1/连续档（转换门 5ms），模型 virt_tick 预武装首读就绪，
# call 零真实睡眠；一拍对应一个 virt_tick（合成正弦 ±1.5V，32 拍周期）。
# 用法：cat scripts/test/mcp3421_virt.mt | ./build/mybot --robot=robots/test/mcp3421_virt.sql
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
