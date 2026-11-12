# BH1750 无硬件端到端（proto=virt，命令式单字节 opcode + 无指针纯读的环境光器件）：
# 首行 t0 预热 200ms 等守护 setup（build 真实睡眠 120ms 一帧，余量充裕），
# 随后 16 拍 ×50ms：pump Ema（引用快照注入，play 一次推进一拍 LUX 滤波）并消费
# 两个 Monitor——mon0 透传守护 raw（LUX）与 count，monf 输出 eavg 滤波后照度与
# 阈值 level。守护 interval=20ms（连续模式 call 零写零睡眠，一拍对应一个
# virt_tick），模型 32 拍正弦 count 12002~18002 → LUX 10001.7~15001.7；少数拍
# count 恰为 6 的倍数 ⇒ raw 成整数，加上 20ms/50ms 混叠（快照采到哪拍不固定），
# 故 :f 浮点断言锚 monf 行 Ema 的 α 混合 out（恒带小数、未被 sign=16 取整补码）。
# 用法：cat scripts/test/bh1750_virt.mt | ./build/mybot --robot=robots/test/bh1750_virt.sql
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
