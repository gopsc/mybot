# 参数化片段：节拍引用 @Vars 旋钮（$(amp) 在派发期对合并后的值求值）。
# 主脚本同名 @Vars 覆盖这里的缺省值（主从覆盖，stderr 注记）。
@Vars
name value;
  amp 21;
@

@Action
r1.test;
  $(amp);
@
