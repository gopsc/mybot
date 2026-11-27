# 仿真蜘蛛：向前弹道跳（一次性，空中不受控，落到地面或箱顶后自动恢复）
# 动作码：10=jump，两个参数——param=前跳水平距离（米）、param2=起跳 apex 高度（米）。
# 用于跳过矮障碍、跳上箱子（跳上后可在箱顶行走，走下箱沿自动坠落）。
#
# 参数经调用时注入：run_action_script(script="sim_jump.mt", vars={"dist":0.8,"height":0.35})
# 脚本里的 $(dist)/$(height) 就地取值（缺 vars 会响亮报「expression references ...」）。
# 高度须高于目标箱顶才跳得上（跳弧 apex < 箱顶会被当墙挡回）；距离是同一高度起落的
# 期望水平位移，落到更低处会滑得更远。仿真器内钳到 height≤1.5m、dist≤4m。
# 第四列 spk.delay=3000ms：等腾跃到落地、机身停稳后再返回，下一次拍照即落点后画面。

@Action
sim.M sim.P sim.Q spk.delay;

10 $(dist) $(height) 3000;	# jump 前跳 $(dist) 米、apex $(height) 米，落地自动停
