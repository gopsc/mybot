# LTC2944 多节电池电量计测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/ltc2944.sql（I2C + gauge-0@0x64 + Timer + gauge-d0 守护）
# 运行：cat scripts/test/ltc2944.mt | ./build/mybot --robot=robots/test/ltc2944.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x64 电量计 + 带 sense 电阻的真实电池通路）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/LTC2944 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# gauge-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量，后 6 行以 1s 节拍空转，
# 给 gauge-d0 守护（1s 间隔，电荷连续累计）留出采样窗口。
@Action
gauge-0.go  gauge-d0.status  t0.delay;
        1             -       100;
        1             -       100;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
@
