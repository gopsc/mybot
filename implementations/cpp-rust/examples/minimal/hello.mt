# 最小动作脚本（三层之三：演员剧本——一行一个动作）
# 数据格只认数值，文本值要经 @Alias 起名 + $(别名) 间接（docs/dsl.md）。
# 这里给 d0 的 echo 参数喂一句问候，只播一帧。
#
# 用法（两种等价）：
#   ./build/mybot --robot=examples/minimal/robot.sql --input examples/minimal/hello.mt
#   cat examples/minimal/hello.mt | ./build/mybot --robot=examples/minimal/robot.sql

@Alias
name   alias;
greet  你好，三层架构;
@

@Action
d0.echo;
$(greet);
@
