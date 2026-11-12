# 别名指向未定义名字（负值）：解析期清晰报错，不落到派发期 not defined
@Alias
name  alias;
   r  no-such-dev;
@

@Action
r.test;
  200;
@
