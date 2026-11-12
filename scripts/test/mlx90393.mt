# MLX90393 三轴磁力计测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/mlx90393.sql（I2C + mlx0@0x0C + Timer + mlx-d0 守护）
# 运行：cat scripts/test/mlx90393.mt | ./build/mybot --robot=robots/test/mlx90393.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x0C 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/MLX90393 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# 预期（器件水平静止、远离磁铁）：
#   X/Y/Z 各 ±几十 µT（地磁场总量 ~50µT，模长 sqrt(X^2+Y^2+Z^2) 稳定）
#   T 接近室温（°C）
# 排查指引：
#   轴明显对调 / T 位置不对 -> 改驱动 OFF_T/Z/Y/X 偏移表（MLX90393.lua 复核项 1）
#   数值量级异常            -> 核对灵敏度基准（复核项 2，或用 XR/YR/ZR 原始计数自算）
#   每次都报测量超时        -> 优先核对 SM_DONE 位定义（复核项 4）
#
# mlx0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量，后 6 行以 50ms 节拍空转，
# 给 mlx-d0 守护（20ms 间隔 >= 单次测量耗时）留出采样窗口。
@Action
mlx0.go  mlx-d0.status  t0.delay;
      1             -        50;
      1             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
@
