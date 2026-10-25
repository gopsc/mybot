# BH1745NUC 四通道颜色传感器测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/bh1745.sql（I2C + colour0@0x38 + Timer + clr-d0 守护）
# 运行：cat scripts/test/bh1745.mt | ./build/mybot --robot=robots/test/bh1745.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x38 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/BH1745 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# colour0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 守护 interval=200ms（>= 测量时间 160ms），后 10 行以 200ms 节拍空转
# 给 clr-d0 守护留出采样窗口。通道比值（R:C 等）才是颜色信息。
@Action
colour0.go  clr-d0.status  t0.delay;
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
