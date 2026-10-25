# @Vars 负值契约：同一动作脚本内重复定义名字 A → 报错退出非 0。
# 运行：cat scripts/test/vars_dup.mt | ./build/mybot --robot=robots/test/alias_dup.sql
@Vars
name  value;
   A   1;
@

@Vars
name  value;
   A   2;
@

@Action
s1.A;
   30;
@
