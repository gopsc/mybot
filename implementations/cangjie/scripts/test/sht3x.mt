# SHT3X 温湿度测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/sht3x.sql（I2C + sht3x-0@0x44 + Timer + sht-d0 守护）
# 运行：cat scripts/test/sht3x.mt | ./target/release/bin/main --robot=robots/test/sht3x.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x44 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/SHT3X 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# sht3x-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 前 2 行轮询直连变量，后 8 行以 100ms 节拍空转，
# 给 sht-d0 守护（100ms 间隔采样 T/RH）留出采样窗口。
@Action
sht3x-0.go  sht-d0.status  t0.delay;
         1             -        50;
         1             -        50;
         -             -       100;
         -             -       100;
         -             -       100;
         -             -       100;
         -             -       100;
         -             -       100;
         -             -       100;
         -             -       100;
@
