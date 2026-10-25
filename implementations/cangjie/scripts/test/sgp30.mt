# SGP30 空气质量测试（直连单次 + 守护连续采样）
# 结构脚本：robots/test/sgp30.sql（I2C + sgp30-0@0x58 + Timer + sgp-d0 守护）
# 运行：cat scripts/test/sgp30.mt | ./target/release/bin/main --robot=robots/test/sgp30.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x58 地址器件）。
# halt-on-error 生效后无器件无法优雅跑完：I2C/SGP30 的 build 一旦返回 ERR
# 即中止整个动作（exit 1），据此可在无器件机器上快速验证错误通道是否打通。
#
# SGP30 采样间隔不得小于 1s（内部基线算法要求），所有 t0.delay 均为 1000ms；
# sgp30-0 的列参数 .go 无实际含义（call 不需要参数），仅为 @Action 列名格式占位。
# 上电后前 15s 读数固定 CO2eq=400/TVOC=0，属正常现象。
@Action
sgp30-0.go  sgp-d0.status  t0.delay;
         1             -      1000;
         1             -      1000;
         -             -      1000;
         -             -      1000;
         -             -      1000;
         -             -      1000;
@
