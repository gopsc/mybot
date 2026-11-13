# Nns：C++ 原生神经网络示例

这个示例不接硬件，只演示结构 SQL 的 `Nns` 表如何创建/加载一个 MLP，以及
`@Action` 如何做推理和训练。底层是 `nn4cpp`（Eigen），不经过 Lua。

## 前置

构建时启用 `nn4cpp`：

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DMYBOT_WITH_NN4CPP=ON
cmake --build build -j4
```

默认会在同级 `../nn4cpp` 或 `../botprj/nn4cpp` 查找；也可用
`-DMYBOT_NN4CPP_DIR=/path/to/nn4cpp`。

## 跑

```bash
# 训练（30 轮 x 4 个样本 = 120 次逐样本更新；自动保存）
./build/mybot --robot=examples/nns/robot.sql --input=examples/nns/train.mt

# 推理（加载 examples/nns/model.nn；XOR 输出应接近 [0, 1, 1, 0]）
./build/mybot --robot=examples/nns/robot.sql --input=examples/nns/predict.mt
```

第一次运行 `train.mt` 时，`path` 不存在，会按 `layers` 创建模型并立即保存；
之后运行会加载已有模型。`autosave=1` 让每次训练后也写回。

## 协议速查

- 输入：`nn.input0`、`nn.input1`（每个格一个数值），或 `nn.input`（文本/JSON 数组）。
- 输出：`nn.target0` 存在即训练，否则推理；也可以显式写 `nn.command`。
- 可选：`nn.discount`（训练折扣）、`nn.save`（本次后保存）。
- 返回值：推理带 `output` 数组和 `output0` 等标量；训练额外带 `loss`、`saved`。
- 模型文件是 nn4cj 的 `nn4cj 1` 文本格式，可由仓颉版 nn4cj 直接读取。

更多字段见 [docs/drivers.md](../../docs/drivers.md#nns原生神经网络)。
