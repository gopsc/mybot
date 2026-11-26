# BME688 无硬件端到端（proto=virt，四合一温压湿气传感器）：
# 首行 t0 预热 200ms 等守护 setup——真实驱动 build 含软复位后 10ms
# milli_sleep（200ms 余量充裕），随后 16 拍 ×50ms：pump Ema
# （引用快照注入，play 一次推进一拍温度滤波）并消费两个 Monitor——
# mon0 透传守护 raw 快照（T/P/H/GAS 四浮点 + GAS_OK 整数 + count），
# monf 输出 ev 滤波后温度。
# 守护 interval=50ms（forced 门 160ms，但 virt_tick 预武装触发即
# 就绪零睡眠，一拍即一次采样）：32 拍确定性码钉循环多轮
# （T 22~28°C / P 100725~101925Pa / H 35~65%RH / GAS 6~18kΩ）。
# 用法：cat scripts/test/bme688_virt.mt | ./build/mybot --robot=robots/test/bme688_virt.sql
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
