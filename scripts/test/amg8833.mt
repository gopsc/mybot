# AMG8833 8x8 红外热像阵列测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/amg8833.sql（I2C + cam0@0x69 + Timer + cam-d0 守护）
# 运行：cat scripts/test/amg8833.mt | ./build/mybot --robot=robots/test/amg8833.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x69 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/AMG8833 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# cam0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=200ms（10Hz 帧率）。人体/热源靠近时 MAXT 升高、
# MAXR/MAXC 指示热源方位（行 0 靠近丝印侧）。
@Action
cam0.go  cam-d0.status  t0.delay;
      1             -       200;
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
