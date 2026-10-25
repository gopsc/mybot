# EMC2101 智能风扇控制器测试（采样 + 设占空比）
# 结构脚本：robots/test/emc2101.sql（I2C + fan0@0x4C + Timer + fan-d0 守护）
# 运行：cat scripts/test/emc2101.mt | ./target/release/bin/main --robot=robots/test/emc2101.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x4C 地址器件 + 风扇接 PWM/TACH，或空转测采样）。
# halt-on-error 生效后无器件无法优雅跑完：build 一旦返回 ERR 即中止（exit 1)。
#
# fan0.go 列：1 = call 采样（无参），40 = call 设 40% 占空比（带 duty 参数即切手动）；
# 后 10 行以 200ms 节拍空转给 fan-d0 守护留采样窗口。
@Action
fan0.go  fan-d0.status  t0.delay;
      1             -       200;
     40             -       200;
     70             -       200;
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
