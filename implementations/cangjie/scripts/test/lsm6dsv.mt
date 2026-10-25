# LSM6DSV16X 六轴 IMU 测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/lsm6dsv.sql（I2C + imu0@0x6A + Timer + imu-d0 守护）
# 运行：cat scripts/test/lsm6dsv.mt | ./target/release/bin/main --robot=robots/test/lsm6dsv.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x6A 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/LSM6DSV 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# imu0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=10ms（odr=120Hz 跑满），后 20 行 x 50ms 空转让守护留出采样窗口。
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
