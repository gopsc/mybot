# MS5611 高分辨率气压计测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/ms5611.sql（I2C + baro0@0x77 + Timer + baro-d0 守护）
# 运行：cat scripts/test/ms5611.mt | ./target/release/bin/main --robot=robots/test/ms5611.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x77 地址器件；CSB=VDD 的模块地址是 0x76）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/MS5611 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# 预期（室内静置）：
#   P_HPA ≈ 980~1040（当地气压），T_C ≈ 室温
#   ALT_M 随气压换算；呼气到芯片上 P_HPA 应可观测上升
# 排查指引：
#   build 报 PROM CRC mismatch -> 优先复核 CRC 布局（word7/0xAE，见驱动头注释），
#                               其次错挂器件/总线异常
#   读数缓慢漂移属正常（气压本身随天气/高度变化），接 Ema/Kalman 滤波更平滑
#   地址 0x76 的模块           -> 改 .sql 中 address 列为 '0x76'
#
# baro0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 后 6 行以 50ms 节拍空转，给 baro-d0 守护（30ms 间隔）留出采样窗口。
@Action
baro0.go  baro-d0.status  t0.delay;
      1             -        50;
      1             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
@
