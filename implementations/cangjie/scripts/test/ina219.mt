# INA219 单通道电流/功率测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/ina219.sql（I2C + ina219-0@0x40 + Timer + ina-d0 守护）
# 运行：cat scripts/test/ina219.mt | ./target/release/bin/main --robot=robots/test/ina219.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x40 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/INA219 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# ina219-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量，后 8 行以 50ms 节拍空转，
# 给 ina-d0 守护（50ms 间隔 >= 一个转换循环 2 x 532µs x 16）留出采样窗口。
@Action
ina219-0.go  ina-d0.status  t0.delay;
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
