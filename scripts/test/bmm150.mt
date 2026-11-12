# BMM150 三轴地磁传感器测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/bmm150.sql（I2C + mag0@0x10 + Timer + mag-d0 守护）
# 运行：cat scripts/test/bmm150.mt | ./build/mybot --robot=robots/test/bmm150.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x10 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/BMM150 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# mag0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=200ms（regular preset ODR=10Hz）。
# 罗盘用法提示：X/Y 水平分量算航向需配合倾角补偿（引用加速度计快照）。
@Action
mag0.go  mag-d0.status  t0.delay;
      1             -       200;
      1             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
      -             -       200;
@
