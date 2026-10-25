# 别名指向别名（负值）：一层为止，链式穿透在解析点报错
@Alias
name  alias;
   r   r2;
   r2  relay-a;
@

@Action
r.test;
  200;
@
