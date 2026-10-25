# 更新日志

本文件记录 bot4cj 的所有重要变更，依据 git 提交历史整理（仅覆盖 main 主线）。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号与 `cjpm.toml` 的 `version` 字段对应。

## [未发布]

virtbus 虚拟硬件测试基座、2026-09 审计修复批次、ActionSource 工厂、NN 前向推理引擎。

### 新增

- **virtbus 虚拟硬件测试基座**（`modules/lib/virtbus/`，issue #18）：真实 HAL 下注入虚拟 I2C/SPI 总线与器件模型，无需真机即可用真实驱动跑通全链路。
  - `regmap.lua` 通用寄存器模型（8/16 位指针 + burst 自增回绕）；`inject()` 替换全局 I2C/SPI 函数，支持 NACK/故障注入、txlog 留痕。
  - **26 个虚拟器件模型及测试迁移**（原手写桩整体重写）：I2C 侧 MPU6050、BME280、VL53L0X、MCP4725、VL53L4CD、SHT3X、MCP3421、MS5611、SGP30、INA219、ADS1115、AS7262、MAX30102、AMG8833、PCF8574、LTC2944、CHT8305、ADS1015、INA226、INA3221、MAX17043、ADXL345、LPS22HB；SPI 侧 ADS1256、AD9833、TPL0501。迁移即抓出旧桩假绿（BME280 H1 溢出、MPU6050 NACK 误判等）。
  - **守护 `proto=virt` 无硬件端到端**：按驱动名挂模型，build/call → 共享槽 → 滤波 → Monitor 全链路纯内存跑通。全套 84 项 / 1 真机跳过 / E2E 二十三组。
- @Daemon 共享槽采样通道 16 → 32，支撑单守护聚合多路传感器。
- **MPU6050 补全片上温度输出**：call() 返回 `TEMP/TEMP_RAW`；`sensor_daemon` 字段新增 `:f`/`:s16` 逐字段模式后缀。
- **ActionSource 工厂 `src/ActionSource.cj`**（stdin / TCP / 文件三源可替换动作输入）：`main.cj` 新增 `--tcp` / `--input` 参数；`TcpStreamReader` 字节流适配字符流；含回环 E2E 与 7 用例。
- **NN 前向推理引擎 `modules/lib/nn.lua`**（纯 Lua，无 nn4cj 依赖）：全连接 MLP，默认 `{41,80,80,40,17}` 架构；`forward`/`forwardOne`/`zeroInit`/`randInit`/`saveMt`/`loadMt`；16 用例。
- 离线桩测试：SHT3X、LTC2944、MAX17043、TPL0501、INA219、INA3221；新增 `test_spi.lua`、`test_ads1256.lua`。

### 修复

- **5 个测试结构脚本 INSERT 缺列**：按各自 `CREATE TABLE` 补全 `'-'` 占位符，用例由解析失败变为正常走到硬件层。
- **`h03_arr.sql` 引用列漏写 `$` 前缀**：补为 `'$arr_src'` 后恢复正常。
- **守护 `interval ≤ 0` CPU 忙循环**：解析失败与 `≤ 0` 一律抛 `IllegalArgumentException`，报错带上下文。
- **`sgp30.lua` LuaJIT 下 `table.unpack` 崩溃**：补兼容 shim。
- **`pthread.lua` stop 偏移注释错误**（248 应为 328）。
- **长动作脚本 controller 转发路径概率性崩溃/挂死**：仓颉 1.1.3 并发 GC 缺陷，`_run.sh` 新增 `BOT4CJ_NO_GC=1` 规避；热路径 `logD` 改条件求值降低 GC 压力。
- **ActionSource 编译失败 8 错**：按 Cangjie std.io 实际接口修正，补导入与类型适配。
- **test_pwm 概率性段错误**：`ffi.copy` 越界 1 字节写坏 GC 对象头，改 `char[?](#s+1)`。
- **BH1750 MTreg 编码错误**：改 `0x60|(mt&0x1F)`；测试断言一并修正。
- **多路径模块查找对守护 chunk 与滤波驱动不生效**（issue #19 收尾）。
- **守护消费端过滤 CRC 失败样本**。
- **2026-09 审计修复批次**：严重四项（LTC2944 控制字写偏、BMM150 三轴多乘 0.3、INA219 SADC 档表错位、MHZ19 帧头扫描死代码）；中低项含 SHT3X 状态位映射、MPU6050 WHO_AM_I 甄别、call-before-build 守卫等。
- `Lua.cj` 沙箱补中和 `io.input`/`io.output`；Lua 表转 JSON 混合键转对象；守护退出清理顺序修正。

### 重构

- **`logD` 惰性求值**：签名改为接收 `() -> String`，非 debug 模式下插值代码不再执行——从类型上根除"热路径日志插值产生 GC 压力"问题（0.3.3 曾修 7 处、仍漏 10 处的调用点差异随之消除）。
- **FFI C 字符串作用域辅助 `withCString`**（`Lua.cj`）：`mallocCString`/`free` 手工配对约 18 处收敛为 try/finally 统一释放，malloc 失败一律显式抛错。
- **`luaGlobalType` 探测辅助**：`readImpl`/`freeImpl` 重复的"getglobal + type + pop"探针合并。
- **`jsonMergeInto` 浅合并辅助**（`MatrixVars.cj`）：`callImpl` 元数据拷贝/参数合并/转发 payload 与 `MetaProvider.collect` 引用列合并共 5 处重复循环收敛。
- **`MtVars_Daemon.Factory` 拆分**：play/rise/free 三个内联大闭包提取为具名静态实现 `playImpl`/`riseImpl`/`freeImpl`（与 `MtVars_Lua` 既有同类重构对齐）；配置串与 interval 两遍列扫描合并为一遍；slot 释放两分支去重为 `releaseSlot`。
- `sandbox_lua` os/io 两段孪生中和逻辑合并为数据驱动循环；ActionSource 端口校验双报错路径合一。
- **命名改进**：`src/r.cj` → `src/RobotStruct.cj`（单字母文件名自描述化）；`RobotStruct` 单字母字段 `C`/`M` → `matrices`/`hardwareVars`（含 `MetaProvider` 同名字段）；`run_action`/`parse_action_matrixObject` → `runAction`/`parseActionCell`；局部 `MtName`/`AC`/`AliasDefs` 等统一 camelCase。各文件注释中对 r.cj 的引用同步更新。

### 文档

- `BME280.lua` / `SHT3X.lua` 头注释更新为现 HAL 语义，移除过时 cfunc 描述。

## [0.3.3] - 2026-09-11

新增硬件 PWM 驱动，修复 BME280 恒 ERR 与构建/配置一致性问题。

### 新增

- **硬件 PWM 驱动 `PWM`**（`modules/PWM.lua` + `HAL.lua` PWM 段）：走 Linux sysfs 接口，SoC 控制器产生波形。走 ffi 而非 io 库（沙箱兼容）；写序固定 duty→period→duty；`chip`/`channel` 限定非负整数；duty 未配置时 build 不使能输出。离线测试 2 层 mock + 示例。

### 修复

- **`pwm_exported` 存在性探测改 `O_RDONLY`**：非 root 用户 EACCES 误判未导出。
- **越界通道号前置校验 + `pwm_npwm`**：export 前读 `npwm` 校验合法范围。
- **sysfs 写失败带 errno 人话提示**。
- **`.gitignore` 移除 `cjpm.lock`**：与 0.3.2 锁文件入库矛盾。
- **`_run.sh` 堆大小注释与默认值不符**（128MB vs 注释 512MB）。
- **BME280 湿度校准块读取超 HAL 上限，build 恒 ERR**：改走 `i2c_read_multi_bytes`，新增 33 用例离线桩测试。

### 文档

- README 硬件变量矩阵表补 `PWM`，新增「硬件 PWM」小节（设备树绑定、权限等）。

## [0.3.2] - 2026-09-10

引用列显式化：`$` 前缀替代隐式按值判定（行为变更，存量结构脚本需同步加 `$`）。

### 变更

- **引用列须以 `$` 前缀显式标记**：裸名一律按字面值；`$` 指向未定义变量 build 期显式报错。五个 test 用例与 README 同步加 `$`，新增 `test_ref_prefix` 回归用例。

### 修复

- **INSERT 目标表名拼错改解析期显式报错**：原静默跳过致硬件实例消失。
- **ADS1115 轮询预算扩至 200ms**：覆盖最慢 8SPS 档（125ms 转换周期）。
- **ADS1115/ADS1015 PGA 冗余编码换算错 8 倍**：6/7 映射到 5。
- **HAL `i2c_read_bytes` n<1 反向钳制**：n<1 钳 1、n>16 钳 16。
- **`test/run_all.sh` 空匹配假绿与死循环**：无匹配报错退出 1；新增单测超时。
- **构建可复现性：`cjpm.lock` 入库**。
- **README 舵机表与 spider1.sql 对齐**（10 路→14 路）。
- **`.gitignore` 裸名模式锚定**；删除过时 `robots/spider.mt`。
- **`_run.sh` cjc 缺失显式报错** + LD_LIBRARY_PATH 空项安全隐患修复。
- **真机跳过改文件内标记** `-- requires: i2c`。
- **ADS1115/ADS1015 call 补 `i2c_set_addr`**。
- **Kalman.new 校验 Q≥0、R>0**。
- **sensor_daemon tick 期错误限频日志**。
- **共享槽布局核对失败改 fail-fast**（`error()` 而非 print）。
- **ADS1115 destroy 语义反转修复**：改读改写仅置 MODE=1，新增 16 用例离线桩测试。
- **重名前置判重**（资源泄漏防线）；**RobotStruct 两阶段构造**（init 纯解析 / active 资源创建）。
- **总线引用列 `$` 迁移补漏**：28 个结构脚本共 31 处补 `$`。
- **`_run.sh` 堆上限 64MB→512MB**（仓颉 GC 并发缺陷规避）。

## [0.3.1] - 2026-09-10

0.3.0 审计复审后的低危修复批，无新增功能。

### 修复

- **HAL 合并值读函数 n 越界改显式失败**（返回 -1 替代静默钳制）。
- **HAL `uart_read` 落实错误契约**：EAGAIN/EINTR 轮询，其余立即返 nil。
- Servo 驱动 print 收敛到 `BOT4CJ_DEBUG` 门控。

### 变更

- `_run.sh`：编译产物缺失友好提示、源码过期告警、.so 路径收集改 POSIX。

### 文档

- README「安全说明」：Lua 沙箱是防误用护栏而非安全边界。

## [0.3.0] - 2026-09-04 ~ 2026-09-10（未打 tag）

围绕「守护采样 → 滤波 → 引用消费」数据闭环的大版本，同时落地 HV 子包重构、硬件错误通道与一批新驱动。

### 新增

- **@Daemon 守护线程机制**：Cangjie spawn + 每守护独立 lua_State；共享内存槽 IPC；万能采样 chunk `sensor_daemon.lua`；让出式节拍。
- **滤波器硬件变量**：Kalman 与 Ema，支持三级引用链。
- **新驱动**：SHT3X、INA3221、INA219、INA226、MAX17043、TPL0501、LTC2944、GPIO、MLX90393、AS3935、VL53L4CD、MS5611、AS7262、VL53L0X、BMI270、LSM6DSV16X、BME688、BMM150、MT6826S、LPS22HB、ADS1015、MCP3421、APDS9900、BH1745、ADXL345、MAX30102、AMG8833、EMC2101、MAX17048、CHT8305、MCP4725、AD9833、PCF8574、SDS011。
- **UART 总线能力**（HAL termios + MH-Z19B CO2 参考驱动）。
- **HAL 新增**：`i2c_write_reg16`/`i2c_read_reg16`、`i2c_read_bytes`、`i2c_read_multi_bytes`、`spi_write_multi`。
- SGP30 驱动升级（build 自检 + 基线持久化 + 湿度补偿）。
- **硬件错误通道**（halt-on-error）；**Lua 驱动沙箱**；`BOT4CJ_DEBUG` 开关。
- Lua 离线测试统一入口 `test/run_all.sh`，test/ 套件全量入库。

### 变更

- @Daemon chunk 按 `BOT4CJ_MODULE_PATH` 寻址；硬件变量类迁出 `src/HV/` 子包。
- HAL i2c 改用 `I2C_RDWR` 原子事务；DSL 语义收紧。
- 元数据收集改静态列缓存；驱动样板收敛 `drv_common.lua`（统一 52 个驱动）。
- Cangjie 内核瘦身：`Lua.cj` 闭包拆分、`r.cj` 重构分发器。
- 依赖升级 luajit4cj 1.0.1、pthread4cj 1.0.2。

### 修复

- `sensor_daemon` 浮点静默向下取整修复；守护线程 stop/join/泄漏三连修复。
- `sandbox_lua` 栈索引错误；PCA9685 channel 越界校验。
- MPU6050 六轴符号扩展；INA219/INA3221 位左移兼容性修复。
- **ADS1x15 OS 位读语义反转**（datasheet 级）；**ADS1256 满量程换算少乘 2**。
- pthread `publish` 入锁前数值校验；SPI setup 失败关闭泄漏 fd。
- 审计加固两轮（驱动返回值判读、print 噪音收敛、halt-on-error 补强等）。

## [0.2.0] - 2026-09-04

HAL 彻底甩掉宿主注册的 cfunc，进入 LuaJIT ffi 时代（此后仅支持 LuaJIT）。

### 新增

- LuaJIT 绑定抽取为独立包 luajit4cj；fft、kalman 由 C 移植为 Lua 库。

### 变更

- HAL 以 ffi 直调 glibc（open/ioctl/read/write/usleep）；SPI 延时改为逐次显式传入；`i2c_set_addr` 支持 EBUSY 回退 FORCE。

### 修复

- LuaJIT ffi 变参 ABI 陷阱：ioctl 地址参数显式 cast。

## [0.1.1] - 2026-09-03 ~ 2026-09-04

### 新增

- 通用 **controller 引用机制**；动作脚本支持内联 @Alias 定义；BME280 驱动。

### 变更

- 基层 I2C/SPI 驱动完全解耦为纯 Lua HAL（issue #14）；Servo 迁移为 Lua 驱动；`-` 占位符归一为 `0`。

## [0.0.6] - 2026-09-01 ~ 2026-09-02

### 新增

- **机器人结构脚本迁移到 SQL**：新版 `.sql` 结构文件由 SQL4cj 解析，旧版 `.mt` 结构矩阵废弃。
- 新驱动：Timer、SGP30、Dummy。

### 变更

- 动作与结构解耦；@Action 按标题行列序执行；解析器独立为模块。

## [0.0.5] - 2026-08-31

### 新增

- Lua 桥新增 burst 读写函数；重写 ADS1115 / ADS1256 驱动。

### 变更

- 全面改进错误处理与可配置性。

### 修复

- 解析器逻辑错误与调试代码残留；硬件变量重复键检查（Issue #8）。

## [0.0.4] - 2026-08-31

### 变更

- 更新外部依赖。

## [0.0.3] - 2026-05-31（tag v0.0.3beta；6~8 月在其上持续演进）

项目最大转折点：嵌入 Lua 状态机，硬件变量改由 Lua 脚本实现。

### 新增

- Lua 状态机嵌入与 MtVars_Lua；ADS1256/ADS1115 ADC、SPI 驱动；pthread4cj；spi4cj 独立仓库。
- I2C 驱动重建；MPU6050 迁移跑通；删除遗留构建脚本与杂项 test 目录。

## [v0.0.2beta] - 2026-05-03（tag；5 月上中旬持续）

硬件变量体系成型期。

### 新增

- 占位符支持与流式读取；Servo/PCA9685 硬件变量；RobotStruct 类封装。
- @Alias/@Action 解析；原生 I2C；pthread 线程与 I2C 锁；MPU6050。
- kalman 滤波器；Cangjie 版神经网络（矩阵/卷积/Adam）。
- 动作集扩充：行走/转向/倾斜/举手/躺下等。

### 移除

- 旧的神经网络与矩阵、声音（Speaker）部分及旧 I2C 接口。

## [v0.0.1beta] - 2026-04-21（tag；2026-01-28 项目起步）

探索期：从 C 直读传感器到强化学习驱动的机器人动作。

### 新增

- 项目创建：仓颉 + C 混合 I2C/MPU6050 读取；Actor 动作脚本解析器与 `Actor.play()`。
- PCA9685 舵机驱动；蜘蛛机器人步态脚本；FFT 库；神经网络重构；CUDA 矩阵加速。
- DRL 强化学习；CNN 卷积神经网络库；Windows 平台支持；Parser.cj 独立。
