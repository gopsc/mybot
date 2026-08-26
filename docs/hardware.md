# 硬件支持与驱动

本文说明 bot4cj 的硬件抽象方式、内置驱动的现状，以及通过 Lua 脚本扩展新硬件的方法。

## 硬件变量模型

所有硬件在运行期表现为一个**硬件变量**（`MatrixVars_Hardware` 及其子类）。每个变量持有三个回调：

| 回调 | 触发时机 | 职责 |
| --- | --- | --- |
| `rise` | 解析器激活阶段（`build`） | 打开设备、初始化 |
| `things` | 每次动作调用（`play`） | 接收参数并驱动硬件 |
| `free` | 退出阶段，按构造的逆序销毁 | 释放资源 |

参数与返回值统一使用 JSON 值对象传递，使不同硬件共享同一调用接口。

## I2C 子系统

I2C 层直接封装 glibc 接口：

- `open(path, O_RDWR)` 打开 `/dev/i2c-N` 设备文件；
- `ioctl(fd, I2C_SLAVE, addr)` 选择从机地址；
- 寄存器读写使用 `write`/`read` 组合，读寄存器前先写入寄存器地址，每次读取一个字节。

每个 I2C 文件句柄绑定一把互斥锁（由 pthread4cj 提供），所有通信前后必须加解锁，保证多线程访问时的原子性。

树莓派默认未开启 I2C，需先在 `raspi-config` 中启用，并将用户加入 `i2c` 组以获得设备文件读写权限。

## 内置驱动现状

### PCA9685（PWM 控制板）

现行实现位于 `modules/PCA9685.lua`，经通用 Lua 硬件机制加载。驱动将 PWM 频率配置为 50 Hz（舵机标准周期 20 ms），预分频值按 25 MHz 内部时钟计算；角度到脉宽的映射为 0°–180° 对应 0.5 ms–2.5 ms。

源码中另有一份仓颉实现的 `PCA9685` 类（`src/hd/PCA9685.cj`），已被 Lua 驱动取代，暂时保留备用。

### MPU6050（姿态传感器）

内置完整驱动（`src/hd/MPU6050.cj`）：初始化、单次采样、以及后台线程持续采样（`startDaemon`/`stopDaemon`）。脚本中的 `@MPU6050_BIND` 矩阵对应的绑定类尚未接入工厂分发流程，接入前该矩阵不会创建原生驱动实例。示例脚本中的相关行均处于注释状态。

### Speaker（扬声器）

原生音频代码位于 `src/cpp/snd.cpp`，但发声调用目前处于停用状态，`Spk.play()` 仅执行毫秒级延时。动作脚本中的扬声器列因此用于控制节拍时序。

### ADS1115 / ADS1256（ADC 模块）

两模块均经 SPI 总线通信，由 `modules/ADS1115.lua` 与 `modules/ADS1256.lua` 驱动，依赖 spi4cj 提供的应用层接口。

### 帧缓冲（实验性）

`src/hd/fb.cj` 包含 Linux framebuffer 的打开与内存映射封装，属实验性代码，尚未接入脚本体系。

## Lua 扩展机制

自定义硬件的驱动脚本放在 `modules/` 目录下，文件名为 `<矩阵名>.lua`。解析器为每个数据行创建独立的 Lua 状态机，并在三个阶段调用同名全局函数：

```lua
function build(data)   -- 构造阶段：data.mode == "build"
end

function call(data)    -- 调用阶段：data.mode == "call"，携带 @Action 传入的实时参数
end

function destroy(data) -- 销毁阶段：data.mode == "destroy"
end
```

`data` 表的内容依次为：元数据列（字符串）、已解析引用变量的求值结果、以及调用阶段的实时参数。函数可返回一张键值表，返回值会作为本次调用的结果交回宿主；当其他变量的元数据引用了本变量时，这些键值将被合并进对方的参数表。

宿主环境注册了以下 C 函数：

| 函数签名 | 说明 |
| --- | --- |
| `milli_sleep(ms)` | 毫秒级延时 |
| `i2c_open(path)` | 打开 I2C 设备，返回句柄 |
| `i2c_close(fd)` | 关闭 I2C 设备 |
| `i2c_set_addr(fd, addr)` | 设置从机地址 |
| `i2c_write_reg(fd, reg, val)` | 写寄存器 |
| `i2c_read_reg(fd, reg)` | 读寄存器，返回一个字节 |
| `spi_open(path)` | 打开 SPI 设备，返回句柄 |
| `spi_close(fd)` | 关闭 SPI 设备 |
| `spi_setup(fd, mode, bits, speed, delay)` | 配置 SPI 模式、位宽、速率与时延 |
| `spi_write(fd, val)` | 写一个字节 |
| `spi_read(fd)` | 读一个字节 |

参考实现见 `modules/PCA9685.lua`。
