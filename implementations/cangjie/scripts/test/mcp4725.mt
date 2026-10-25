# MCP4725 12 位 I2C DAC 测试（percent/volt 扫描 + EEPROM 持久化）
# 结构脚本：robots/test/mcp4725.sql（I2C + dac0@0x62 + Timer + dac-d0 读回守护）
# 运行：cat scripts/test/mcp4725.mt | ./target/release/bin/main --robot=robots/test/mcp4725.sql
#
# 实机测试（需 /dev/i2c-1 总线 + 0x62 地址器件；万用表看 VOUT 引脚）。
# dac0.percent 列 = 输出占满量程百分比（0~100），volt/level 亦可为列；
# dac0.eep = 1 时走 EEPROM 持久化写（断电保持，写周期约 25ms）。
# 前 4 行扫压（10% -> 50% -> 90% -> 0%），第 5 行 EEPROM 保存 50%，
# 后 8 行以 200ms 节拍空转给 dac-d0 读回守护留采样窗口。
# 断电重启验证：EEPROM 保存后重启树莓派，VOUT 应自动恢复保存值。
@Action
dac0.percent  dac0.eep  t0.delay;
          10         -       200;
          50         -       200;
          90         -       200;
           0         -       200;
          50         1       200;
           -         -       200;
           -         -       200;
           -         -       200;
           -         -       200;
           -         -       200;
           -         -       200;
           -         -       200;
@
