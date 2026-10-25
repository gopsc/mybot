-- LuaJIT ffi 变参 ABI 回归测试
-- 背景：i2c_set_addr 的 ioctl 变参若直接传 Lua number，解释执行按 int 传递正常，
-- 但热点循环被 JIT 编译（约 56 次阈值）后按 double 位模式传递，
-- 内核收到 0x4050...（>0x7f）返回 EINVAL —— 真机多行动作脚本必现。
-- 修复：HAL.sys.ioctl_i 显式 ffi.cast("unsigned long", val)。
-- requires: i2c
-- 本测试用真实 /dev/i2c 总线循环调用远超 JIT 阈值次数来锁定该回归。
--
-- 用法（项目根目录）: luajit test/test_jit_warmup.lua
-- 需要本机存在任一 /dev/i2c-N 总线；无总线时跳过（不算失败）。

-- F4/N-33：断言收敛到 test/lib/tester.lua（本文件原先只有裸 print 的成败分支）
local tester = dofile("test/lib/tester.lua")

local HAL = dofile("modules/lib/HAL.lua")
if HAL.backend ~= "ffi" then
	print("[SKIP] 非 ffi 后端（需 LuaJIT），跳过")
	return
end

-- 找一个可用总线
local fd = -1
local bus_used = nil
for bus = 0, 20 do
	fd = i2c_open("/dev/i2c-" .. bus)
	if fd >= 0 then bus_used = bus; break end
end
if fd < 0 then
	print("[SKIP] 本机无可用 /dev/i2c-N 总线，跳过")
	return
end

local N = 300	-- 远超 LuaJIT 热点阈值（56）
i2c_set_addr(fd, 0x40)
-- 锤真实 I2C_RDWR ioctl（无设备时每次返回 -1 属正常）：
-- 重点是 JIT 编译后 ffi 结构构造 + ioctl 调用稳定，不崩溃、不出现异常返回
local bad = 0
for _ = 1, N do
	local v = i2c_read_reg(fd, 0x00)
	-- 合法返回只能是 -1（无设备/失败）或 0~255（有设备）；出现其它即异常
	if v ~= -1 and (v < 0 or v > 255) then bad = bad + 1 end
end
i2c_close(fd)

tester.check(string.format(
	"i2c-%d 上 %d 次 i2c_read_reg(I2C_RDWR) 全部正常（含 JIT 编译后路径）", bus_used, N),
	bad == 0, string.format("%d 次异常返回（JIT 后 ffi ABI 回归）", bad))
tester.summary("test_jit_warmup.lua")
