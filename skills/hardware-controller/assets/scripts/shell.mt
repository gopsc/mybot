# Shell 驱动动作示例：输入一条命令字符串，返回 out/err/code。
# MT 双引号内的空格、Tab、;、# 不分格，命令可直接写成一条带空格的字符串。
# 运行（命令以宿主用户权限执行，需要 --allow-hardware）：
#   .venv/bin/python -m pymybot run --robot robots/shell.sql \
#     --input scripts/shell.mt --allow-hardware --timeout 30
@Action
sh.cmd;
$("echo hello from the pymybot shell driver");
$("exit 3");
@
