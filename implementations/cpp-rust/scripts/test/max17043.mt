# MAX17043 锂电池电量计测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/max17043.sql（I2C + fuel-0@0x36 + Timer + fuel-d0 守护）
# 运行：cat scripts/test/max17043.mt | ./build/mybot --robot=robots/test/max17043.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x36 电量计 + 真电池）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/MAX17043 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# fuel-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量，后 6 行以 1s 节拍空转，
# 给 fuel-d0 守护（1s 间隔，电量变化慢）留出采样窗口。
@Action
fuel-0.go  fuel-d0.status  t0.delay;
        1             -       100;
        1             -       100;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
        -             -      1000;
@
