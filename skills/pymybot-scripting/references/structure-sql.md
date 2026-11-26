# 结构脚本（.sql）

Source: 本文件是结构 SQL 文法的书面来源（实现 `pymybot/sql.py` 与 `pymybot/robot.py` 的 `_validate`）；
分层见 [docs/architecture.md](../../../docs/architecture.md)，命令与开关见 [docs/cli.md](../../../docs/cli.md)。

## 1. 基本文法

- 只支持这些语句：`CREATE TABLE`、`INSERT INTO`、`SELECT * FROM`、`SHOW TABLES;`、
  `DELETE FROM`、`DROP TABLE`、`UPDATE ... SET`。**结构文件只能含 CREATE/INSERT**；
  其余语句属于 `query` / `apply-sql`（见第 9 节）。
- **每条语句必须以 `;` 结尾**，单条语句也不例外，否则报 `SQL: unexpected end of script`。
- 注释只有两种：`--` 行注释与 `/* ... */` 块注释。
- 字符串：单引号 `'...'`，内部单引号写两遍 `''`；双引号 `"..."` 同样接受（转义规则相同）。
  **反斜杠是普通字符**（Windows 路径无需转义），没有 `\n` 之类的转义。
- 标识符（表名、列名）：`[A-Za-z_][A-Za-z0-9_]*`，**不含连字符**；保留字（CREATE/TABLE/…）
  作名字用时必须加引号。
- 值（VALUES / WHERE / SET 右边）三类合法形态：
  1. 带引号字符串（含标点的文本必须引起来）；
  2. 裸词：`[$]?[A-Za-z_][A-Za-z0-9.-]*` 或占位符 `-`；
  3. 数字字面量：十进制（可带符号/指数）或十六进制 `0x...`。
- 值中禁止 NUL；整个文件上限 8 MiB。

## 2. 声明变量：CREATE + INSERT

```sql
CREATE TABLE CHT8305 (
    name    String,
    I2C     String,
    address String
);
INSERT INTO CHT8305 (name, I2C, address) VALUES ('th-0', 'i2c-1', '0x40');
```

规则：

- 列类型只有 `String` / `Number`。`Number` 列的值必须是合法数字字面量或 `$(表达式)`
  （表达式语法在解析期校验，求值发生在激活时）。
- `INSERT` 必须按名字列出**全部**声明列，且每列恰好一次。
- 同一批里 `CREATE TABLE` 不得重名；表一旦 DROP，本批内不能再改。
- **每张普通表名对应一个驱动文件 `modules/<表名>.py` 或 `modules/<表名>.lua`**，
  加载期校验存在性（`Alias` / `Vars` / `Daemon` 三张内建表除外）；逐根查找、同根 Python
  优先，详见 `references/driver-lua.md`。
- 每张表必须有 `name` 列；变量名（name 列的值）须匹配 `[A-Za-z_][A-Za-z0-9_-]*`
  （**允许连字符**，如 `timer-0`），且全局唯一。
- `INSERT` 行序即声明序；引用必须**先声明后使用**（见第 4 节）。

## 3. 继承：`-`

数据行的单元格里写 `-` 表示继承上一行同列的值（首个数据行的 `-` 保持字面 `-`，
按「未提供」处理）。适合多器件共享总线配置：

```sql
CREATE TABLE SHT3X (name String, I2C String, address String);
INSERT INTO SHT3X (name, I2C, address) VALUES ('s0', 'i2c-1', '0x44');
INSERT INTO SHT3X (name, I2C, address) VALUES ('s1',      '-',     '-');
```

## 4. 三类引用

**(1) `$变量` 引用**——把目标变量的当前结果并入本变量的元数据：

```sql
CREATE TABLE Ema (name String, alpha String, src String, field String);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$th0', 'v0');
```

`$th0` 指向先前声明的变量（通常是 Daemon）。每次调用前框架读取目标：
`@Vars` / `@Alias` 标量 → 按列名填入；表结果 → **整个结果表合并进**本变量的 `data`。

**(2) `$(表达式)` 引用**——激活时求值为数字，填入所在列：

```sql
INSERT INTO Example (name, gain) VALUES ('ex', '$(base * 2 + 1)');
```

表达式标识符必须能解析到 `@Vars` 数字（结构表或动作脚本的 `@Vars` 块）。

**(3) controller / trigger 流向列**——列名匹配 `(controller|trigger)[0-9]*`
（如 `controller`、`controller2`、`trigger`），值为目标变量名（不带 `$`）：

```sql
CREATE TABLE Relay (name String, controller String, note String);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
```

- `controller`：本变量 `call` 返回后，框架把「元数据 ∪ 结果」转发给控制器变量的
  `play`，最终输出为**最后一个控制器**的返回值（Relay→Timer 即此机制）。
- `trigger`：本变量 `call` 之前，框架先空参调用触发器变量，把其结果表以
  **触发器变量名**为键注入 `data`（驱动里 `data["trig0"]` 取用）。
- 流向目标必须是先前声明的非标量变量（不能是 Alias/Vars）；同一行内不得重复；
  trigger 名不得与 `mode` / `result` / `message` 或本表其他列重名。

## 5. 跨表校验清单（加载期全部执行）

| 规则 | 报错示例 |
| --- | --- |
| 表名对应的 `modules/<表名>.py` 或 `.lua` 必须存在 | `Driver module not found: CHT8305.py or CHT8305.lua` |
| 模块路径不得绝对 / 含 `..` / 反斜杠 / 冒号 / 软链 | `Module path escapes root` |
| Daemon 的 `chunk`、`driver`、`devices` 只能选中 Lua | `Lua daemon requires a Lua driver, not Python` |
| 所有 `$` / `$(...)` 引用必须指向**先前**声明的变量 | `'x' references undefined variable 'y'` |
| 变量名全局唯一 | `Duplicate hardware variable name` |
| 同一 UART 路径不得被两个变量独立打开（`proto='virt'` 除外） | `UART path '...' has multiple independent consumers` |
| 驱动源码含 `SINGLE_CONSUMER` 标记行时，同 `(总线路径, 地址)` 只允许一个消费者 | `Single-consumer conflict` |
| Daemon 的 `sources` 只能引用先前声明的 Daemon | `Daemon source '...' must name a previously declared daemon` |

`SINGLE_CONSUMER` 标记写在驱动文件顶层（行首 `SINGLE_CONSUMER`，可带注释），
用于「一颗芯片只允许被一个变量驱动」的器件。

## 6. 内建表：Alias / Vars

不对应驱动文件，声明会话级标量：

```sql
CREATE TABLE Vars (name String, value String, precision Number);
INSERT INTO Vars (name, value, precision) VALUES ('base', '3', '-');
INSERT INTO Vars (name, value, precision) VALUES ('ratio', '2.3456', 2);
CREATE TABLE Alias (name String, alias String);
INSERT INTO Alias (name, alias) VALUES ('out', 'relay0');
```

- `Vars`：数字标量，值可为数字字面量或 `$(...)`（引用其他 `@Vars` 数字）；
  供表达式与 Number 列引用。可选 `precision` 列（0..15）只影响渲染到动作参数
  的小数位，不影响表达式内部的浮点计算；`-` 表示使用缺省的 `.15g` 格式。
- `Alias`：文本别名，把设备名间接化（动作表头 `out.test` 实际派发给 `relay0`，一层间接），
  也可被普通列用 `$name` 引用填入文本（例如账号/密码）。
- 同名 `--var`/`--var-env` 会在**激活前**覆盖 Alias/Vars 行，所以 `build()` 就要
  登录的驱动也能拿到注入值；表内仍保留声明缺省值，`query`/`hardware` 不会回显覆盖值。
  只覆盖这两张表，Lua/Daemon 等硬件变量不受影响。

## 7. `proto='virt'`：无硬件验证

器件行的 `proto` 列填 `'virt'` 时走虚拟总线（详见 `references/virt-model.md`），
不打开物理设备：

```sql
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('th0', 'lib/sensor_daemon.lua', 'CHT8305', 'virt',
          '/dev/i2c-1', '0x40', '50', 'T:f|H:f', '16');
```

要求该驱动内嵌 `<驱动>_VIRT` 虚拟模型，否则**响亮报错**（绝不静默回落真机）。
另有整总线级虚拟化：总线行的 `path` 直接写 `virt-<名字>`（如 `virt-bus0`），
该总线 open 即虚拟总线。

## 8. HTTP 总线与 Qsont 云端网关

`HTTP` 表与 I2C/SPI/UART 同级：每行声明一个服务端点会话（`base` 为无凭据的
`http(s)://` URL，`timeout` 毫秒缺省 10000）。**回环主机（`127.0.0.1` /
`localhost` / `[::1]`）默认可用，其余主机需要 `--allow-hardware`**——与串口
`loop://` 同一安全口径。

```sql
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', 'http://127.0.0.1:8000/api/v1', 5000);
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device) VALUES ('qs', '$cloud', 'iot_01', 'pass123', 1);
```

`Qsont` 是 qsont iot-server 的 IoT 设备客户端（`HTTP` 列用 `$会话` 引用）：
`build` 用 `user`/`pass` 登录换 JWT（401 自动重登），`device` 为服务器上已注册
的设备 ID（不在 build 里静默注册账号/建设备）。动作分派列叫 **`op`**（`mode`
是宿主保留键）：

| op | 参数 | 说明 |
| --- | --- | --- |
| `push`（给了 `key` 时可省 op） | `key` + `value` | POST /data 单条 |
| `batch` | `items` = `k=v\|k2=v2` | POST /data/batch |
| `pull` | — | GET /commands/pending → `{count, commands=JSON 串}` |
| `ack` | `cmd`（+`status` 缺省 executed） | PUT /commands/{id}/status |
| `online` | `online`（0/1，缺省 1） | PUT /devices/{id}/status |
| `bind` | `key` = 对方给出的 device_key | POST /devices/bind 绑定**他人创建的**设备；成功后本会话自动改用该设备 id，持久化需同步更新 `device` 列 |
| `unbind` | — | DELETE /devices/{id}/unbind（只能解绑绑定来的设备） |
| `devices` / `latest` | `latest` 可带 `key` | GET 设备列表（含绑定设备）/ 最新数据点 |
| （缺省，无 key 无 op） | 整个 payload | **autopush**：controller 转发来的结果表剔除框架/结构键后整批上推——传感器行写 `controller1='qs'` 即可让每次采样自动上云 |

**mobile ↔ iot 跨账号关联**靠绑定：mobile 账号建设备给出 device_key → 机器人 `op='bind'` 绑定
→ 之后机器人推数据/`pull` 拉 mobile 发来的指令并 `ack`，mobile 查数据。

`HTTP` 总线也可脱离驱动独立使用：动作行直接给 `method`/`path`（如
`cloud.method cloud.path; $("GET") $("/devices");`）即透传执行一次请求，
返回 `{result, status, body, headers}`。范本：`robots/qsont.sql` +
`scripts/qsont.mt`。HTTP 无 virtbus/virt 模型——无硬件验证用本地回环假服务器
（`tests/test_qsont.py`）。

## 9. Shell 宿主命令驱动

`Shell` 是通用宿主命令驱动（软件资源，非总线）：`call` 收一条命令字符串，
经平台 shell（POSIX `/bin/sh -c`、Windows `cmd.exe /c`）执行，返回
`{result, code, out, err, truncated}`。**非零退出码是正常完成**（`code` 携带
退出码），仅启动失败/超时返回 ERR（超时时仍带回已捕获的部分输出）。

```sql
CREATE TABLE Shell (name String, timeout Number);
INSERT INTO Shell (name, timeout) VALUES ('sh', 10000);  -- timeout 毫秒，缺省 10000
```

```mt
@Action
sh.cmd;
$("echo\thello");     # 词间用 \t 转义（shell 视 TAB 为参数分隔）
$("exit\t3");         # → result="OK", code=3
@
```

硬纪律：

- **整个能力默认拒绝，激活需要 `--allow-hardware`**（与物理设备、非回环 HTTP 同门）；
  命令以宿主用户权限与环境在当前目录执行，不是沙箱，边界见 docs/security.md。
- MT 单元格按空白切分、不接受字面空格——命令词间用 `$("a\tb")` 的 `\t`
  转义；含字面空格的复杂命令用 `--var CMD="..."` 传入后写 `$(CMD)`。
- 上限：命令 64 KiB、单流输出 1 MiB（超限截断并 `truncated=true`）、
  超时 1..60000 ms（逐次可用 `timeout` 参数覆盖 build 缺省）。
- 超时/取消**尽力**击杀进程树（POSIX 进程组、Windows `taskkill /T`）；
  逃到新会话的子孙进程不保证被杀。
- 无 virt 模型：`proto='virt'` 写在 Shell 行上会因找不到 `SHELL_VIRT`
  响亮报错。范本：`robots/shell.sql` + `scripts/shell.mt`。

## 10. query 与 apply-sql

**`query --sql`** 只接受 `SHOW TABLES;` 和 `SELECT * FROM 表 [WHERE 列=值 AND ...];`——
WHERE 只支持字符串等值匹配，配合 `-` 继承语义；命令形态见
[docs/cli.md](../../../docs/cli.md)。

**`apply-sql --sql`** 热应用（对已激活会话；不改磁盘文件）：

- 接受 `CREATE` / `INSERT` / `DELETE` / `DROP` / `UPDATE`，拒绝 `SELECT` / `SHOW`。
- 批内隔离：`UPDATE` 重写的表本批内不能再 `INSERT`/`DELETE`；`DROP` 的表本批内不能再动；
  与 `CREATE` 混用同理——需要混合操作时分多批执行。
- `UPDATE` 语义是**删行重建**（对硬件而言是断电重建），命中行按 WHERE 等值匹配。
- 全批先在副本上校验、失败整体回滚；被引用的变量不允许删除。
- 批内若写入 `Action` 瞬态表，热应用后会立即执行一次该动作矩阵然后清空
  （`DROP TABLE Action` 被禁止）。
- 成功回执示例：`已生效：新增 1 个变量，删除 0 个变量，热更新 1 行（断电重建）`。
