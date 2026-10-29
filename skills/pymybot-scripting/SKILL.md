---
name: pymybot-scripting
description: Reference for the pymybot three-layer robot scripting stack — SQL structure files, .mt action scripts, and Python/Lua chip drivers with embedded *_VIRT virtual device models and Daemon sampling. Consult before writing, reviewing or diagnosing 结构脚本、动作脚本、驱动、.sql/.mt 文本、modules/*.py、modules/*.lua、proto=virt 或传感器/舵机/继电器接入方案；文法细节、错误对照与硬纪律都在本技能的 references 里。
---

# pymybot 三层脚本开发

> 本技能供 mybot 智能体按需查阅（read_skill），命令示例供操作者参考执行。

## 项目定位

- 仓库根 ＝ Python 主线，包名 pymybot。**一切开发以它为准。**
- 三层模型：`robots/*.sql` 结构（舞台：声明零件与接线）→ `modules/*.py` 或 `*.lua` 驱动
  （演员：build/call/destroy）→ `scripts/*.mt` 动作（剧本：一行一拍）。
- 操作者文档 `docs/` 是架构、CLI、安全、测试的权威来源，本技能只写脚本层的硬规则；
  agent 读不到 docs，因此每个 reference 开头的 `Source:` 行标明了它对应的权威位置。

## 按任务先读参考文件

| 任务 | 先读 |
| --- | --- |
| 写/改结构脚本、Daemon 表配置、排查加载报错 | `references/structure-sql.md` |
| 写/改动作脚本、表达式、嵌套 Action/if/while、命名 Reflex、Include/Merge | `references/action-mt.md` |
| 写/改 Python/Lua 驱动、HAL 调用、drv_common 工具 | `references/driver-lua.md` |
| 写虚拟器件模型 `*_VIRT`、`proto='virt'` | `references/virt-model.md` |
| Daemon 后台采样、滤波/监视消费者 | `references/daemon.md` |
| 验证流程、常见报错对照、速查表 | `references/workflow-errors.md` |

references 内的相对路径均以仓库根 `mybot/` 为基准。

## 硬纪律（高频翻车点）

1. SQL 每条语句必须 `;` 结尾；结构文件只允许 CREATE/INSERT。
2. MT 数据格裸文本直接报错——文本必须写 `$("...")`；单元格以空白分隔、`;` 结行，
   行格数须等于表头列数。
3. SQL 的 `$变量`、controller/trigger 引用须先声明。MT 顶层声明在动作前统一注册，
   Reflex 可先调用后定义；表达式求值时名字必须可见，捕获可创建数值/文本标量，不能隐式创建 Struct。
4. 驱动返回值必须是非空表，含 `result` 键时必须恰为 `"OK"`；失败返回 `err("原因")`。
5. 数值入参一律过 `finite_of`/`int_or`/`num_or`——NaN 是 truthy，`tonumber(v) or def` 挡不住。
6. 普通表对应 `modules/<表名>.py` 或 `.lua`：逐根查找，同根 Python 优先；原生入口是 `Driver(context)`，详见驱动参考。表名不带连字符。
7. `proto='virt'` 找不到内嵌 `*_VIRT` 模型会响亮报错，**绝不静默回落真机**；
   虚拟与真机用分别命名的 SQL。
8. `destroy` 是尽力释放：资源不可用就跳过动作、仍返回 OK。
9. `@if`/`@while` 条件写在块名内且中间无空格：`@if(x>0)`；Action、控制块和 Reflex body
   均可混排矩阵与嵌套 Action/if/while。Include 只在最外层，body 内 Merge 只合并其后的纯矩阵，不能横向合并嵌套块。
10. 默认拒绝物理设备、非回环网络与宿主命令执行（`--allow-hardware` 才放开）；virt 总线、`loop://` 与回环 HTTP（127.0.0.1/localhost/[::1]）不需要该开关。
11. 使用顶层 `@Reflex(name)` 命名块，无 `name` 列，可声明多个但不得重名或嵌套声明；仅由 `reflexName.varName`
    表头调用。MT `@Trigger` 和旧无名 `@Reflex` 在解析时拒绝；SQL trigger 完全保留。
12. Reflex 根 body 可声明 Alias/Vars 局部默认值，实参按数值/文本类型覆盖；Action/控制块内不可声明，Struct 仍仅顶层。
    默认值、参数及所有内部捕获（含全局 Struct 写入）逐次调用隔离，退出即恢复；用外层 `f.capture` 显式取得最后一次内部器件结果。
    参数保护、precision、递归预算等完整规则见 `references/action-mt.md` 第 7 节，勿沿用旧捕获传播语义。

## 验证闭环（在 `mybot/` 下执行）

```sh
# 静态检查（语法/模块存在/引用关系，不激活驱动）
.venv/bin/python -m pymybot check --robot robots/<任务>.sql [--input scripts/<任务>.mt]

# proto='virt' 无硬件端到端（不需要 --allow-hardware）
.venv/bin/python -m pymybot run --robot robots/<任务>.sql --input scripts/<任务>.mt --timeout 30

.venv/bin/python -m pytest    # 全量回归
```

新驱动应配 `tests/fixtures/virt/<驱动小写>_virt.{sql,mt}` 夹具
（机制见 `tests/test_migrated_drivers.py`，已有 40 对范本）。

## 兜底：以源码为准

references 按 2026-10 源码整理，pymybot 在活跃开发；行为存疑时读各 reference 开头 `Source:`
指向的实现裁定，HAL 细节见 `modules/lib/HAL.lua` 与 `modules/lib/hal/`。
