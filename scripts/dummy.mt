# Dummy 冒烟动作脚本（无硬件自检）：
# 配 robots/test.sql 用——那份最小结构脚本里只有一台 Dummy 设备 d1
# （驱动 modules/dummy.lua），全程不接任何硬件。
# 本脚本声明一列 d1.test、只播一帧：首行 `-` 无上一行可继承，test 参数
# 按未设置派发，d1 的 call 照常执行一次——仅回显问候并统计调用次数，
# 退出时 destroy 打印总调用数（看到 {"count":1,...} 且退出码 0 即链路通）。
# 适用场景：装好环境后跑通「结构脚本 → 动作脚本 → 驱动 call」最小链路；
# 排查派发管线时当最小复现（覆盖 MtVars_Lua 全生命周期：build 元数据
# 传递 / call 参数合并 / destroy 释放）。
# 用法：cat scripts/dummy.mt | ./build/mybot --robot=robots/test.sql
@Action
d1.test;
      -;
@
