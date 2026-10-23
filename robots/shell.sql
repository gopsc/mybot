-- Shell 宿主命令驱动示例：输入一条命令字符串，返回 out/err/code。
-- 命令以宿主用户权限与环境在当前目录执行（不是沙箱），激活需要 --allow-hardware：
--   .venv/bin/python -m pymybot run --robot robots/shell.sql \
--     --input scripts/shell.mt --allow-hardware --timeout 30
CREATE TABLE Shell (name String, timeout Number);
INSERT INTO Shell (name, timeout) VALUES ('sh', 10000);
