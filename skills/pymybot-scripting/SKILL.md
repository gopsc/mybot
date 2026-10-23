---
name: pymybot-scripting
description: Reference for the pymybot three-layer robot scripting stack — SQL structure files, .mt action scripts, and Lua chip drivers with embedded *_VIRT virtual device models and Daemon sampling. Consult before writing, reviewing or diagnosing 结构脚本、动作脚本、驱动、.sql/.mt 文本、modules/*.lua、proto=virt 或传感器/舵机/继电器接入方案；文法细节、错误对照与硬纪律都在本技能的 references 里。
---

# pymybot 三层脚本开发

> 本技能供 mybot 智能体按需查阅（read_skill），命令示例供操作者参考执行。

## 项目定位

- 仓库根 ＝ Python 主线，包名 pymybot（分支 `pymybot`）。**一切开发以它为准。**
- 三层模型：`robots/*.sql` 结构（舞台：声明零件与接线）→ `modules/*.lua` 驱动
  （演员：build/call/destroy）→ `scripts/*.mt` 动作（剧本：一行一拍）。

## 按任务先读参考文件

| 任务 | 先读 |
| --- | --- |
| 写/改结构脚本、Daemon 表配置、排查加载报错 | `references/structure-sql.md` |
| 写/改动作脚本、表达式、@if/@while、Include/Merge | `references/action-mt.md` |
| 写/改 Lua 驱动、HAL 调用、drv_common 工具 | `references/driver-lua.md` |
| 写虚拟器件模型 `*_VIRT`、`proto='virt'` | `references/virt-model.md` |
| Daemon 后台采样、滤波/监视消费者 | `references/daemon.md` |
| 验证流程、常见报错对照、速查表 | `references/workflow-errors.md` |

references 内的相对路径均以仓库根 `mybot/` 为基准。

## 硬纪律（高频翻车点）

1. SQL 每条语句必须 `;` 结尾；结构文件只允许 CREATE/INSERT。
2. MT 数据格裸文本直接报错——文本必须写 `$("...")`；单元格以空白分隔、`;` 结行，
   行格数须等于表头列数。
3. 一切引用先声明后使用：`$变量`、`$(表达式)`、controller/trigger 列都只认先前声明的变量。
4. 驱动返回值必须是非空表，含 `result` 键时必须恰为 `"OK"`；失败返回 `err("原因")`。
5. 数值入参一律过 `finite_of`/`int_or`/`num_or`——NaN 是 truthy，`tonumber(v) or def` 挡不住。
6. 每张普通表名对应 `modules/<表名>.lua`；表名不带连字符，变量名（name 列的值）可带。
7. `proto='virt'` 找不到内嵌 `*_VIRT` 模型会响亮报错，**绝不静默回落真机**；
   虚拟与真机用分别命名的 SQL。
8. `destroy` 是尽力释放：资源不可用就跳过动作、仍返回 OK。
9. `@if`/`@while` 条件写在块名内且中间无空格：`@if(x>0)`。
10. 默认拒绝物理设备、非回环网络与宿主命令执行（`--allow-hardware` 才放开）；virt 总线、`loop://` 与回环 HTTP（127.0.0.1/localhost/[::1]）不需要该开关。

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

references 按 2026-10 源码整理，pymybot 在活跃开发，行为存疑时读源码裁定：
文法 `pymybot/{sql,matrix,expr,actions,include}.py`；生命周期与校验
`pymybot/{robot,hardware,daemon,runtime}.py`；驱动框架 `modules/lib/drv_common.lua`；
HAL `modules/lib/HAL.lua` 与 `modules/lib/hal/`。
