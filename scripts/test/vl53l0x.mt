# VL53L0X ToF 激光测距测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/vl53l0x.sql（I2C + tof0@0x29 + Timer + tof-d0 守护）
# 运行：cat scripts/test/vl53l0x.mt | ./build/mybot --robot=robots/test/vl53l0x.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x29 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/VL53L0X 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# 预期（室内，传感器正对白墙/纸面约 300mm）：
#   DIST_MM ≈ 300 ± 少许（毫米级），STATUS=0 VALID=1
#   SIGNAL_MCPS 数十以上、SPAD_NB 接近标称有效 SPAD 数为质量良好
# 排查指引：
#   对空旷处（>2m）   -> DIST_MM≈8190 / VALID=0 属正常（超出量程）
#   恒定报 ready 超时  -> 检查供电/接线；XSHUT 引脚须释放（拉高或悬空看模块上拉）
#   远距测不到        -> 试试 long='1' 长距模式（tuning 换挡 + 门限 0.1 MCPS）
#   距离数值跳变极大   -> 目标过黑/强阳光直射，看 SIGNAL_MCPS 与 AMBIENT_MCPS
#
# tof0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 后 6 行以 100ms 节拍空转，给 tof-d0 守护（60ms 间隔 >= 单帧 33ms）留窗口。
@Action
tof0.go  tof-d0.status  t0.delay;
     1             -        50;
     1             -        50;
     -             -       100;
     -             -       100;
     -             -       100;
     -             -       100;
     -             -       100;
     -             -       100;
@
