# 动作脚本（.mt）

Source: 本文件是 MT 文法的书面来源，以实现为准——`pymybot/matrix.py`（字符文法）、`pymybot/expr.py`
（表达式）、`pymybot/actions.py`（派发/捕获/控制块/命名 Reflex）、`pymybot/include.py`（Include/Merge）；
运行动作的命令见 [docs/cli.md](../../../docs/cli.md)。

## 1. 字符文法

```mt
# 井号到此行末是注释
@Action
relay0.test   timer-0.delay;      # 表头：变量.参数；空白分隔，';' 结行
          1              200;      # 数据行：空白分隔单元格
          2                 -;      # '-' 继承上一行同列
@
```

- 块写成 `@块名`，块名遇空白结束；推荐独占一行，单独一行 `@` 闭块。
  命名块写 `@Reflex(name)` / `@Struct(name)`，名称必须紧贴括号，不能加空白。
- Action、Reflex 和控制块的 body 可混排纯矩阵与嵌套 Action/if/while，按书写顺序执行；
  每个纯矩阵段有自己的表头。Reflex/Struct 定义仅限顶层，Alias/Vars 另允许在 Reflex 根 body 声明。
- **单元格以空白（空格/Tab/换行）分隔**，`;` 提交一行；一行可以跨多行书写，
  但惯例是一行一拍。空行（连续 `;` 无内容）被忽略。
- 每行单元格数必须等于表头列数。
- CRLF 与 LF 等价；脚本上限 8 MiB；块嵌套深度上限 32。
- 注释 `#` 可以出现在任何位置到行尾（也能结束块名）。
- 普通矩阵的分格发生在表达式解析之前，**引号不保护空白、`;` 或 `#`**：`$(n + 1)`、
  `$("hello world")` 不能作为一个单元格。表达式应写 `$(n+1)`；字符串需要 Tab 时可写
  `$("hello\tworld")`，由表达式解析器将 `\t` 转成 Tab，但它不是字面空格。
- `@Struct(name)` 是例外：块体整体按标准 JSON 解析，不分格、不按分号分行，JSON 字符串
  中的空白、`#`、`;`、`@` 均保留，详见第 9 节。

## 2. @Action 动作块与矩阵

`@Action` 不再是只能容纳矩阵的叶子块：可直接写矩阵，也可混排嵌套 Action/if/while。
下列规则适用于所有动作 body 的纯矩阵段，嵌套不会改变其求值、派发或捕获顺序。

**表头**：每个单元格形如 `设备.参数`（表达式外恰好一个分隔点，两侧非空；设备名允许连字符，
与 SQL 里 name 列的值一致）。点号两侧可以分别用 `$(...)` 动态生成，如
`$(prefix+n).$(key)` 或 `$(cfg.device).$(cfg.parameter)`；设备名可再经 `@Alias` 一层间接，
参数名渲染为文本。表达式中的字段点号、小数点不作为分隔符，因此 `dev.$(1.5)` 也可解析，
其参数名为文本 `"1.5"`，是否接受由驱动决定。同一 `(设备, 参数)` 解析结果不得重复。
每次派发矩阵时只解析一次表头；同一矩阵后续行的捕获不会改变目标设备或参数名，
循环下一次派发该矩阵时才会重新解析。
目标也可以是 `@Reflex(name)` 定义的反射名，写成 `反射名.形参名`；参数类型、局部作用域和返回捕获见第 7 节。

**数据行**每格取值（依序判定）：

| 形态 | 语义 |
| --- | --- |
| `-` | 继承上一行同列的原始单元格内容；未设值时的行为见下文 |
| `$(表达式)` | 求值（数字或文本；**不得是布尔**） |
| `$变量=字段.路径` | 捕获：不发送参数，从该设备本次结果中取字段（见第 5 节） |
| 数字字面量 | 十进制或 `0x` 十六进制，严格 Float64 解析 |
| 其他裸文本 | **报错**——文本必须写成 `$("...")` 字符串表达式，或通过 `$(别名)` 读取文本 |

`-` 继承表达式时会重新求值，继承捕获格时会再次调用并捕获，并非复用上次结果。
若设备在整张矩阵中有非 `-` 数据，尚无继承来源的参数会跳过；若该设备的所有数据格
都是 `-`，则每行仍以对应参数值 `0` 调用。继承只在本次矩阵派发内有效，不跨矩阵或循环轮次。

**执行语义**（`actions.py` 的 `dispatch`）：

1. **整行先求值、后派发**：一行所有单元格先算完，捕获值对本行后续单元格不可见，
   从下一行/下一块开始可见。
2. 设备按**表头首次出现顺序串行** `play`；同设备多列合并为本行的一次调用，
   本行没有任何参数也没有捕获的设备跳过。一行不自带固定时长，节拍需由 Timer 等驱动提供。
3. 器件动作参数不得覆盖保留键：本设备元数据列名、`mode` / `result` / `message`、
   SQL trigger 变量名。
4. 每次调用的返回必须是**非空表**；若含 `result` 键，必须是去掉首尾空白后为 `"OK"`
   的字符串，否则执行失败。设备调用或捕获失败不会撤销此前已发生的调用，一行不是事务。
5. 脚本至少要有顶层 `@Action` 或 `@if` / `@while`；只有标量、Struct 或 Reflex
   定义不能单独运行。条件为假的控制块可以合法地不产生任何调用。

## 3. 表达式语言 `$(...)`

有界解析器（不 eval Python），类型系统：**数字（Float64）/ 文本 / 布尔**，
无隐式真值转换。

| 优先级 | 运算符 | 说明 |
| --- | --- | --- |
| 5 | `*` `/` `%` | 数字；除零/模零报错；`%` 为 C 语义 fmod |
| 4 | `+` `-` | 数字；`+` 任一侧为文本 → 拼接（布尔禁止） |
| 3 | `<` `>` `<=` `>=` | 仅数字大小比较，不支持文本或布尔 |
| 3 | `==` `!=` | 同类型相等比较，支持数字、文本、布尔；跨类型报错 |
| 2 | `&&` | 布尔，惰性 |
| 1 | `\|\|` | 布尔，惰性 |
| 一元 | `-` `!` `+` | 前缀可叠加按奇偶折叠 |

- 表达式字面量：十进制（支持小数、`e` 指数）、`"字符串"`（转义仅 `\n \t \r \\ \"`）。
  **表达式不支持十六进制**：`$(0x10)` 报错；裸数值单元格或 `@Vars` 的裸数值才支持
  `0x10`、`0x1.8p+2`。非有限数值拒绝。
- 标识符解析：`@Vars` → 数字，`@Alias` → 文本，`@Struct` → JSON 值；Struct 支持
  `.字段`、`[下标表达式]` 逐层访问，最终表达式结果仍须为数值、文本或布尔。
  不能直接访问驱动或 `设备.字段`，需先捕获结果。标识符只能含字母、数字、下划线且不能
  以数字开头，连字符会被当作减号；不支持对象的 `["键"]` 访问。
- `true` / `false` 不是 MT 表达式的内建布尔字面量；布尔值可由比较表达式或 Struct 中的
  JSON 布尔字段产生。JSON 块体本身支持标准 `true` / `false` / `null`。
- 单个 `=` 不是运算符（等号必须写 `==`）；不支持 `1<2<3` 式连锁比较。
- 限额：单表达式的二元运算符与字段/下标访问合计 ≤512，括号/下标嵌套及访问链深度 ≤128；
  数值结果必须有限。Struct JSON 自身另有 32 层深度限制。
- 条件必须得到布尔值，`@if(1)` 不合法；动作表头或数据单元格的 `$(...)` 产生布尔即报错。

## 4. 控制块 @if / @while

条件写在**块名里**，紧跟括号、**中间不得有空格**——空格是单元格分隔符，
`@while(count < 3)` 会解析成块名 `while(count` 加两个数据格而报错：

```mt
@Vars
name value;
count 0;
@
@while(count<3)
r.value;
$(count);
$count=reading;
@
```

- `@if(条件)` 为真时执行子块；`@while(条件)` 循环执行子块（含空体死循环防护——
  预算耗尽会打断）。
- 控制块**体内直接写矩阵**即隐式子 Action（如上：`r.value` 是隐式表头，
  其后每行是数据行），也可混排显式 `@Action`、`@if` 或 `@while`；四种 if/while 相互嵌套组合均支持，
  与 Action、Reflex body 一样按书写顺序执行。嵌套块后的矩阵段必须重新写表头，`-` 不跨段继承。
- 外层条件为假时，整个 body 都跳过，内层条件也不求值；后续兄弟块继续执行。
  `if` 只在进入时判断一次，`while` 每轮开始前重新判断；内层循环重新进入时也使用当前捕获值。
- Action/控制块内不能声明 Alias/Vars、Struct 或 Reflex；Alias/Vars 另可在 Reflex 根 body
  声明局部默认值（第 7 节），Struct/Reflex 声明始终只在顶层。
  循环变量的更新靠**捕获**：上例 `$count=reading` 把 `r` 本次结果的 `reading`
  字段写回 `count`，下一轮条件立即用新值（捕获从下一行/下一块起可见，见第 5 节）。
- 嵌套不会重置超时、取消或输出预算，空体死循环也会被预算打断；块嵌套仍最多 32 层。

以下可配合 `robots/relay-test.sql` 运行，仅调用软件 Timer，不访问物理硬件。
它展示 `if → while → if/Action → Reflex 调用`，回执中的 `slept` 依次为 `1、2、3`：

```mt
@Vars
name value;
count 0;
@
@Reflex(step)
timer-0.delay;
$(value);
@
@if(count==0)
@while(count<3)
@if(count<2)
step.value step.capture;
$(count+1) $count=slept;
@
@Action
step.value step.capture;
$(count+1) $count=slept;
@
@
@
```

第二轮内层 `if(count<2)` 为假，但同层 Action 仍执行，将 `count` 更新为 3 后退出循环。
Reflex 内部变量不会泄漏；这里通过调用处的 `step.capture` 显式更新外层循环变量。

## 5. 捕获 `$变量=字段.路径`

捕获格写在**数据行**里、对齐到要捕获的那个设备的列（表头格必须是 `设备.参数`，
不能放捕获格）：

```mt
@Action
th0.T;
$t=T;
@
```

- 数据格 `$t=T`：`th0` 本行不收动作参数（仍会被调用一次），其结果表的 `T`
  字段捕获为变量 `t`。路径支持点分多级（`a.b.c`），每段必须存在且父级是表。
- 同一行既要发参数又要捕获：加一列**同设备的另一参数**，如
  `th0.T th0.settle` 配数据行 `$(25) $t=T`——`th0` 收到 `T=25` 调用一次，
  捕获读的是**结果表**里的 `T`（回读值），不是发出的参数。
- 数值捕获自动成为 `@Vars` 型标量，文本捕获成为 `@Alias` 型；
  已存在的 `@Vars` 目标必须捕获到数值字段；不能捕获进驱动/daemon 变量。
- 布尔字段可捕获到已声明的 `@Alias`（可来自 SQL 结构或 MT），保存为文本
  `"true"` / `"false"`；也可捕获到已声明的 Struct 整值或成员，保留 JSON 布尔类型。
  未声明目标无法推断布尔类型，`@Vars` 目标也不接受布尔。
- Struct 捕获目标可写 `$state=payload`、`$state.count=count`、`$state.points[i].x=x`；
  右侧仍是驱动结果的点分字段路径。赋值规则见第 9 节。
- 设备带 controller 链时，捕获的是链路最终返回的结果。例如 Relay 转发到 Timer 后，
  可捕获 `slept`；不是直接读取 Relay 的中间结果。捕获字段不存在时，设备调用已经发生。
- Reflex 内部的所有捕获（含外层 Struct 写入）仅在本次调用内可见；向调用者写回须使用
  外层反射捕获列，读取最后一次内部器件结果，详见第 7 节。

## 6. 会话与调用局部标量 @Alias / @Vars

```mt
@Vars
name value precision;
level 2;
ratio 2.3456 2;
@
@Alias
name alias;
output relay0;
@
```

- `@Vars` 必须有 `name` / `value` 列；`@Alias` 必须有 `name` / `alias` 列。
- 所有顶层标量声明在执行动作前统一注册，写在动作块后面也会提前生效；它们不是顺序赋值语句。
  Reflex 根 body 内也可声明调用局部默认值，不会注册到顶层；Action/控制块内不得声明。
- 顶层 `@Alias` 可临时覆盖同名标量；顶层 `@Vars` 不得与结构变量同名。
  同一声明作用域内重复声明同名 Alias/Vars 报错；Reflex 的局部默认值和参数可临时覆盖已有 Alias/Vars，
  但不得覆盖 driver、Daemon、Struct 或 SQL controller/trigger 受保护引用，详见第 7 节。
- `@Vars` 的 `value` 若为 `$(...)`，每次读取都重新求值，可引用数值型 `@Vars` 或 Struct
  的数值成员，最终必须得到数值，不能引用 Alias。不能用重复声明或 `$(i+1)` 数据格来赋值，
  循环更新可通过捕获完成。
- `@Vars` 可选 `precision` 列（0..15）：只影响该变量渲染为器件动作参数/捕获文本时的小数位，
  不改变表达式内部的浮点计算，也不把传给 Reflex 的数字参数转成文本；缺省仍使用 `.15g`。
  `precision` 必须是非负整数，非法值在注册阶段报错。`@Alias` 不支持该列。
- 这里的会话指**一次 `Robot.run`**：成功或失败退出时都会恢复进入前的标量覆盖层，
  不会重置 Lua 驱动状态或撤销设备动作，也不会把捕获值保留到下一次 `run`。
  Reflex 的默认值、参数及内部捕获有更短的生命周期，在每次调用退出时即恢复。
- SQL 结构也支持 Alias/Vars（见 `references/structure-sql.md` 第 6 节），但它们属于
  Robot 结构；MT 声明和捕获属于本次运行或调用的临时覆盖层，生命周期不同。

## 7. @Reflex(name) 命名动作块与调用

`@Reflex(name)` 是**独立的顶层命名块**，名称须符合 `[A-Za-z_][A-Za-z_0-9-]*`，没有 `name` 列。
同一脚本可声明多个不同名字，重复名字报错；定义可在调用之后，但不能嵌在 Action、控制块或另一个 Reflex 内。
声明本身不执行，只有 `reflexName.varName` 动作表头会调用它。块体直接采用与 Action 相同的矩阵，
也可按顺序混排嵌套 `@Action` / `@if` / `@while`；Action 本身同样支持这些嵌套。

**BREAKING**：MT `@Trigger` 的解析与执行已移除，旧的无名 `@Reflex` 定义表也不兼容，均在 parse 阶段拒绝。
SQL 结构中的 `trigger` 列、引用保护及触发机制完全保留，与此变更无关。

以下可配合 `robots/relay-test.sql` 使用，由 Relay 转发给 Timer：

```mt
@Reflex(alarm)
@Vars
name value;
delay 1;
@
@Alias
name alias;
output relay0;
@
output.test;
$(delay);
@Action
@if(delay>0)
output.test output.capture;
$(delay+1) $delay=slept;
@
@
@
@Action
alarm.delay alarm.capture;
2 $last=slept;
4 $last=slept;
@
```

实参覆盖局部默认的 `delay=1`，依次产生 `slept=2、3、4、5`；调用者的 `last` 最终为 5。
内部 `$delay=slept` 只更新本次调用的临时数值，`output` 别名和内部捕获均不泄漏到调用者。

### 普通动作调用 `reflexName.varName`

- 目标支持一层 `@Alias` 间接引用及 `$(...)` 动态表头，和器件一致。
  registry 中已有变量优先于同名 Reflex；反射不是 SQL 器件，不会出现在硬件清单里。
- `varName` 是反射内的临时变量/别名名，无需预先声明，必须符合 `[A-Za-z_][A-Za-z_0-9]*`。
  字面参数名不会因外层同名 Alias/Vars 改成其值；动态参数名显式写 `alarm.$(key)`。
- 数据格按普通 Action 规则求值：数值绑定为临时 `Vars`，文本绑定为临时 `Alias`；
  `2` 和 `$(1+1)` 可参与内部算术，`$("2")` 仍是文本，布尔不能作为动作参数。
  数字参数不会因外层 `Vars.precision` 变成文本，保留原始数值；直接传给器件的现有 precision 规则不变。
- 同一行中，同一反射的多列合成一次调用。整行先求值，再按表头首次出现顺序串行派发；
  反射块体执行完毕才继续下一个目标。`-` 使用普通 Action 继承语义，内部继承每次调用重新开始。
- `f.capture` 对齐 `$value=字段` 时只捕获，**不发送 `capture` 形参**；捕获列本身即可触发调用。
  不需要参数也不捕获时，可用表头 `f.unused`、数据格 `0` 调用，`unused` 只是未使用的普通形参；
  没有特殊预留的 `call` 接口。

### 调用局部默认值与捕获

- `@Alias` / `@Vars` 可直接声明在 Reflex **根 body**，每次调用先建立局部默认值，再绑定实参；
  实参按类型覆盖同名默认值。它们不能声明在其中的 Action 或控制块内，`@Struct(name)` 仍只能顶层声明。
- 局部声明与参数可临时覆盖外层已有 Alias/Vars，但不能覆盖 driver、Daemon、Struct 或 SQL
  controller/trigger 受保护引用。未传参数时使用局部默认值，否则读取外层可见值；求值到未定义名字时报错，不补零。
  临时数值和别名允许通过后续捕获更新，仍遵守第 5 节的类型规则。
- **所有内部 capture 都只在本次调用内可见**，不论目标是形参、新名字、已有标量，还是外层全局 Struct 的整值或成员。
  正常结束、失败或取消都会恢复调用前的变量层；新捕获名也随调用移除。变量恢复不撤销已发生的器件动作。
- 写回调用者必须由外层捕获列显式完成，例如 `f.capture` 配 `$state.login=status`，读取本次调用
  **最后一次内部实际器件调用的结果**，不是内部局部变量。没有实际调用时返回 `{"result":"OK"}`，不向 `outputs` 添加项目。
  有实际调用时 `outputs` 仍是内部器件回执的平铺序列，不额外重复一份 Reflex 回执。
- Action、控制块和 Reflex body 中均可通过表头调用其他 Reflex 或递归调用自身，但不能嵌套声明 Reflex。
  每一层调用的 Alias/Vars、参数和 capture 独立隔离；内层结束恢复外层调用的局部状态，内层结果也须显式捕获才能写回。
  嵌套调用最多 32 层，与 Action/控制块的组合嵌套也受执行深度限制；共用执行预算、取消信号和输出限额，不会因递归重置预算。

例如把反射的最终回执用于调用者的循环条件：

```mt
@Vars
name value;
count 0;
@
@Reflex(step)
relay0.test;
$(delay+1);
@
@while(count<3)
step.delay step.capture;
$(count) $count=slept;
@
```

这里 `step.capture` 不传形参，显式把 `slept=1、2、3` 写回调用者的 `count`。

## 8. @Include / @Merge 复用

```mt
@Include
path;
common/head.mt;
@

@Merge
path    phase;
frag/beep.mt  5;
@
```

- `@Include`：列只允许 `path`。**复制**被引文件的块序列到当前位置，可导入顶层
  `@Reflex(name)` 等定义；只能出现在最外层，不能放进任何 body。
  只能引用**动作脚本所在目录内**的相对 `.mt` 路径（拒绝绝对路径、`..`、反斜杠、冒号、
  软链/junction）；循环引用报错，非递归重复复制合法，但复制后定义重名仍报错。
- 顶层 `@Merge`：列允许 `path` 与可选 `phase`（整数，行相位偏移，不是时间或并行执行）。
  从片段合并 `@Alias` / `@Vars` / `@Action`，并保留 `@Struct(name)` 声明
  （片段里只允许这些块加顶层 `@Merge` 引用，Reflex 定义应使用 Include 导入）：
  - 父脚本显式声明的同名标量覆盖子片段定义；两个兄弟片段的同名标量若没有父级定义覆盖，
    会报重复错误，不是后出现者覆盖前者；Struct 不应用该覆盖规则，同名声明在运行前注册时拒绝；
  - 纯矩阵 Action 按列拼接、按 `phase` 对齐行；两个待合并矩阵的设备表头标识重复即报错；
    含嵌套 Action/if/while 的动作块不能参与横向合并；
  - 缺行补 `-`：前部等待首个有效值，尾部则继承并重复调用，不代表停止；
  - 负相位会丢弃片段前部数据行并告警，丢掉全部行则报错；首次引入 Action 且尚无
    主矩阵时，该片段的 `phase` 不生效；
  - 主脚本和各片段分别只取第一张 `@Action`，后续 Action 丢弃并告警。
- `*.once.mt`：顶层 Merge 引用树中，同一解析后的文件路径只合并一次；普通 `.mt`
  重复引用或形成环会报错。Include 不适用 once 语义，重复引用仍会重复复制。
- **Action / Reflex / 控制块 body 内的局部 @Merge**：指令必须位于要合并的纯矩阵**之前**，
  只并入其后的该矩阵，不合并前一张表，也不能横向合并嵌套 Action/控制块。
  片段只能包含纯矩阵，不能含声明、嵌套动作块或 Include/Merge；同样只允许 `path`/`phase` 列，
  不采用顶层 Merge 引用树的 once 去重机制。
- 智能体执行前仍沿用原有的脚本冻结顺序，保留命名定义及嵌套结构，不另设 Reflex 执行阶段。
- 限额：Include/Merge 合计 ≤32 个引用项、深度 ≤32、累计读取 ≤8 MiB；
  两矩阵合并输出 ≤20000 数据行 / ≤200000 数据格。

## 9. JSON 结构变量 @Struct(name)

`@Struct(name)` 声明本次运行内可变的 JSON 变量，块体是一个完整 JSON 值，**不是矩阵**。
以下完整示例可配合 `robots/relay-test.sql` 运行，无需物理设备：

```mt
@Struct(state)
{
  "count": 0,
  "points": [{"x": 10, "y": 20}],
  "enabled": true,
  "note": "空白、#、;、@ 在 JSON 字符串中原样保留"
}
@
@while(state.enabled&&state.count<3)
@Action
relay0.test relay0.capture;
$(state.count+1) $state.count=slept;
@
@
@Action
relay0.test relay0.capture;
$(state.points[0].x) $state.points[0].x=slept;
@
```

该例依次返回 `slept=1、2、3、10`，运行结束后 `state` 被移除。

### 声明与读取

- 名称必须符合 `[A-Za-z_][A-Za-z_0-9]*`，例如 `@Struct(state)`；名称内不允许连字符。
  只能在顶层声明，Reflex 内也不能声明；与顶层 Alias/Vars 一样在动作开始前统一注册，不能重复声明或遮蔽已有变量。
- 声明行可带 `#` 尾随注释；JSON 块体从下一行开始，支持 object、array、字符串、数值、
  布尔和 null，用独占一行的 `@` 结束。JSON 后不加 `;`，块体不允许注释、尾逗号、
  重复对象键、NaN/Infinity 或非有限数值。
  JSON 字符串使用标准 JSON 转义，与 MT 表达式字符串的转义集合不同。
- `$(state.count)` 读取 object 字段；`$(state.points[0].x)` 读取嵌套字段。
  `.字段` 仅查 JSON 对象键，不访问 Python 属性；字段名使用标识符语法。
- 数组从 **0** 开始，支持 `[i]`、`[i+1]` 等下标表达式；下标须为非负有限整数值，
  布尔、小数、负数、字符串和越界下标均报错。访问缺失字段或对错误类型取字段/下标也报错。
- object、array、null 可存储、捕获和用于逐层访问，但不能作为表达式最终结果或参与运算。
  最终选出的数值/文本可用于动作参数，布尔可用于 `@if` / `@while` 条件。
  Struct 不是设备，不能直接作为 Action 的调用目标。

### 捕获赋值

| 目标写法 | 含义 |
| --- | --- |
| `$state=payload` | 用驱动结果中的 `payload` 整体替换已声明的 Struct |
| `$state.count=count` | 替换已存在的 object 字段 |
| `$state.points[0]=point` | 替换已存在的 array 元素 |
| `$state.points[i].x=x` | 替换数组元素中的字段，下标可以是表达式 |

- 赋值可改变整值、字段或元素的 JSON 类型，但必须保持为合法、有界的 JSON 值。
  不隐式创建字段、不扩展数组；必须先声明 Struct，不能通过捕获自动推断出一个结构变量。
- 与其他捕获一样，先完成本行全部参数和目标下标的求值，再调用设备并依次写入结果。
  本行前面的捕获不会改变本行已计算的参数或下标，下一行或下一块才使用新值。
- 赋值使用独立的新值，不修改此前返回的驱动回执。目标路径错误时，设备调用可能已经发生，
  报错不会撤销硬件副作用。
- Struct 声明及赋值最多在本次 `Robot.run` 内生效，正常或异常结束都会恢复进入前的变量层。
  Reflex 内即使捕获到全局 Struct 的整值或成员，也仅在本次调用内可见，调用结束或失败即恢复；
  向调用者写回须使用外层 `f.capture` 捕获最后一次内部器件结果（第 7 节）。
  不允许用 Reflex 参数、CLI `--var` 或同名 Alias/Vars 声明替换 Struct。
- Include 和顶层 Merge 保留原始 JSON 语义，智能体执行前冻结脚本时同样保留；任何 body 内的
  局部 Merge 片段都不能包含 Struct 声明。Struct 同名声明不采用 Merge 的标量覆盖规则。
- 单个 Struct 的规范 JSON 序列化最多 8 MiB，值嵌套深度最多 32；捕获赋值也受这些限制。

## 10. Camera 通用动作

`scripts/Camera.mt` 抓取一帧并返回图片。默认目标变量是 `cam`；其他名称用
`--var cameraVar=<name>`（或智能体 `run_action_script` 的 `vars={"cameraVar": "..."}`）覆盖：

```sh
pymybot run --robot robots/camwin.sql --input scripts/Camera.mt --allow-hardware
pymybot run --robot robots/camwin.sql --input scripts/Camera.mt --allow-hardware --var cameraVar=cam0
```

Windows 示例见 `robots/camwin.sql`（DirectShow 设备序号，0 为第一个摄像头）。
文件图片源在 SQL 中声明 `src` 并给 `--camera-src-dir`，不需要 `--allow-hardware`。
