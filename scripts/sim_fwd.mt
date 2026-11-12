# 仿真蜘蛛：精确相对前进（一次性，仿真器内带刹车到量，不冲过头）
# 动作码：5=fdist，参数=米（正=前进，负=后退）。比按时长的 sim_forward.mt
# （2 秒≈3 米）精细得多，适合「靠近一点再拍照」的逐步逼近。
#
# 参数经调用时注入：run_action_script(script="sim_fwd.mt", vars={"dist":0.5})
# 脚本里的 $(dist) 就地取该值（缺 vars 会响亮报「expression references 'dist'」）。
# 第三列 spk.delay=3000ms：等走到量、机身停稳后再返回。3000ms 够 |dist|≤2m
# （极速 1.6m/s + 加速滞后）；更远请分多段走，边走边拍照核对。

@Action
sim.M sim.P spk.delay;

5 $(dist) 3000;	# fdist $(dist) 米（正前负后）后自动停
