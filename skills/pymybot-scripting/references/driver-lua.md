# 驱动模块（Python / Lua）

Source: 驱动契约与信任边界的权威是 [docs/architecture.md](../../../docs/architecture.md) 与
[docs/security.md](../../../docs/security.md)；实现见 `pymybot/native.py`、`pymybot/runtime.py`、
`pymybot/hardware.py` 与 `modules/lib/`，本文件只留写驱动的硬规则与 HAL 接口表。

## Python 原生入口与 SQL 选择

- 普通表名选择 `<表名>.py` / `<表名>.lua`，`Alias` / `Vars` / `Daemon` 除外。
  按模块根顺序逐根查找（`--module-path` 可重复），**每根内 `.py` 优先于 `.lua`**；
  较早根的 Lua 优先于较晚根的 Python。无需新增 SQL 语言列。
- 必须实现 `build(self, data)`、`call(self, data)`；可选 `read(self, data)`（缺省回退到
  `call`）和 `destroy(self, data)`（尽力清理）。`data` 是已解析元数据、动作参数、触发结果
  合成的字典，`mode` 是本次入口名。返回非空、可转 JSON 的字典；`result` 可省略，或以
  `"OK"` 表示成功、`"ERR"` + `message` 表示失败；不要返回裸标量、空字典或 `None`。
- `context.call(operation, *args)` 使用宿主 HAL 操作名，例如 `uart_write` / `uart_read`、
  `i2c_transfer` / `spi_transfer`、`close_handle` / `sleep_ms`；不是下文的 Lua 便利函数名。
  字节数组使用 Python list（索引从 0 起）。长循环要主动调用 `context.check()`——
  超时/取消不能硬中断阻塞的原生调用或不协作的循环。
- 每个 SQL 行有独立的模块命名空间与 `Driver(context)` 实例，但**不是沙箱、也不是进程隔离**；
  `check` 只编译源码，不执行导入、构造器或生命周期方法，入口是否齐全在激活时才检查。
  权限边界与 `--allow-hardware` 的作用范围见 docs/security.md 的 Native driver trust 一节。
- 内置 I2C/SPI/UART/TCP/HTTP/Camera/Shell 普通表已是 Python，HAL 总线句柄仍与 Lua 器件驱动共享。
  Python I2C/SPI/UART 将显式 `proto=virt` 或 `virt-*` 路径的总线打开为纯内存 HAL 句柄并禁止
  物理访问；既有 `proto=virt` 搭配 `/dev/...` 路径写法仍保持虚拟语义，绝不回落真机。
  Lua 器件驱动继续复用现有 `virtbus` 模型和逐运行时隔离；其他原生模块没有自动虚拟模型。
  **Daemon chunk 仍只加载 Lua 驱动**，按根顺序选中 Python 时静态检查报
  `Lua daemon requires a Lua driver, not Python: <驱动>`。

可运行的 Python + SQL + MT 回环示例见 [使用指南：写一个驱动](../../../docs/Introduce.md#写一个驱动)。

## TCP 的 MT 接口

`modules/TCP.py` 使用标准库 socket，经宿主 HAL 管理连接。SQL 只配置三个字段：

```sql
CREATE TABLE TCP (name String, host String, port Number);
INSERT INTO TCP (name, host, port) VALUES ('net', '127.0.0.1', 9000);
```

`host` 必须是 IPv4/IPv6 字面量（不支持域名或 scope），`port` 为 1..65535。
激活仅校验配置，不联网；每个 SQL 行有独立连接。回环地址无需物理硬件权限，
非回环连接需要 `--allow-hardware`。`read` / `sample` 只返回连接与配置元数据，不接收数据。

| MT 字段 | 入参与行为 |
| --- | --- |
| `net.connect` | `1` 建立连接；已连接时不重新连接 |
| `net.close` | `1` 关闭连接；重复关闭成功 |
| `net.timeout` | 1..60000 毫秒，默认 1000，修改后用于后续连接、发送与接收 |
| `net.num_recv` | 单次接收上限 1..512 字节，默认 512，修改后持续生效 |
| `net.send_hex` | 十六进制文本，如 `$("00FF80")`；允许来自变量的 ASCII 空白，不接受奇数位或非十六进制字符 |
| `net.send_str` | UTF-8 文本，如 `$("你好")`；编码后单次最多 512 字节 |
| `net.recv_hex` | `1` 接收，回执含 `recv_hex`（大写、空格分隔）、`received` 与 `status` |
| `net.recv_str` | `1` 接收 UTF-8，回执含 `recv_str`、`received` 与 `status` |

操作旗标为 `0` 时不执行；一次派发最多一个有效操作，可附带 `timeout` / `num_recv` 设置。
MT 普通单元格只接受数字，文本须使用 `$("...")` 或字符串表达式；表达式内不能包含
实际空白，含空白的文本可放在 `@Struct` JSON 字段中再通过表达式引用。接收字段可按普通
MT 捕获规则读取，例如 `net.recv_hex net.reply; 1 $reply=recv_hex;`。

TCP 是字节流：接收最多读取 `num_recv` 字节，不保证填满或返回一个完整报文。
`status` 为 `data` / `timeout` / `eof`；超时不是断连，EOF 后关闭连接。
UTF-8 跨次接收的未完整字符会暂存，切换到 `recv_hex` 时先返回这些原始字节；
非法 UTF-8 或 EOF 时仍有不完整字符会报错，不替换乱码。
发送回执的 `sent` 只表示 socket 接受的字节数，不代表设备已执行；发送失败或取消后关闭连接，
不自动重连或重放，去激活会兜底关闭未显式关闭的连接。样例 [robots/tcp.sql](../../../robots/tcp.sql)
和 [scripts/tcp.mt](../../../scripts/tcp.mt) 需要先在本机对应端口启动 TCP 回显服务。

以下章节专述保留的 **Lua** 驱动协议与工具。

## 1. 生命周期与运行环境

- **普通 Lua 硬件变量各有独立 Lua 状态**（LuaJIT 2.1）。多器件 Daemon 在一个状态中为各器件
  创建独立环境；`require_driver` 将入口绑定到调用者环境，实例状态隔离，HAL/helper 共享。
- 环境收紧（**不是安全沙箱**）：移除 `python` / `debug`，`io` 仅保留 stderr；
  `package.loaders` 受限，拒绝 Lua 字节码；LuaJIT FFI 仍可用，只运行审阅过的驱动。
  单文件 ≤8 MiB；指令计数钩子 + JIT 开关实现协作预算（阻塞的原生 I/O 不可中断）。
- 文件加载：宿主注入 `__mpath`，`__mpath.resolve("lib/xxx.lua")` 把模块相对路径解析为
  实际文件；驱动内 `dofile` / `loadfile` 受同一解析器约束。
- 入口是全局函数而非方法：`build(data)` 激活初始化（打开/配置器件）、`call(data)` 每次动作派发、
  `read(data)` 可选快照（`sample` 与守护采样用，缺省回退 `call`）、`destroy(data)` 去激活收尾
  （**尽力释放**：资源不可用就跳过动作、仍返回 OK）。
- `data` 表 = **结构元数据 ∪ 本次动作参数 ∪ trigger 结果**（trigger 结果以触发器变量名为键注入）。
- **返回值契约**同上面的 Python 节：非空 Lua 表，含 `result` 键时必须恰为 `"OK"`；
  失败用 `err("原因")` 生成 `{result="ERR", message=...}`。
- **引用读取失败会阻断下游执行**，不能把 ERR 合并后继续派发。快照尚未产生时可返回
  `{result="ERR", code="NOT_READY", message="no sample yet"}`：仅下游初始化时省略这份
  未就绪元数据，不制造样本；动作和采样仍报错。其他读取错误即使在初始化时也会传播。

## 2. 声明式写法（推荐）：require_driver

`modules/CHT8305.lua` 是标准范本。骨架：

```lua
-- 1 行前导：加载驱动框架（require_driver 由它定义；HAL/print_table 由框架代劳）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules")
                 :match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

require_driver("i2c", {                -- 总线四选一："i2c" / "spi" / "uart" / "http"
    name = "CHT8305",                  -- 驱动名（日志与错误定位用）
    -- i2c_addr_default = 0x69,        -- 可选：硬件固定地址器件可省略 address 列

    build = function(ctx, data)
        -- ctx.fd / ctx.addr（仅 i2c）/ ctx.state / ctx.name
        if i2c_write_multi(ctx.fd, 0x02, 0x80) ~= 0 then
            return err("CHT8305 not responding")
        end
        return { result = "OK" }
    end,

    call = function(ctx, data)
        local v = i2c_read(ctx.fd, 2)
        if v < 0 then return err("read failed") end
        return { result = "OK", T = v * 165.0 / 65535.0 - 40.0 }
    end,

    -- destroy 可省略（缺省空操作）；需要收尾时才写：
    -- destroy = function(ctx, data) ... return { result = "OK" } end,

    -- state = {},                     -- 可选：跨 call 共享的模块级状态容器
})
```

框架包装层统一做了：`arg_table` 参数校验 + `proto=virt` 前置 + 总线校验
（i2c：fd/address 存在性 + `i2c_set_addr`；spi：fd；uart/http：fd ≥ 0），
然后以 `ctx` 调用用户函数。用户函数内可直接使用 HAL 全局与驱动文件里的 local
（闭包链保留）。http 总线的 `fd` 来自 `HTTP` 列的 `$会话` 引用
（范本 `modules/Qsont.lua`）。

## 3. 传统写法：全局函数

`modules/Timer.lua` / `modules/Relay.lua` 是范本。要点：

```lua
local mpath = (__mpath or dofile(...))
dofile(mpath.resolve("lib/HAL.lua"))          -- 必须先加载 HAL
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

function build(data)
    local ok, ek = arg_table(data)            -- 每个入口的第一行
    if not ok then return ek end
    return { result = "OK" }
end

function call(data)
    local ok, ek = arg_table(data)
    if not ok then return ek end
    local fd, addr, e = i2c_pair(data)        -- I2C：存在性 + set_addr
    if fd == nil then return e end
    ...
end
```

`arg_table` 必须保持在入口首个调用位置（它代调 `proto=virt` 前置）。
I2C 校验两档：`i2c_pair`（存在性 + set_addr）/ `i2c_check`（仅存在性，
供「额外校验须在 set_addr 之前」的驱动）。

## 4. HAL API 参考

UART（pyserial）：

| 函数 | 说明 |
| --- | --- |
| `uart_open(path, baud)` | fd ≥0 成功，-1 失败；`loop://` 为无硬件回环 |
| `uart_close(fd)` / `uart_flush(fd)` | |
| `uart_write(fd, byte_table)` | 字节表（1-based），返回写入数 |
| `uart_read(fd, n, timeout_ms)` | 返回字节表或 nil；单次上限 `UART_IO_MAX_BYTES`、超时上限 `UART_READ_MAX_MS` |

I2C（pyftdi MPSSE / Linux smbus2；详见 `modules/lib/hal/i2c.lua`）：

| 函数 | 说明 |
| --- | --- |
| `i2c_open(path)` / `i2c_close(fd)` | 路径如 `/dev/i2c-1` 或 `ftdi://ftdi:232h/1` |
| `i2c_set_addr(fd, addr)` | 选从地址 |
| `i2c_write_reg(fd, reg, val)` / `i2c_read_reg(fd, reg)` | 单寄存器 |
| `i2c_write_multi(fd, reg, ...)` | 单事务写 `[reg, 数据...]`；返回 0 成功 |
| `i2c_read(fd, n)` | 无指针纯读 n 字节，合并为大端数字；<0 失败 |
| `i2c_read_multi(fd, reg, n)` | 指针写 + 读 n 字节合并大端数字；**>6 字节精度丢失**，用 `read_block_bytes` |
| `i2c_read_multi_bytes(fd, reg, n)` / `i2c_read_bytes(fd, n)` | 字节表版本 |
| `i2c_write_reg16` / `i2c_read_reg16` | 16 位寄存器地址变体 |

SPI（pyftdi / Linux spidev；详见 `modules/lib/hal/spi.lua`）：

| 函数 | 说明 |
| --- | --- |
| `spi_open(path)` | 路径如 `ftdi://ftdi:232h/1?cs=0` 或 `/dev/spidev0.0` |
| `spi_setup(fd, mode, bits, speed)` | |
| `spi_write(fd, val [, delay_us])` / `spi_read(fd [, delay_us])` | 单字节 |
| `spi_write3` / `spi_write_multi(fd, data [, delay])` / `spi_read_multi(fd, n)` / `spi_xfer_full(fd, data)` | 多字节与全双工 |

HTTP（标准库 urllib；`modules/HTTP.lua` 是总线范本、`modules/Qsont.lua` 是驱动范本）：

| 函数 | 说明 |
| --- | --- |
| `http_open(base, timeout_ms)` | 只校验不建连：base 须为无凭据/无 query/无 fragment 的 `http(s)://` URL（`bus.http_url_ok`），超时上限 `HTTP_TIMEOUT_MAX_MS`；fd ≥0 成功 |
| `http_close(fd)` | 注销会话句柄 |
| `http_request(fd, method, path, headers, body)` | method ∈ GET/POST/PUT/DELETE/PATCH；**path 只允许相对路径**、ASCII 且无空格；返回 `{result, status, body, headers}`——**4xx/5xx 也是 `result="OK"` 的合法响应**（`status` 携带状态码，3xx 不跟随），仅传输层失败返回 `result="ERR"`；请求体/响应体上限 4 MiB |

其他：

- `milli_sleep(ms)`：阻塞（上限 4294967ms）。
- Camera：`HAL.camera_open(device, w, h)` / `HAL.camera_capture(handle, options)` /
  `HAL.camera_close(handle)`；文件图片必须落在 `--camera-src-dir` 内。
- **不支持的后端会响亮报错**（`HAL: xxx is not supported by the portable backend`）：
  `gpio_*`、`pwm_*`、`speaker_*`、原生 `open/ioctl/read/write/termios` 族。
  需要这些外设时用受支持总线写协议实现。
- 未加 `--allow-hardware` 时，物理 `i2c_open` / `spi_open`、非 `loop://` 的 `uart_open`、
  非文件的 camera 采集与非回环 `http_open` 一律拒绝（口径见 docs/security.md）。

## 5. drv_common 工具函数

| 函数 | 用法 |
| --- | --- |
| `err(msg)` | 统一失败表 `{result="ERR", message=msg}` |
| `arg_table(data)` | 入参必须是表；代调 virt 前置。`(ok, e)` 两返回 |
| `i2c_check(data)` / `i2c_pair(data)` | 见第 3 节；成功 `(fd, addr, nil)`，失败 `(nil, -1, err表)` |
| `finite_of(v)` | tonumber + 拒绝 NaN/inf，非法返回 nil（**数值入参都应过这道防线**，NaN 是 truthy 会穿透 `or` 兜底） |
| `int_or(v, def, lo, hi)` | 数值列 → 钳到 [lo,hi] 的整数，非法/`-` 归 def |
| `num_or(v, def)` | 数值列 → 数字，非法回落 def（不钳不取整） |
| `clampi(v, lo, hi)` | 整数钳位（NaN/inf 回落 lo） |
| `read_block_bytes(fd, reg, n [, chunk])` | 分块读寄存器块 → 1-based 大端字节表；chunk 缺省 6 |
| `guard_build(rollback, fn, data)` | build 全程 pcall：异常折 ERR 并回滚已打开句柄（防 fd 泄漏） |
| `dbg_table(title, t)` | 调试打印收到的表 |

## 6. 数值纪律（防 NaN 穿透）

LuaJIT 下 `math.floor(NaN)=NaN` 且 NaN 与任何数比较为假，`tonumber(v) or def`
挡不住 NaN。驱动解析任何数值入参/样本列都必须走 `finite_of` / `int_or` / `num_or`
（仓内既有审计结论，勿再引入本地拷贝）。
