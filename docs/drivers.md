# 硬件变量（驱动）清单

> **清单与计数以 `modules/` 目录为准**（本页是速查索引，可能滞后于代码；`ls modules/*.lua` 即权威清单）。结构脚本里每张 `CREATE TABLE <矩阵名>` 对应加载 `modules/<矩阵名>.lua`。各驱动的协议细节与其内嵌 `<矩阵名>_VIRT` 仿真模型见 [virtbus.md](virtbus.md)。
>
> **计数口径**（README 与架构页引用的数字按此推导，可复算）：`ls modules/*.lua` = 60 = **49 款器件/执行器/系统接口驱动**（本页前六节：舵机/输出 13 + IMU 6 + 气压/环境/光 11 + 测距/闪电 3 + ADC/电源 11 + 气体/医疗/其他 5）+ **3 条总线**（`I2C`/`SPI`/`UART`）+ **8 个框架/工具驱动**（`Relay`/`dummy`/`Monitor`/`Kalman`/`Ema`/`bitcompat`/`Camera`/`Sim`，即最后一节；2026-09-25 #8 起 Lua 协议驱动轨道已删，`LlmOpenAI`/`LlmDeepSeek`/`LlmAnthropic` 不再有对应 `.lua` 文件）。注意 `GPIO`/`PWM`/`Speaker` 是**系统接口/执行器驱动**、归在 49 里（不是总线）；`bitcompat` 是纯 Lua 兼容库、不在 `lib/` 下。`modules/lib/` 另有 29 个共享库（`find modules/lib -name '*.lua' | wc -l`，含 `asound`、`virtbus/regmap.lua` 与 `hal/` 下 5 个总线域分块），不计入 60。本页各节点名的模块集合与 `ls modules/*.lua` **双向**相等、以及上面这串分项数字，都由 `scripts/check_doc_paths.py` 逐次核对（漏登记一个新驱动、留着一个已删驱动、或分项加起来对不上总数，都判失败；见 [testing.md](testing.md)「跨源一致性校验」）。

## 舵机 / 输出执行器

| 驱动 | 说明 |
| --- | --- |
| `PCA9685` | 16 路 PWM 舵机控制器（I2C），`Servo` 的 controller |
| `Servo` | 舵机抽象（角度 → 脉宽，max/min/offset 标定） |
| `SCSCL` | 飞特总线舵机（UART，FT-SCS 大端帧；位置/时间/速度/扭矩 + 反馈块读取 + 站号烧写） |
| `Timer` | 定时/延时（relay-test 链路的执行端） |
| `MCP4725` | 12 位 DAC（I2C） |
| `AD9833` | DDS 波形发生器（SPI，写-only） |
| `TPL0501` | 256 抽头数字电位器（SPI，写-only） |
| `PCF8574` | 8 位准双向 IO 扩展器（I2C） |
| `LCD1206` | 16x2 字符液晶（HD44780 + PCF8574 I2C 背包，4 位模式）：清屏 / 背光 / 分行文本 |
| `GPIO` | Linux GPIO |
| `PWM` | Linux PWM |
| `H03ARR` | H03A 电机驱动 |
| `Speaker` | 声卡音频输出（ALSA ffi 直驱，经 `lib/asound.lua`）：预设波形（sine/square/triangle/sawtooth/noise/silence）+ 音调 + 时长阻塞播放；`simulate='1'` 为仿真模式 |

## IMU / 姿态

| 驱动 | 说明 |
| --- | --- |
| `MPU6050` | 六轴 IMU（I2C） |
| `ADXL345` | 三轴加速度计（I2C） |
| `BMI270` | 六轴 IMU |
| `LSM6DSV` | 六轴 IMU |
| `MLX90393` | 三轴磁力计 |
| `BMM150` | 三轴磁力计 |

## 气压 / 环境 / 光

| 驱动 | 说明 |
| --- | --- |
| `MS5611` | 高精度气压计（I2C，PROM CRC-4） |
| `LPS22HB` | 气压/温度（I2C） |
| `BME280` | 温压湿三合一（I2C） |
| `BME688` | 温压湿 + 气体（I2C） |
| `SHT3X` | 温湿度（16 位命令字 + CRC-8） |
| `CHT8305` | 温湿度（SensyLink，双 ROM ID） |
| `AMG8833` | 8×8 红外热电堆阵列（Grid-EYE） |
| `AS7262` | 六通道可见光光谱 |
| `APDS9900` | 接近/环境光 |
| `BH1745` | 颜色传感器 |
| `BH1750` | 光照度（命令式单字节 opcode） |

## 测距 / 闪电

| 驱动 | 说明 |
| --- | --- |
| `VL53L0X` | ToF 激光测距（8 位指针 + 分页） |
| `VL53L4CD` | ToF 激光测距（16 位指针） |
| `AS3935` | 闪电检测 |

## ADC / 电源监测

| 驱动 | 说明 |
| --- | --- |
| `ADS1015` | 12 位 4 通道 ADC（I2C） |
| `ADS1115` | 16 位 4 通道 ADC（I2C） |
| `ADS1256` | 24 位 ΣΔ ADC（SPI 全双工） |
| `MCP3421` | 18 位 ΔΣ ADC（I2C） |
| `INA219` | 高边电流/功率监测（I2C） |
| `INA226` | 高精度电流/功率监测（真双 ROM ID） |
| `INA3221` | 三通道电流/电压监测 |
| `MAX17043` | 单节锂电电量计（ModelGauge） |
| `MAX17048` | 电量计（MAX17043 同族增强） |
| `LTC2944` | 多节电池电量计 |
| `EMC2101` | 风扇控制 + 温度 |

## 气体 / 医疗 / 其他传感器

| 驱动 | 说明 |
| --- | --- |
| `SGP30` | 空气质量 CO2eq/TVOC（I2C） |
| `SDS011` | 激光颗粒物（UART） |
| `MHZ19` | CO2 红外（UART） |
| `MAX30102` | 心率/血氧 PPG（环形 FIFO） |
| `MT6826S` | 磁编码器（SPI 全双工） |

## 框架 / 总线 / 工具

| 模块 | 说明 |
| --- | --- |
| `I2C` / `SPI` / `UART` | 总线变量，器件行以 `$` 引用挂载 |
| `Relay` | 参数转换转发（无硬件自检链路的一端） |
| `dummy` | 桩替身，打印参数即返回 |
| `Kalman` | 一维卡尔曼滤波（虚拟传感器，配 `Q`/`R`） |
| `Ema` | 指数移动平均（配 `alpha`∈(0,1]） |
| `Monitor` | 消费 `$` 引用快照的观察/决策变量 |
| `bitcompat` | Lua 5.1/5.3 位运算兼容库（非驱动） |
| `Camera` | **摄像头驱动**：V4L2 mmap 取帧、只取硬件编码的 MJPEG（ffi，无第三方库）；`src=<图片>` 为仿真模式。agent 模式的 `capture_image` 工具用它。调用参数可带 `width`/`height`（正整数，须同给同缺）：与上次请求不同即重开设备重协商 `VIDIOC_S_FMT`，返回表报**实际协商尺寸**（设备可能就近调档） |
| `Sim` | **仿真器桥接驱动**：把语义动作以行文本发到 `mybot-sim`（`sim/` 下的 GLFW 蜘蛛仿真器）的 AF_UNIX socket，只传「动作 + 速度」不传关节角。`range` 走独立 sensor socket；**仿真器缺席＝静默成功**（可视化从端不该打断动作脚本），感知侧相反。协议、动作码 0–10 与场景持久化见 [sim.md](sim.md) |

> 不依赖 HAL 的模块（如滤波器、virtbus 底座）可用 `luajit`/`lua5.4` 独立调试。
> 模型协议族（OpenAI 兼容 / DeepSeek / Anthropic）由 Rust agent 内建（`agent/src/provider.rs`），
> 2026-09-25 #8 起不再有 Lua 协议驱动；切换方式与安全边界见 [agent.md](agent.md)。

## 驱动契约

硬件/总线驱动现使用 `require_driver` 声明式框架（见下 `drv_common` 公共原语表），
框架自动处理 `arg_table` 入参校验与总线校验（`i2c_pair` / `fd≥0` 等），驱动只写
业务闭包（`build`/`call` 接收 `ctx.fd`/`ctx.addr`）。非驱动模块（`Relay`/`dummy`/
`Camera`/`GPIO`/`PWM` 等）仍用独立 `function build(data)` 模式，未经 `require_driver`
迁移。公共样板在 `modules/lib/drv_common.lua`。
可机器核对的部分由 `luajit test/test_driver_contract.lua`（驱动入口契约 sweep）
逐模块断言：能加载、三入口齐全、非表入参返回 ERR 契约表而非抛 Lua error——
豁免只有 `bitcompat`（纯 Lua 库）与 `Camera`（头注声明不挂 `arg_table`）。
`run_all.sh` 另有三道 grep lint（`arg_table` 首调用、模块路径 `__mpath` 引导、`data.` 裸读的 nan 回落）。

### 入口函数集

已迁移的硬件驱动通过 `require_driver` spec 表声明以下入口（框架自动生成全局
`build`/`call`/`destroy`）；非驱动模块（`Relay`/`dummy` 等）仍定义独立全局函数。

| 函数 | 调用时机 | 约定 |
| --- | --- | --- |
| `build(data)` | 装配期（`active()`，按声明序） | 打开/配置资源并做在位自检；**必须有** |
| `call(data)` | 每拍派发（或 `$` 引用读取） | 一次完整动作/读数；**必须有** |
| `destroy(data)` | 销毁期（倒序，`deactivate()`） | 尽力释放，见下 |
| `read(data)` | `$` 引用快照读取（可选） | 定义即**替代** `call`；宿主**不做 `ensureOk`**（读是数据流不是动作），返回值可为标量；`Ema`/`Kalman`/`Monitor` 定义它并忽略入参 |
| （驱动未定义 `read`） | 同上 | 回退 `call(data)`（`mode="call"`），即缺省 `play({})` |

> **`data.mode` 是宿主注入的保留字段**（取值 `build` / `call` / `read` / `destroy`），
> **结构脚本里不要用 `mode` 当数据列名**：宿主在 build 期会
> `metadata.put("mode", "build")` 把它覆盖掉（`src/luavar.cpp` 的 `riseImpl`），
> 症状是驱动在 `build` 里读到的永远是 `"build"` 而不是你配的值。需要同类语义时
> 换个列名（如 `looping`）。

### 返回值契约（halt-on-error）

每次 `build`/`call`/`destroy` 都必须返回**表**：

- 成功：`return { result = "OK" }`（可附带数据字段 `v0`/`out`/`value`…）
- 失败：`return err("<文案>")`（`drv_common.err` 构造 `{result="ERR", message=…}`）

宿主侧由 `MatrixVars_Hardware::ensureOk` 统一检查：非表、空表、`result="ERR"`、
`result` 非 `"OK"`/`"ERR"` 一律抛错。**漏写 `return` 会被判为失败**，不会静默当成功。

### 参数校验顺序

已迁移驱动使用 `require_driver` 框架，`arg_table` + 总线校验由框架包装层自动完成，
驱动闭包直接接收 `ctx.fd`/`ctx.addr`：

```lua
require_driver("i2c", {
    name = "EMC2101",
    build = function(ctx, data)
        local fd = ctx.fd   -- 框架已完成 arg_table + i2c_pair
        -- 业务逻辑
    end,
    call = function(ctx, data)
        local fd = ctx.fd
        -- 业务逻辑
    end,
})
```

- 框架按总线类型分派校验器：`"i2c"` → `i2c_pair`（`fd`/`address` 存在性 + `set_addr`），
  `"spi"` → `fd` 非 nil（不查 ≥0）、`"uart"` → `fd≥0`（fd 0 合法）；报错口径与旧内联版本逐字对齐
- 若驱动的**额外**校验须先于 `set_addr`，可在 build 闭包里用 `i2c_check`
  （仅存在性）自行把 `set_addr` 留到校验通过之后——**目前无驱动使用此法**：
  `MS5611` 的 OSR 档位、`PCF8574` 的地址族都在 build 内、位于框架 `i2c_pair` 的
  `set_addr` **之后**校验；因 `set_addr` 仅配置 fd 不碰总线，「非法配置值不碰总线」
  依然成立（见 `PCF8574.lua` 头注）
- 器件地址硬件固定、`address` 列可省者（当前仅 `AMG8833` 0x69）
  可用 `require_driver` 的 `i2c_addr_default` 字段指定固定地址——
  `i2c_pair` 视 `address` 为必填，语义不等价，框架对此类器件有特殊处理
  （`MCP4725` 地址虽也硬件固定，但未走 `i2c_addr_default`，`address` 列仍必填）

### drv_common 公共原语

| 原语 | 语义 | 越界/失败语义 |
| --- | --- | --- |
| `err(msg)` | 构造 `{result="ERR", message=msg}` | — |
| `arg_table(data)` | 入参必须是表；附带 `proto=virt` 前置（现主要由 `require_driver` 框架内部调用，驱动通常不直接调） | 返 `(false, err表)` |
| `virt_prepare(data)` | 独立入口：加载 virtbus → 发现并挂载 `*_VIRT` 模型 → inject（`arg_table` 只是它的调用方） | 返 `nil` 或原因串 |
| `i2c_check(data)` | `fd`/`address` 存在性（不碰总线） | 返 `(nil, -1, err表)` |
| `i2c_pair(data)` | `i2c_check` + `i2c_set_addr`（现主要由 `require_driver` 框架内部调用） | 同上 |
| `int_or(v, def, lo, hi)` | 数值列 → 取整并**钳到** `[lo, hi]`；非法/`-` 归 `def` | 钳制（非报错） |
| `num_or(v, def)` | 数值列 → `tonumber`；缺省/非法回落 `def` | 回落（不钳制、不取整） |
| `read_block_bytes(fd, reg, n, chunk)` | 从 `reg` 起读 `n` 字节，返 1 基大端字节表；`chunk` 缺省 6 | 任一读失败返 `nil` |
| `guard_build(rollback, fn, data)` | build 全程 pcall + 失败时回滚句柄 | 抛错折成 ERR 表 |
| `require_driver(bus, spec)` | 声明式驱动框架入口；`bus` ∈ `"i2c"`/`"spi"`/`"uart"`，`spec` 含 `name`/`build`/`call`/`destroy`（可选）；自动生成全局 `build`/`call`/`destroy`，驱动只写业务 delta（`ctx.fd`/`ctx.addr`） | 校验失败返 ERR 表（口径与旧内联对齐） |

`guard_build` 的适用范围是**持有 OS 句柄的 4 个总线驱动**（`GPIO`/`I2C`/`SPI`/`UART`）——
只有它们自己 `open`/申请句柄，所以只有它们需要「半途抛错时回滚」。器件驱动的句柄由
总线变量持有（器件只拿 `fd` 用），**不需要**也不应套这一层：把它推广到器件驱动只会
把 `build` 的入口形态搅乱、并让 param 校验与回滚责任错位。
机械锚点：`grep -c 'guard_build(' modules/*.lua` 应恒为 **4**。

越界语义是**三选一**，由驱动按器件语义显式选择，不要互相「统一」：

- **报 ERR**：参数非法即拒绝（如 `APDS9900` 的 atime 范围；`MS5611` 的 OSR 是
  **混合语义**——非数字/低于 256 报 ERR，介于两档之间向下降档到不大于它的最大档，
  见其 `osr_idx_of` 头注）
- **钳制**：就近吸附到合法边界（`int_or`；`ADS1015`/`ADS1115` 的
  pga/dr/channel 亦为钳制——已复核保留，改报 ERR 属行为变更，需单独评审）
  - 名字刻意不叫 `int_of`：`bus_contract` 里已有一个**同名不同元**的严格判据
    `int_of(v, lo, hi)`（越界/小数返 `nil`，HAL 与 virtbus 用它）。两者在同一个
    Lua 状态里都可见，重名时按 3 参调用会把 `def` 静默绑到 `lo`、区间整体错位
    却不报错——比崩溃更难查，故钳制那份改名 `int_or`（"整数，否则取 def"）。
- **回落缺省**：占位符/非法值取默认（`num_or`）

### 单消费者声明（`SINGLE_CONSUMER`）

如果本驱动的**一次访问跨多个总线事务、且器件侧留有地址或握手相位**，就在模块源里
**行首**声明一行（宿主是纯文本扫描、不执行 Lua；允许前导空白，但写在注释里不算）：

```lua
SINGLE_CONSUMER = "间接窗口 + 握手：地址相位在器件侧，一次访问跨多个 I2C 事务"
```

装配期（`src/hw_factory.cpp` 的 `checkSingleConsumer`）据此按（总线设备路径, 归一化
地址）判重：同一颗器件出现第二个消费者（另一个直连变量，或 `proto` 非 `virt` 的
`@Daemon`）即**加载期报错**并点名双方，不申请任何资源。守护走 `proto=virt`
是内存仿真，不计入。

`@Daemon` 行的**缺列不等于"不参与判据"**（2026-09-21 第七轮审计）：守护侧对这两列
都有缺省，判据按同一规则补全后再登记——

| 列 | 缺列时按什么参与判据 |
| --- | --- |
| `proto` | `i2c`（`sensor_daemon.lua` 的 `cfg.proto or "i2c"`）；只有**显式** `virt` 才跳过 |
| `path` | `spi` → `/dev/spidev0.0`，否则 `/dev/i2c-1`（同上那条 `or` 表达式） |
| `driver`/`addr` | 多器件守护没有这两列，改从 `devices` 列逐个 spec 解析：`driver@addr@f1,f2[:模式][@k=v]`，spec 之间以 `\|` 分隔；报错会点名 `devices[N]` 与驱动名 |

C++ 侧那三个缺省值以 `HwFactory::kDaemonDefault*` 为单点，与 `sensor_daemon.lua`
的缺省表达式由 `test/cpp/test_robot_lifecycle.cpp` 的 `daemon_defaults_match_lua_source`
**读 Lua 源两侧比对**（这类漂移没有运行期症状，只会让判据静默漏判）。

当前声明者：`AS3935` / `AS7262` / `MS5611` / `VL53L0X` / `VL53L4CD`
（各自的器件侧状态与失效形态见 [faq.md](faq.md) 的「一器件一消费者」条）。
这份名单与模块源由 `test/test_driver_contract.lua` **双向钉住**：新增/删除声明而
不同步该测试的期望集合与本文档，守门会红。

**不要**给"每次访问都是单事务"的器件声明它：HAL 的 `i2c_read_reg` /
`i2c_read_multi_bytes` 把寄存器指针写与数据读合并成一次 `I2C_RDWR` ioctl（内核原子），
这类器件允许「主线程直连 + 守护同址采样」并发——`robots/test/` 下 20 个夹具正是
这么写的，乱声明会白白禁掉一种安全且常用的形态。判据与理由详见
[faq.md](faq.md) 的「一器件一消费者」条。

`chunk` 必须 ≤6：HAL 的合并读把整块拼成一个 `double`，超过 6 字节即超
2^53 精度（见 `lib/hal/i2c.lua` 的 `i2c_read_multi` 注释）。

> 未收 `poll_reg`（寄存器轮询）：唯一候选是 `VL53L0X` 的 `wait_reg`，
> `VL53L4CD` 的 `wait_ready` 轮询的是函数而非寄存器——单点抽象不值得。

### destroy 契约：资源不可用即静默成功

框架为绝大多数驱动提供缺省 `destroy`（仅 `return { result = "OK" }`）——省略
`destroy` 字段即走此默认路径，无需手写 `arg_table` + 返回 OK 的样板。需要真正器件
收尾的驱动（停连续读、复位硬件状态、关扭矩等）仍在 `require_driver` spec 里提供
自定义 `destroy` 闭包：

```lua
destroy = function(ctx, data)
    -- 注意：destroy 包装只透传 {state, name}，不含 fd/addr——收尾要用的
    -- 总线句柄/地址从 data 里取（与 PCA9685/ADS1115 等实驱动一致）
    local fd = tonumber(data.fd)
    if fd ~= nil then
        ...与器件状态有关的收尾动作...
    end
    return { result = "OK" }
end
```

收尾不是校验：器件可能因 build 失败或总线先行释放而拿不到 `fd`，此时报 ERR
会把正常收尾变成失败（`--tcp` 会话下即退出码非零）。

**例外**：下列驱动的 `destroy` 在**器件状态收尾失败**时会返回 ERR（不适用「静默 OK」）——
改动它们前先确认对应回归用例与器件语义：

| 驱动 | 触发条件 | 依据 |
| --- | --- | --- |
| `ADS1115` | 缺 `fd`/`address`，或 `set_addr` 失败 | 被回归用例固定（`test/test_ads1115.lua`），不改范 |
| `ADS1256` | 缺 `fd`；停止连续读模式失败 | 器件需先停流再释放总线 |
| `PWM` | unexport 失败（成功时带 `released` 标志） | sysfs 收尾结果如实上报 |
| `SCSCL` | 扭矩关闭短写 | 舵机需确认已卸力，短写即未确认 |

### 位运算与 bitcompat

- 位运算一律走 `modules/bitcompat.lua`（LuaJIT 5.1 无位运算符，
  且它提供 `s8`/`s12`/`s16`/`s16le`/`u16le` 符号扩展原语单点）：
  `local bitc = dofile(mpath.resolve("bitcompat.lua"))`
- 符号扩展**不要**再写 `if v >= 0x8000 then v = v - 0x10000 end`
  （除下述豁免）；调用点直接 `bitc.s16(v)`

### 内嵌虚拟模型（`<矩阵名>_VIRT`）

同文件内定义，`new()` 返回实例，可选 `BUS = "uart"|"spi"` 标记总线类型。
模型走 `lib/virtbus.lua`，与驱动共享同一套寄存器语义。

### 库加载与状态（`_G` 哨兵 / `virt_state`）

两条与「一变量一 `lua_State`」不变式相关的约定，写驱动时要按它推理：

- **共享库首载者胜**：`HAL` / `drv_common` / `bus_contract` / `virtbus` 都用 `_G` 哨兵守卫
  （`__BOT4CJ_*`），**第二次 `dofile` 是 no-op**。因此依赖环境变量的开关（如
  `BOT4CJ_HAL_BACKEND`）必须在**第一次**加载 `HAL.lua` 之前设置；重复 `dofile` 不会重新读环境。
- **虚拟注入是一次性闩锁**：`drv_common` 的 `virt_state` 每状态机只尝试一次。宿主为每个
  硬件变量各建一个 `lua_State`，**同一状态里 `dofile` 两个驱动会让第二个驱动的 virt 注入
  失效**（模型的全局名约定是 `<文件名>_VIRT`，发现逻辑只认唯一一个）。调试时请一状态一驱动。

## 收敛豁免清单（刻意保留的重复实现）

这些重复是**设计**而非疏漏：两套独立实现互为对照，收敛会同时抹掉双方——
改动它们的算法/结构前请先确认互证价值。

| 豁免对象 | 位置 | 理由 |
| --- | --- | --- |
| 模型侧符号扩展与位运算 | 各驱动 `*_VIRT` 声明之后 | 模型刻意不共用驱动局部量（部分刻意「纯算术无 bitcompat」），与驱动实现互证寄存器语义 |
| CRC 计算双实现 | 驱动侧 vs 模型侧（如 `SHT3X` CRC-8、`MS5611` CRC-4、`SGP30` CRC-8） | 同上：一处算错时另一处会暴露，收敛后单点错误即失效 |
| 24 位符号扩展（`0x800000`/`0x1000000`） | `LPS22HB`、`ADS1256` 等 | `bitcompat` 无 `s24` 原语，保持内联 |
| `ADS1115` destroy 的显式 ERR | `modules/ADS1115.lua` | 有回归用例固定的既有契约 |

## 孪生驱动相似度实测（26.6 留档）

四对「名字相近」的驱动于 2026-10-06 实测（`diff -w` + 芯片改名归一后的代码面相似度）：

| 对 | 行数 | diff -w | 整文件相同 | 归一后代码面 | 性质 |
|---|---|---|---|---|---|
| ADS1015/ADS1115 | 529/520 | 253 | 76% | **87%** | **机械孪生** |
| INA219/INA226 | 469/562 | 417 | 59% | 67% | 语义 |
| MAX17043/MAX17048 | 433/623 | 544 | 48% | 62% | 语义（超集） |
| BMI270/LSM6DSV | 753/650 | 767 | 45% | 46% | 语义（归一无收益） |

**结论：** 仅 ADS1015/ADS1115 是机械孪生（真差异只有数据速率表与 12 位左对齐抽取 `raw12_of`），
其余三对承担等量或更大的语义差异（INA 的 LSB 数学不同、MAX17048 是功能超集、BMI270 需 config blob
上传而 LSM6DSV 走软复位 + 双小端窗口）。孪生驱动收敛整项判为**出界**（2026-10-06 用户确认）。

**无更多孪生对：** BH1745/BH1750 20%、SHT3X/CHT8305 28%、VL53L0X/VL53L4CD 24%、INA226/INA3221 53%。
