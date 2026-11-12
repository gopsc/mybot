-- 最小结构脚本（三层之一：舞台接线图——机器人有哪些零件）
-- 一张表 = 一类器件，表名 = 驱动文件名：这里声明一台 Dummy 设备 d0，
-- 装配器据此去模块路径（缺省 ./modules）找 dummy.lua 驱动并上电。
-- Dummy 不接任何硬件：call 时回显参数、统计次数，适合链路自检。
-- 零依赖跑通：./build/mybot --robot=examples/minimal/robot.sql \
--                        --input examples/minimal/hello.mt
CREATE TABLE dummy (name String);
INSERT INTO dummy (name) VALUES (d0);
