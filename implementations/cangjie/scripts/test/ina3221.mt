# INA3221 三通道电流/电压测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/ina3221.sql（I2C + ina3221-0@0x40 + Timer + ina-d0 守护）
# 运行：cat scripts/test/ina3221.mt | ./target/release/bin/main --robot=robots/test/ina3221.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x40 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/INA3221 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# ina3221-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量（一次读全三通道），后 8 行以 150ms 节拍空转，
# 给 ina-d0 守护（150ms 间隔 >= 一个转换循环）留出采样窗口。
@Action
ina3221-0.go  ina-d0.status  t0.delay;
          1             -        50;
          1             -        50;
          -             -       150;
          -             -       150;
          -             -       150;
          -             -       150;
          -             -       150;
          -             -       150;
          -             -       150;
          -             -       150;
@
