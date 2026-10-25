# MH-Z19B NDIR CO₂ 传感器测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/mhz19.sql（UART uart-0@/dev/serial0@9600 + co2-0 + Timer + co2-d0 守护）
# 运行：cat scripts/test/mhz19.mt | ./build/mybot --robot=robots/test/mhz19.sql
#
# 实机测试（需 /dev/serial0 串口 + MH-Z19B 模块；无器件机器走 halt-on-error
# 验证错误通道：build/请求写失败即 exit 1）。
# co2-0.go 列无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=1000ms（NDIR 采样周期约 100ms，1s 足够宽裕）。
# 上电预热约 3 分钟，期间读数偏低属正常现象。
@Action
co2-0.go  co2-d0.status  t0.delay;
      1             -      1000;
      1             -      1000;
      -             -      1000;
      -             -      1000;
      -             -      1000;
      -             -      1000;
      -             -      1000;
      -             -      1000;
@
