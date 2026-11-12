# MAX17048 无硬件端到端（proto=virt，偶地址稀疏字地图电量计）：
# 首行 t0 预热 200ms 等守护 setup（纯只读 build 仅 5 事务零睡眠，余量
# 充裕），随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍
# VCELL 滤波）并消费两个 Monitor——mon0 透传守护 raw 两字段快照
#（VCELL/SOC）与 count，monf 输出 ev 滤波后电池电压与阈值 level。
# 守护 interval=20ms（call 零睡眠），一拍一拍对应 virt_tick（单节锂电
# 3.60~4.10V / SOC 72~88%，32 拍周期，build 前预武装，无转换门）。
# 用法：cat scripts/test/max17048_virt.mt | ./build/mybot --robot=robots/test/max17048_virt.sql
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
