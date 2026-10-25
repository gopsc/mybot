# BMI270 六轴 IMU 测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/bmi270.sql（I2C + imu0@0x68 + Timer + imu-d0 守护）
# 运行：cat scripts/test/bmi270.mt | ./target/release/bin/main --robot=robots/test/bmi270.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x68 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/BMI270 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# imu0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=10ms（odr=100Hz 跑满），后 20 行 x 50ms 空转让守护留出采样窗口。
@Action
imu0.go  imu-d0.status  t0.delay;
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
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
      -             -        50;
@
