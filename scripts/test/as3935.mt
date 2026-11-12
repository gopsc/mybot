# AS3935 闪电传感器测试（直连读事件 + 守护低频轮询）
# 结构脚本：robots/test/as3935.sql（I2C + as3935-0@0x03 + Timer + as-d0 守护）
# 运行：cat scripts/test/as3935.mt | ./build/mybot --robot=robots/test/as3935.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x03 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/AS3935 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# 预期（室内安静环境）：
#   call 返回 EVENT=none CODE=0（无事件时距离=-1 能量=0）
#   附近有电机/继电器动作时会短暂出现 EVENT=disturber/noise——属正常现象
#   真闪电：EVENT=lightning CODE=3，DIST_KM=1~40（-1=超范围/未知），ENERGY>0
# 排查指引：
#   build 报 calibration failed -> 天线/供电问题；个别模块需调 tun_cap 列
#   无器件但 build 通过        -> 不可能（在位甄别读 AFE_GAIN 复位默认值）
#   i2cdetect 扫不到 0x03      -> 正常，保留地址区默认不扫，直接跑本用例即可
#
# as3935-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 后 6 行以 300ms 节拍空转，给 as-d0 守护（250ms 间隔）留出轮询窗口。
@Action
as3935-0.go  as-d0.status  t0.delay;
         1             -         50;
         1             -         50;
         -             -        300;
         -             -        300;
         -             -        300;
         -             -        300;
         -             -        300;
         -             -        300;
@
