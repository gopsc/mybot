# AS3935 无硬件端到端（proto=virt，事件型雷电传感器）：
# 首行 t0 预热 200ms 等守护 setup——真实驱动 build 约 4ms milli_sleep
# （复位 2ms + RCO 校准显示窗 2ms），200ms 余量充裕；随后 16 拍 ×50ms：
# pump Ema（引用快照注入，play 一次推进一拍 DIST_KM 滤波）并消费两个
# Monitor——mon0 透传守护 raw 快照（CODE/DIST_KM 两整数 + ENERGY:f
# 21 位浮点 + count），monf 输出 ev 滤波后距离与阈值 level。
# 守护 interval=20ms
# （call 前真实睡 2ms 等中断锁存稳定），一拍对应一次 virt_tick：
# 8 拍事件脚本（none/none/闪电/none/噪声/none/闪电/干扰，闪电距离
# 10~35km、能量 1e5~9e5 正弦，build 前预武装拍 0=none）。
# 用法：cat scripts/test/as3935_virt.mt | ./build/mybot --robot=robots/test/as3935_virt.sql
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
