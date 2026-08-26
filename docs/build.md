# 构建与部署指南

## 环境要求

| 组件 | 版本/说明 |
| --- | --- |
| 仓颉 SDK | 1.1.3 或更高，含 cjpm |
| stdx 扩展库 | 需与目标架构匹配的 cjnative 版本 |
| Lua | 5.4 动态库及开发文件 |
| C/C++ 工具链 | gcc / g++（编译原生扩展时使用） |
| 操作系统 | Linux（glibc），aarch64 或 x86_64 |

Windows 平台暂不支持：当前版本依赖 Linux glibc。

## 准备工作

### 指定 stdx 路径

cjpm.toml 从环境变量读取 stdx 库路径：

```bash
export CANGJIE_STDX_PATH=/path/to/cangjie-stdx
```

目标平台对应的静态库位于 `${CANGJIE_STDX_PATH}/linux_aarch64_cjnative/static/stdx` 或 `linux_x86_64_cjnative/static/stdx`。

### 配置 liblua 链接名

仓颉链接选项使用 `-l lua`，而多数发行版的库文件名为 `liblua5.4.so`，需建立软链接：

```bash
# aarch64（树莓派）
sudo ln -s /usr/lib/aarch64-linux-gnu/liblua5.4.so /usr/lib/aarch64-linux-gnu/liblua.so
# x86_64
sudo ln -s /usr/lib/x86_64-linux-gnu/liblua5.4.so /usr/lib/x86_64-linux-gnu/liblua.so
```

若发行版提供 `libluajit` 或其他命名方式，请按实际路径调整。

## 构建

推荐使用仓库自带脚本：

```bash
./_set.sh
```

脚本等价于：

```bash
export cjHeapSize=16MB
cjpm update    # 解析并拉取 ctype4cj、pthread4cj、spi4cj、lua4cj、nn4cj 依赖
cjpm build
```

默认构建当前主机架构的目标。cjpm 会依据 cjpm.toml 中 `[target.*]` 段自动选择对应的 stdx 路径；在树莓派上构建即为 aarch64 目标，在 x86_64 主机上则为 x86_64 目标。

关于根目录下的 `Makefile`：该文件为早期原生库（I2C、矩阵运算等）的遗留构建脚本，其中引用的部分源文件已拆分至独立的依赖仓库，当前构建流程不依赖它。新版本请以 cjpm 为准。`compile.ps1` 为更早的 Windows 实验脚本，同样不再维护。

## 运行

程序从标准输入读取动作脚本：

```bash
cat scripts/std.mt | ./_run.sh
# 或直接调用 cjpm
cat scripts/jump.mt | cjpm run
```

`_run.sh` 会设置运行期内存参数并切换到脚本所在目录：

```bash
export cjStackSize=64MB
export cjHeapSize=64MB
exec cjpm run --run-args="$@"
```

Windows 侧的 `run.ps1` 仅转发参数给 cjpm，作用相同。

无硬件环境下可先验证解析流程：将脚本中的硬件声明注释后执行，观察解析输出。注意 `--test=matrix_o`、`--test=matrix_2` 分支仍引用旧版的 `ss/` 目录路径，当前版本下不可直接使用。

## 部署到树莓派

1. 在树莓派上安装相同版本的仓颉 SDK 与 stdx，重复上述构建步骤；或将构建产物连同依赖库一并拷贝。
2. 启用 I2C：`sudo raspi-config` → Interface Options → I2C。
3. 将运行用户加入 `i2c` 组：`sudo usermod -aG i2c $USER`，重新登录生效。
4. 用 `i2cdetect -y 1` 确认 PCA9685（默认地址 0x40）等设备已被识别。
5. 检查 `/dev/i2c-*` 设备文件存在且可读写，再执行动作脚本。

## 常见问题

**链接阶段报找不到 `-llua`**
未建立 liblua 软链接，见上文"配置 liblua 链接名"。

**运行时报打开 I2C 设备失败**
设备未启用、权限不足，或脚本中的 `/dev/i2c-N` 编号与实际不符。

**cjpm 报依赖解析失败**
检查网络可达 gitcode.com；nn4cj 以 Git 引用方式依赖，其余依赖来自仓颉包源。
