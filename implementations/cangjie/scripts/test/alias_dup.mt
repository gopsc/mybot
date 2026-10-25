# 用例3：同一动作脚本内重复定义别名 A，应抛错
# 运行：cat scripts/test/alias_dup.mt | ./target/release/bin/main --robot=robots/test/alias_dup.sql（预期非 0 退出）
@Alias
name  alias;
   A  angle;
@

@Alias
name  alias;
   A  echo;
@

@Action
s1.A;
   30;
@
