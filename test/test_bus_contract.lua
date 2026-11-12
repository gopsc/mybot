-- test_bus_contract.lua - 数值归一化契约回归（2026-09-20 审计 C2）
--
-- 背景：byte_of / uint_of 是全仓唯一的字节/非负整数归一化点（HAL 真机路径与
-- virtbus 虚拟总线共用同一份），注释承诺「非法返回 nil」。但旧实现只写
-- `n = math.floor(n); if n < 0 or n > 255 then return nil end`，而 LuaJIT 下
--    math.floor(NaN) = NaN，且 NaN < 0、NaN > 255 均为 false
-- —— NaN（含字符串 "nan"/"inf"，tonumber 亦返回 NaN/inf）被当作**合法值**返回，
-- 一路走到 ffi.new("uint8_t", NaN) 变成 0x00：
--   HAL.i2c_write_reg(fd, reg, NaN) 返回成功但线上写的是 0x00；
--   PCA9685 的 NaN 角度穿透 0..180 夹取后写成 ON=0/OFF=0（无脉冲）却返回 OK。
-- 这是「静默错写真实硬件」这一类里最坏的一种：既不报错，也看不出值被改过。
--
-- 用法（项目根目录）: luajit test/test_bus_contract.lua
local tester = dofile("test/lib/tester.lua")

local bus = dofile("modules/lib/bus_contract.lua")
dofile("modules/lib/drv_common.lua")		-- 定义 int_or / num_or（纯 Lua，无 HAL 依赖）

local nan = 0 / 0
local inf = math.huge

-- ---- byte_of：非有限值必须被拒 ----

tester.check("byte_of(NaN) 返回 nil", bus.byte_of(nan) == nil)
tester.check("byte_of(inf) 返回 nil", bus.byte_of(inf) == nil)
tester.check("byte_of(-inf) 返回 nil", bus.byte_of(-inf) == nil)
tester.check("byte_of('nan') 返回 nil", bus.byte_of("nan") == nil)
tester.check("byte_of('inf') 返回 nil", bus.byte_of("inf") == nil)
tester.check("byte_of('1e400') 返回 nil（strtod 溢出为 inf）", bus.byte_of("1e400") == nil)
tester.check("byte_of(nil) 返回 nil", bus.byte_of(nil) == nil)
tester.check("byte_of(负数) 返回 nil", bus.byte_of(-1) == nil)
tester.check("byte_of(256) 返回 nil", bus.byte_of(256) == nil)

-- ---- byte_of：合法输入行为逐字不变（NaN 防线不得误伤）----

tester.check("byte_of(0) == 0", bus.byte_of(0) == 0)
tester.check("byte_of(255) == 255", bus.byte_of(255) == 255)
tester.check("byte_of(1.9) == 1（向下取整）", bus.byte_of(1.9) == 1)
tester.check("byte_of('7') == 7（字符串数字）", bus.byte_of("7") == 7)
tester.check("byte_of(0x0F) == 15", bus.byte_of(15) == 15)

-- ---- uint_of：非有限值必须被拒（+inf 旧实现会原样返回）----

tester.check("uint_of(NaN) 返回 nil", bus.uint_of(nan) == nil)
tester.check("uint_of(inf) 返回 nil", bus.uint_of(inf) == nil)
tester.check("uint_of(-inf) 返回 nil", bus.uint_of(-inf) == nil)
tester.check("uint_of('nan') 返回 nil", bus.uint_of("nan") == nil)
tester.check("uint_of(-1) 返回 nil", bus.uint_of(-1) == nil)

tester.check("uint_of(0) == 0", bus.uint_of(0) == 0)
tester.check("uint_of(3.7) == 3", bus.uint_of(3.7) == 3)
tester.check("uint_of(1000000) == 1000000", bus.uint_of(1000000) == 1000000)

-- ---- bus.int_of：严格整数判据（拒绝非整数）单点 ----
-- 主评估 A：HAL.spi_setup 走 uint_of（math.floor 静默取整）、virtbus.v_spi_setup
-- 显式拒绝非整数 —— 同一条判据两库相反，同样破坏总线契约（仿真绿真机红）。
-- 修复把判据下沉到本函数，HAL 与 virtbus 共同调用。判别性：改前 bus.int_of
-- 不存在（判据散在 virtbus 里手工镜像）→ 下面「返回 number」的断言必失败；
-- 此处以 nil 兜底，令失败以 [FAIL] 呈现而非 ``attempt to call nil`` 中断。
local bus_int_of = bus.int_of or function() return nil end

tester.check("int_of(2, 0, 3) == 2（合法整数透传）", bus_int_of(2, 0, 3) == 2)
tester.check("int_of(0, 0, 3) == 0（下界 0 是合法值，不被 falsy 吞）", bus_int_of(0, 0, 3) == 0)
tester.check("int_of(3, 0, 3) == 3（上界含）", bus_int_of(3, 0, 3) == 3)
tester.check("int_of(4, 0, 3) == nil（越上界拒绝）", bus_int_of(4, 0, 3) == nil)
tester.check("int_of(-1, 0, 3) == nil（越下界拒绝）", bus_int_of(-1, 0, 3) == nil)
tester.check("int_of(2.0, 0, 3) == 2（整数取值的浮点接受）", bus_int_of(2.0, 0, 3) == 2)
tester.check("int_of(1.9, 0, 3) == nil（小数拒绝，不静默 floor）", bus_int_of(1.9, 0, 3) == nil)
tester.check("int_of(8, 7, 16) == 8（bits 区间内）", bus_int_of(8, 7, 16) == 8)
tester.check("int_of(7, 7, 16) == 7（bits 下界）", bus_int_of(7, 7, 16) == 7)
tester.check("int_of(16, 7, 16) == 16（bits 上界）", bus_int_of(16, 7, 16) == 16)
tester.check("int_of(8.5, 7, 16) == nil（bits 小数拒绝）", bus_int_of(8.5, 7, 16) == nil)
tester.check("int_of(255, 0, 255) == 255（字节上界）", bus_int_of(255, 0, 255) == 255)
tester.check("int_of(256, 0, 255) == nil（字节越界）", bus_int_of(256, 0, 255) == nil)
tester.check("int_of(NaN, 0, 3) == nil", bus_int_of(nan, 0, 3) == nil)
tester.check("int_of(inf, 0, 3) == nil", bus_int_of(inf, 0, 3) == nil)
tester.check("int_of(-inf, 0, 3) == nil", bus_int_of(-inf, 0, 3) == nil)
tester.check("int_of('nan', 0, 3) == nil", bus_int_of("nan", 0, 3) == nil)
tester.check("int_of(nil, 0, 3) == nil", bus_int_of(nil, 0, 3) == nil)
tester.check("int_of('8', 7, 16) == 8（字符串整数数字）", bus_int_of("8", 7, 16) == 8)
tester.check("int_of('7.5', 7, 16) == nil（字符串小数拒绝）", bus_int_of("7.5", 7, 16) == nil)
tester.check("int_of(1, 1) == 1（上界缺省：只判下界）", bus_int_of(1, 1) == 1)
tester.check("int_of(1e6, 1) == 1e6（无上界放行大值）", bus_int_of(1e6, 1) == 1e6)
tester.check("int_of(0, 1) == nil（下界拒绝）", bus_int_of(0, 1) == nil)

-- ---- drv_common.int_or：钳制语义（原名 int_of，与 bus.int_of 撞名，见下），但非有限值必须回落缺省 ----

tester.check("int_or(NaN, 9, 0, 100) == 9", int_or(nan, 9, 0, 100) == 9)
tester.check("int_or(inf, 9, 0, 100) == 9", int_or(inf, 9, 0, 100) == 9)
tester.check("int_or(-inf, 9, 0, 100) == 9", int_or(-inf, 9, 0, 100) == 9)
tester.check("int_or('nan', 9, 0, 100) == 9", int_or("nan", 9, 0, 100) == 9)
tester.check("int_or('-' , 9, 0, 100) == 9（占位符）", int_or("-", 9, 0, 100) == 9)
tester.check("int_or(1e9, 0, 0, 100) == 100（钳上界不变）", int_or(1e9, 0, 0, 100) == 100)
tester.check("int_or(-5, 0, 0, 100) == 0（钳下界不变）", int_or(-5, 0, 0, 100) == 0)
tester.check("int_or(42, 0, 0, 100) == 42", int_or(42, 0, 0, 100) == 42)

-- ---- drv_common.num_or：非有限值必须回落缺省 ----

tester.check("num_or(NaN, 3) == 3", num_or(nan, 3) == 3)
tester.check("num_or(inf, 3) == 3", num_or(inf, 3) == 3)
tester.check("num_or('nan', 3) == 3", num_or("nan", 3) == 3)
tester.check("num_or(nil, 3) == 3", num_or(nil, 3) == 3)
tester.check("num_or('2.5', 3) == 2.5", num_or("2.5", 3) == 2.5)
tester.check("num_or(0, 3) == 0（0 是合法值，不得被 or 吞）", num_or(0, 3) == 0)

-- ---- drv_common.finite_of：导出给驱动解析「样本列」用（2026-09-20 评估）----
-- 语义 = tonumber + 非有限拒绝、非法返回 nil（不回落缺省）；Ema/Kalman 的
-- in/field 样本列依赖它，退回 local 会让那两个驱动静默失去防线。

tester.check("finite_of 已导出为全局（驱动可用）", type(finite_of) == "function")
tester.check("finite_of('nan') == nil（NaN 不得放行）", finite_of("nan") == nil)
tester.check("finite_of(NaN) == nil", finite_of(nan) == nil)
tester.check("finite_of(inf) == nil", finite_of(inf) == nil)
tester.check("finite_of('-inf') == nil", finite_of("-inf") == nil)
tester.check("finite_of('x') == nil", finite_of("x") == nil)
tester.check("finite_of(nil) == nil", finite_of(nil) == nil)
tester.check("finite_of('2.5') == 2.5", finite_of("2.5") == 2.5)
tester.check("finite_of(0) == 0（0 合法）", finite_of(0) == 0)

-- 改名回归（审计 2.4）：drv_common 的钳制助手原叫 int_of，与 bus_contract 的
-- 严格判据 int_of(v, lo, hi) **同名不同元**；两者在同一个 Lua 状态里都可见，
-- 按 3 参调用会把 def 静默绑到 lo、区间整体错位却不报错。钳制那份已改名 int_or
-- （语义断言见上面「drv_common.int_or」小节），这里只钉住「全局不再有 int_of」。
tester.check("全局不再有 int_of（避免与 bus_contract.int_of 撞名）", _G.int_of == nil)

tester.summary("test_bus_contract")
return 0
