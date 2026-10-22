# 虚拟器件模型（\*_VIRT）

技能 `pymybot-scripting` 参考文件。仓库根为 `mybot/`（Python 主线）。
实现：`modules/lib/virtbus.lua`（内存总线与寄存器模型）、
`modules/lib/drv_common.lua` 的 `virt_prepare`（发现/挂载/注入）。

## 1. 机制

- 器件行 `proto='virt'` → 驱动入口的 `arg_table` 代调 `virt_prepare`：加载 virtbus、
  在当前状态机里发现内嵌 `*_VIRT` 工厂表（**恰好一个**，多于一个点名报错）、
  实例化（`new()`）、按身份挂载（I2C 按地址、UART 按 tty 路径）、登记 fd、注入。
- 找不到模型 → `proto=virt setup failed: ... no embedded <DRIVER>_VIRT model`，
  **绝不静默回落真机**。
- 注入成功后 stderr 打印横幅：
  ` [drv_common] *** VIRTUAL HARDWARE -- NO REAL DEVICE *** (...)`。
- 守护路径（sensor_daemon）与挂载分派共用 `virtbus.attach_model`；同进程混跑
  真机 + 虚拟时按 fd 路由。
- HTTP 总线**没有** virtbus/virt 模型：无硬件验证走本地回环假服务器
  （`tests/test_qsont.py` 的 ThreadingHTTPServer 即范本），proto 列与 HTTP 无关。

## 2. 编写约定（以 `CHT8305_VIRT` 为范本）

写在驱动文件**尾部**（生产路径零执行）：

```lua
MyDev_VIRT = { _VERSION = "0.1.0" }

function MyDev_VIRT.new(seed)
    local d = {}
    -- ---- 芯片侧状态（寄存器、指针、就绪门 ...）----

    -- 总线回调：点定义（无 self），契约固定
    function d.write(bytes)   -- bytes: 1-based 字节表；返回 boolean
        ... return true
    end
    function d.read(n)        -- 返回字节表或 nil（NACK/未就绪）
        ... return out
    end

    -- ---- 测试 / 守护 API：冒号定义 ----
    function d:advance(ms) ... end      -- 推虚拟时钟（转换门）
    function d:reset() ... end          -- 回 POR
    function d:clear_faults() ... end   -- 解除故障注入
    function d:virt_tick(n) ... end     -- 守护逐拍造确定性样本 + 预武装
    return d
end
```

- 工厂经**全局表**暴露（不靠文件 return，宿主以 pcall 多返回加载，返回值会滞留栈）。
- UART 模型在工厂/实例上标 `BUS = "uart"`（挂载身份取 tty 路径）；缺省 I2C；
  SPI 器件模型当前只走守护路径（不做直驱挂载）。
- **模型与驱动独立实现**（互证防假绿）：模型只复刻协议层事实（寄存器语义、
  NACK、转换门），换算公式归驱动。
- 故障注入钩子（按需提供）：`d.nack / d.nack_read / d.nack_write`、
  `d:fail_write(pred)` / `d:fail_read(pred)`、`d:set_never_ready(on)` 等，
  供负路径测试。
- `seed` 构造参数：合法字段播种，任一非法整体回 POR（不采纳半份种子）。
- `virt_tick(n)`：守护每次采样间隔调用，造确定性数据并「预武装」，
  让真实驱动的 build/call 全链路在守护线程里照常跑（含真实 `milli_sleep`）。
