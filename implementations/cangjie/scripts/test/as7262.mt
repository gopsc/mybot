# AS7262 六通道光谱传感器测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/as7262.sql（I2C + spec0@0x49 + Timer + spec-d0 守护）
# 运行：cat scripts/test/as7262.mt | ./target/release/bin/main --robot=robots/test/as7262.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x49 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/AS7262 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# 预期（室内环境光）：
#   V/B/G/Y/O/R 各通道 16 位计数，各不相同且随光源颜色变化；
#   对白纸反射读数显著高于对黑色物体；片上 TEMP_C 接近室温（精度约 ±8.5°C）
#   原始计数顶格 0xFFFF = 饱和，降 gain 或缩短 integ
# 排查指引：
#   build 报 device type 不符 -> 挂的可能是 AS7261(0x3D)/AS7263(0x3F)，
#                               或间接访问握手异常
#   data-ready 超时         -> 增大 timeout 列或减小 integ 列（积分时间越长
#                              一轮越久）
#   读数全 0 或抖动剧烈     -> 检查接线；间接访问握手对总线质量敏感
#
# spec0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位；
# 后 6 行以 400ms 节拍空转，给 spec-d0 守护（300ms 间隔 >= 一轮积分）留窗口。
@Action
spec0.go  spec-d0.status  t0.delay;
      1             -       50;
      1             -       50;
      -             -      400;
      -             -      400;
      -             -      400;
      -             -      400;
      -             -      400;
      -             -      400;
@
