# Daemon 后台采样

技能 `pymybot-scripting` 参考文件。仓库根为 `mybot/`（Python 主线）。
实现：`pymybot/daemon.py`（Python 工作线程 + 独立 Lua 状态 + 槽位桥）、
`modules/lib/sensor_daemon.lua`（采样 chunk）、`modules/lib/sensor_aggregate.lua`（聚合）。

## 1. Daemon 表（结构 SQL）

```sql
CREATE TABLE Daemon (
    name     String,
    chunk    String,   -- 采样 chunk，模块相对路径，缺省 lib/sensor_daemon.lua
    driver   String,   -- 器件驱动名（sensor_daemon 必填）
    proto    String,   -- i2c（缺省）/ spi / uart / virt
    path     String,   -- 总线路径（缺省 i2c:/dev/i2c-1，spi:/dev/spidev0.0）
    addr     String,   -- 器件地址（hex 如 '0x40'）
    interval String,   -- 采样间隔毫秒，1..3600000，缺省 5
    fields   String,   -- 'T:f|H:f'：call 结果按序发布为 v0,v1,...（模式见下）
    sign     String,   -- 整数符号扩展基准（s16 字段跟随），64 位范围
    devices  String,   -- 多器件：'驱动@地址@字段,字段|驱动@地址@字段'（仅 i2c/virt）
    sources  String    -- 聚合：先前声明的 daemon 名，逗号或管道分隔
);
```

- 字段模式：空 = 跟随全局 `sign`；`f`/`float` = 原样浮点；`s16` = 16 位符号扩展。
- 字段数上限 64（`maxvals`）；`fields` 拼错字段名按 tick 错误处理（不发布假样本，
  `count` 停滞即诊断线索）。
- 槽位对消费者暴露：`v0..vN`（按 fields 顺序）+ `count` + 独立 `status`（失败码）。
- proto=virt 的守护在虚拟总线上跑真实驱动的 build/call 全链路。
- 聚合（`sources`）用 `lib/sensor_aggregate.lua` chunk：把多个上游 daemon 的槽
  再发布成一个槽。

## 2. 消费者模式

滤波/监视类软件模块通过 `$daemon` 引用读取槽位（`$th0` 的结果表被合并进
本变量元数据，见 `references/structure-sql.md` 第 4 节）：

```sql
CREATE TABLE Ema (name String, alpha String, src String, field String);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$th0', 'v0');

CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$th0');
```

动作脚本里 `eavg.out` / `mon0.go` 每 play 一次推进一拍滤波/监视。

## 3. 生命周期注意

- 去激活时守护线程先收到停止请求（30s 宽限）再销毁；守护仍在退出时禁止重新激活。
- `interval` 要覆盖驱动 call 的真实耗时（如 CHT8305 call 内含 2×14ms 转换等待，
  interval 取 50ms；再短会溢出）。
