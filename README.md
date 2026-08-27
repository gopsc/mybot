# bot4cj

bot4cj 是基于仓颉编程语言和 Linux I2C 接口的机器人硬件脚本解析器。

机器人种类繁多，软件往往彼此独立、难以复用。本项目尝试使用一种通用的表格式脚本来描述机器人的硬件构成与动作序列：硬件以矩阵对象声明，动作以行列式表格描述，解析器负责解析脚本并将其逐行下发到硬件。宿主机通常为树莓派。

## 特性

- 以 `.mt` 矩阵脚本声明硬件与动作，无需修改代码即可调整机器人配置
- 内置 I2C、PCA9685（PWM 舵机驱动）、MPU6050（姿态传感器）、Servo、Speaker 等硬件变量类型
- 通过 Lua 脚本扩展自定义硬件驱动，内置 SPI、I2C、延时等注册函数
- 依赖 `nn4cj` 提供神经网络接口，为动作生成与微调预留能力

## 硬件支持

| 硬件 | 类型 | 说明 |
| --- | --- | --- |
| PCA9685 | PWM 控制板 | 经 Lua 驱动加载，16 路 PWM 输出，常用于舵机控制 |
| MPU6050 | 姿态传感器 | 内置驱动，后台线程持续采样 |
| Servo | 舵机 | 支持最大/最小角度限制、漂移修正、方向翻转 |
| Speaker | 扬声器 | 当前版本仅负责时序延时，发声功能停用中 |
| ADS1115 / ADS1256 | ADC 模块 | 经 SPI 接口由 Lua 模块驱动 |

详见 [docs/hardware.md](docs/hardware.md)。

## 项目结构

```text
bot4cj/
├── src/
│   ├── main.cj          # 入口，命令行参数处理
│   ├── r.cj             # 机器人结构与硬件变量实现
│   ├── P.cj             # 矩阵脚本词法解析器
│   ├── hd/              # 硬件驱动层（I2C、PCA9685、MPU6050 等）
│   ├── math/            # 数值算法（卡尔曼滤波）
│   └── cpp/             # 原生扩展源码（FFT、滤波、音频）
├── modules/             # Lua 硬件驱动脚本
├── scripts/             # 动作脚本示例（.mt 为现行格式，.bot 为旧版）
├── cjpm.toml            # 构建配置
├── _set.sh              # 更新依赖并构建
└── _run.sh              # 运行脚本
```

## 环境依赖

- 仓颉 SDK 1.1.3 或更高版本，含包管理工具 cjpm
- Linux（glibc），目标架构 aarch64 或 x86_64；Windows 因缺少 glibc 暂不支持
- liblua 5.4 动态库，构建时以 `-l lua` 链接

仓颉标准库扩展 stdx 需通过环境变量 `CANGJIE_STDX_PATH` 指定。完整的构建步骤见 [docs/build.md](docs/build.md)。

## 快速开始

在仓库根目录执行：

```bash
./_set.sh                                # 更新依赖并构建
cat scripts/std.mt | ./_run.sh           # 解析并执行标准动作脚本
```

或直接使用 cjpm：

```bash
cjpm update && cjpm build
cat scripts/jump.mt | cjpm run
```

程序从标准输入读取动作脚本，逐行执行 `@Action` 矩阵中的内容。脚本语法详见 [docs/script-syntax.md](docs/script-syntax.md)。

### 命令行参数

| 参数 | 说明 |
| --- | --- |
| `--help` | 打印帮助信息 |
| `--test=<key>` | 运行内置测试分支，取值 `nn1`、`matrix_o`、`matrix_2` |
| `-i <path>` | 指定输入的神经网络模型路径（配合 nn4cj，重构中） |
| `-o <path>` | 指定神经网络模型的输出路径（重构中） |

## 相关仓库

以下依赖均以独立仓库维护，可在 cjpm.toml 中切换 Git 引用以跟踪开发进度：

| 仓库 | 说明 |
| --- | --- |
| [ctype4cj](https://gitcode.com/qingss0/ctype4cj) | ARM64 架构下 C 变量类型的仓颉抽象层 |
| [pthread4cj](https://gitcode.com/qingss0/pthread4cj) | pthread 线程与互斥锁封装 |
| [spi4cj](https://gitcode.com/qingss0/spi4cj) | SPI 应用层驱动 |
| [lua4cj](https://gitcode.com/qingss0/lua4cj) | Lua 5.4 C API 的仓颉绑定 |
| [nn4cj](https://gitcode.com/qingss0/nn4cj) | 神经网络模块 |

动作脚本适用的机器人建模文件见 [Dashun](https://github.com/gopsc/Dashun) 仓库。

## 文档

- [脚本语法规范](docs/script-syntax.md)
- [硬件支持与驱动](docs/hardware.md)
- [构建与部署指南](docs/build.md)
- [变更日志](CHANGELOG.md)
- [参与贡献](CONTRIBUTING.md)

## 许可证

本项目基于 [MIT License](LICENSE) 发布。
