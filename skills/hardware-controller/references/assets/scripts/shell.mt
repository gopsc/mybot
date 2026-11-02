# Shell 驱动动作示例：输入一条命令字符串，返回 out/err/code。
# MT 单元格按空白切分，命令里的词分隔用 \t 转义（shell 视 TAB 为参数分隔，
# POSIX/Windows 皆然）；含字面空格的复杂命令用 --var CMD="..." 传入后写 $(CMD)。
# 运行（命令以宿主用户权限执行，需要 --allow-hardware）：
#   .venv/bin/python -m pymybot run --robot robots/shell.sql \
#     --input scripts/shell.mt --allow-hardware --timeout 30
@Action
sh.cmd;
$("echo\thello\tfrom\tthe\tpymybot\tshell\tdriver");
$("exit\t3");
@
