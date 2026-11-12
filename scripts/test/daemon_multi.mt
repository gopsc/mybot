# 多器件合并采样守护 E2E（proto=virt，无硬件）：
# 首行 t0 预热 800ms 等守护 setup——合并版 setup 比单器件慢（双驱动 fenv
# 加载 + jit.off，首拍前还要各过一次驱动 build/回读），200ms 会像旧值那样
# 首消费时 count 仍为 0（no daemon value 中止）；随后 8 拍 ×50ms 消费 mon0
# ——mon0 透传守护合并快照（v0=器件1 LUX，v1=器件2 LUX）与 count。
# 两器件各占一个 virt_tick 相位，值来自内存仿真。
# 守门锚点：VIRTUAL HARDWARE 横幅 + joined, total publishes=（正常退场）。
# 用法：cat scripts/test/daemon_multi.mt | ./build/mybot --robot=robots/test/daemon_multi.sql
@Action
t0.delay  mon0.go;
   2000       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
    50       -   ;
@
