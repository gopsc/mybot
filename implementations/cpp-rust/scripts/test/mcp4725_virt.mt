# MCP4725 无硬件端到端配套动作：输出走 50% -> 75% -> 50%
# 运行：cat scripts/test/mcp4725_virt.mt | ./build/mybot --robot=robots/test/mcp4725_virt.sql
# percent 是 MCP4725.call 的动作参数（level > volt > percent 优先级里的
# 兜底路），address 已在结构脚本里定为 0x62
@Action
dac0.percent  t0.delay;
         50        50;
         75        50;
         50        50;
@
