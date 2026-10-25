# ADXL345 三轴加速度计测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/adxl345.sql（I2C + acc0@0x53 + Timer + acc-d0 守护）
# 运行：cat scripts/test/adxl345.mt | ./target/release/bin/main --robot=robots/test/adxl345.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x53 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/ADXL345 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# acc0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=20ms（odr=100Hz 跑满），后 10 行以 50ms 节拍空转
# 给 acc-d0 守护留出采样窗口。FULL_RES 下 256 LSB/g（1g ≈ 25600 码）。
@Action
acc0.go  acc-d0.status  t0.delay;
      1             -        50;
      1             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
@
