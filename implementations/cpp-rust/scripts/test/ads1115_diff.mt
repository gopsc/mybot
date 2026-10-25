# ADS1115 差分读取测试（P=AIN0/N=AIN1 与 P=AIN2/N=AIN3）
# 结构脚本：robots/test/ads1115_diff.sql（I2C + adc0@0x48 + Timer，无守护）；运行：
# cat scripts/test/ads1115_diff.mt | ./build/mybot --robot=robots/test/ads1115_diff.sql
#
# 差分与单端不能混用同一个 @Action：pos/neg 列因占位符继承而常驻，
# 一旦出现驱动将始终走差分分支（支持 0-1 / 0-3 / 1-3 / 2-3）。
@Action
adc0.pos  adc0.neg  t0.delay;
      0        1       50;
      0        1       50;
      2        3       50;
      2        3       50;
@
