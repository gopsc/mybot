# 别名 + 真名解析出同一 (设备,参数)（负值）：派发前查重，不得逐行静默覆盖
@Alias
name  alias;
   r  relay-a;
@

@Action
r.test  relay-a.test;
  200     300;
@
