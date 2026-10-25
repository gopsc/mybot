# 仿真蜘蛛：精确相对转向（一次性，仿真器内带刹车到量，贴着目标角度停）
# 动作码：6=turn，参数=角度（正=左转，负=右转）。比按时长的 sim_left/right.mt
# 可控得多——转到指定度数就停，不受帧率/减速尾程影响。
#
# 参数经调用时注入：run_action_script(script="sim_turn.mt", vars={"deg":35})
# 脚本里的 $(deg) 就地取该值（缺 vars 会响亮报「expression references 'deg'」，
# 不会静默乱转）。第三列 spk.delay=2000ms：等转到量、机身停稳后再返回，下一次
# 拍照即新朝向。2000ms 够 |deg|≤180°（转率≈126°/s）；更大角度请分两次转。

@Action
sim.M sim.P spk.delay;

6 $(deg) 2000;	# turn $(deg) 度（正左负右）后自动停
