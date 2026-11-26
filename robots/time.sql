/* 系统时间：纯软件变量，不声明总线/地址，也不需要 --allow-hardware。
 *
 * format / utc 是动作参数，不是结构列——动作参数不能覆盖同名元数据。
 */
CREATE TABLE Time (name String);
INSERT INTO Time (name) VALUES ('clock');
