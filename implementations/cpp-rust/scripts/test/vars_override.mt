# @Vars 覆盖防线（审计 P0-2）负值契约：.mt 内联 @Vars 与结构定义同名 → 报错退出非 0。
# 结构脚本 vars_num.sql 里 spd=200 且 Relay.note='$spd'；若本脚本的 spd=300 生效，
# note 会变成 300——等价于动作脚本改写结构硬件参数，必须被拒绝。
# 运行：cat scripts/test/vars_override.mt | ./build/mybot --robot=robots/test/vars_num.sql
@Vars
name  value;
  spd  300;
@

@Action
relay0.test;
  $(spd+100);
@
