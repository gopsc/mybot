# CHT8305 无硬件端到端（proto=virt，字寄存器指针+无指针纯读+双 ROM ID 器件）：
# 首行 t0 预热 200ms 等守护 setup（build 半字软复位后真实 sleep 10ms，余量
# 充裕），随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍 T
# 滤波）并消费两个 Monitor——mon0 透传守护 raw 两字段快照（T/H）与 count，
# monf 输出 eavg 滤波后温度与阈值 level。
# 守护 interval=50ms（call 含 2×14ms 转换门真实等待共 28ms），一拍一 tick
# 推进 virt_tick（合成反相正弦 T 20~30°C、H 60~40%RH，32 拍周期；build 前
# 预武装，测量指针写零等待，武装跨软复位保留）。
# 用法：cat scripts/test/cht8305_virt.mt | ./build/mybot --robot=robots/test/cht8305_virt.sql
@Action
t0.delay  eavg.out  mon0.go  monf.go;
   2000       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
    50       -         -         -    ;
@
