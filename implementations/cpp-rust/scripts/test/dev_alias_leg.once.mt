# 可复用动作模板：设备经别名 leg 绑定（片段内缺省 relay-a）。
# 主脚本用同名 @Alias 改绑（主从覆盖）即可把整段动作绑到别的设备——
# 模板入库不动，换一行绑定值。*.once 后缀：菱形复用时第二路跳过。
@Alias
name  alias;
   leg  relay-a;
@

@Action
leg.test;
  150;
  250;
@
