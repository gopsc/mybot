# 数据格拼接（正值）：$(g+n) → "hello-" + 2 → 文本参数（JsonString）
# 经 dummy 的 echo 键原样回传（与 SQL 元数据列同型，驱动 Lua 侧无感）
@Action
dum-1.echo;
  $(g+n);
@
