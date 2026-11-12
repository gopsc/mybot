# ADS1115 功能测试（单端 + 守护连续采样）
# 结构脚本：robots/test/ads1115.sql（I2C + adc0@0x48 + Timer + adc-d0 守护）
# 运行：cat scripts/test/ads1115.mt | ./build/mybot --robot=robots/test/ads1115.sql
#
# 注意：SQL 脚本不支持注释；且结构脚本 '-' 占位符经元数据归一为 "0"，
# 所以 adc0 的 pga/dr 在 .sql 里显式写 '2'/'4'（±2.048V / 128SPS），
# 若写 '-' 会归一成 0，被驱动当作显式档位 ±6.144V / 8SPS。
#
# 无器件时（总线扫描无 ACK）：build/call 返回明确 ERR，守护 fail(-2) 发布错误码，
# 程序仍正常走完退出 0（与 test_hal_i2c 的无器件约定一致）。
#
# 前 4 行轮询单端通道 AIN0~AIN3（call 返回 raw/voltage）；
# 后 12 行以 100ms 节拍空转，给 adc-d0 守护（50ms 间隔采样 AIN0）留出采样窗口。
# 注意：@Action 列参数经占位符继承会常驻（首行归一为 0），本文件故意不设
# pos/neg 列——驱动按 pos~=nil 分流差分/单端，差分见 ads1115_diff.mt。
@Action
adc0.channel  adc-d0.status  t0.delay;
          0             -       50;
          1             -       50;
          2             -       50;
          3             -       50;
          0             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
          -             -      100;
@
