# 驱动模块（.lua）

技能 `pymybot-scripting` 参考文件。仓库根为 `mybot/`（Python 主线）。
实现：`pymybot/runtime.py`（LuaState 沙箱与 `__hal_call` 桥）、`pymybot/hardware.py`
（生命周期与 controller/trigger 转发）、`modules/lib/`（驱动框架与 HAL）。

## 1. 生命周期与运行环境

- **普通硬件变量各有独立 Lua 状态**（LuaJIT 2.1）。多器件 Daemon 在一个状态中为各器件
  创建独立环境；`require_driver` 将入口绑定到调用者环境，实例状态隔离，HAL/helper 共享。
- 沙箱：`python` / `io` / `debug` 被删；`package.loaders` 受限；拒绝 Lua 字节码；
  单文件 ≤8 MiB；指令计数钩子 + JIT 开关实现协作预算（阻塞的原生 I/O 不可中断）。
- 文件加载：宿主注入 `__mpath`，`__mpath.resolve("lib/xxx.lua")` 把模块相对路径解析为
  实际文件；驱动内 `dofile` / `loadfile` 受同一解析器约束。
- 三个入口全局函数（框架按序调用）：
  - `build(data)`：激活时初始化（打开/配置器件）；
  - `call(data)`：每次动作派发；
  - `destroy(data)`：去激活收尾（**尽力释放**：资源不可用就跳过动作、仍返回 OK）；
  - `read(data)`：可选快照（`sample` 命令与守护采样用；缺省回退到 `call`）。
- `data` 表的构成：**结构元数据 ∪ 本次动作参数 ∪ trigger 结果**
  （trigger 结果以触发器变量名为键注入）。
- **返回值契约**：非空 Lua 表；若含 `result` 键必须恰为 `"OK"`。
  推荐成功 `{ result="OK", ...字段 }`，失败 `err("原因")`（生成
  `{result="ERR", message=...}`）。无 `result` 键的非空表也合法，但推荐显式带 OK。
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
| `http_request(fd, method, path, headers, body)` | method ∈ GET/POST/PUT/DELETE/PATCH；**path 只允许相对路径**（绝对/scheme-relative 一律拒绝）、ASCII 且无空格；返回表 `{result, status, body, headers}`——**HTTP 4xx/5xx 也是 `result="OK"` 的合法响应**（status 携带状态码，3xx 不跟随重定向），仅传输层失败返回 `result="ERR"`；请求体/响应体上限 4 MiB |

其他：

- `milli_sleep(ms)`：阻塞（上限 4294967ms）。
- Camera：`HAL.camera_open(device, w, h)` / `HAL.camera_capture(handle, options)` /
  `HAL.camera_close(handle)`；文件图片必须落在 `--camera-src-dir` 内。
- **不支持的后端会响亮报错**（`HAL: xxx is not supported by the portable backend`）：
  `gpio_*`、`pwm_*`、`speaker_*`、原生 `open/ioctl/read/write/termios` 族。
  需要这些外设时用受支持总线写协议实现。
- 未加 `--allow-hardware` 时：物理 `i2c_open` / `spi_open`、非 `loop://` 的 `uart_open`、
  非文件的 camera 采集、**非回环主机的 `http_open`** 一律拒绝
  （回环 = `127.0.0.1` / `localhost` / `[::1]`，与串口 `loop://` 同一口径）。

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
