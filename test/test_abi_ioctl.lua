-- test_abi_ioctl.lua - LuaJIT ffi 变参 ABI 离线代理回归（审计覆盖缺口 #5）
-- 背景：test_jit_warmup.lua 需要真实 /dev/i2c-* 总线，CI 容器永远没有——
-- 但 JIT ABI 回归的本质与总线无关：变参 C 函数（ioctl）收到 Lua number 实参时，
-- 解释执行按 int 传递、JIT 编译后（约 56 次阈值起）按 double 位模式传递。
-- HAL.sys.ioctl_i 的修复是显式 ffi.cast("unsigned long", val)——本测试用
-- 纯用户态的 pipe + FIONREAD 锁定同一条代码路径：
--   1. 在堆上分配 int 接收缓冲，把它的【数值地址】作为 Lua number 传入 ioctl_i
--      （x86_64/aarch64 用户态地址 ≤ 2^47，double 可精确表示）；
--   2. 若 ABI 破损（cast 丢失，number 按 double 位模式进变参），内核收到的
--      「指针」是垃圾 → ioctl 返回 -1 / EFAULT；
--   3. 循环 300 次远超 JIT 阈值，锁定编译后路径。
-- 有真机时 test_jit_warmup.lua 仍作为端到端附加确认；本测试让 ABI 防线
-- 在无总线的 CI 上也全绿。
--
-- 用法（项目根目录）: luajit test/test_abi_ioctl.lua

local HAL = dofile("modules/lib/HAL.lua")
if HAL.backend ~= "ffi" then
	print("[SKIP] 非 ffi 后端（需 LuaJIT），跳过")
	return
end

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 check 曾与 tester.check 逐字重复）
local tester = dofile("test/lib/tester.lua")
local check = tester.check

local ffi = require("ffi")
ffi.cdef([[
	int pipe(int fds[2]);
	typedef struct { long fds[2]; } pipe_fds_t;
]])

-- FIONREAD（Linux 全架构同一编号）：取管道内可读字节数，arg 为 int* 接收指针
local FIONREAD = 0x541B

local fds = ffi.new("int[2]")
if ffi.C.pipe(fds) ~= 0 then
	print("[FAIL] pipe() 创建失败，无法进行 ABI 测试")
	os.exit(1)
end
local rfd, wfd = fds[0], fds[1]

-- 接收缓冲：FIONREAD 的 int* 出参。取其数值地址作 Lua number——
-- 用户态地址 ≤ 2^47 < 2^53，double 精确；ABI 破损时该值按 double 位模式
-- 被解释成整参就是天文数字指针 → EFAULT。
local nbuf = ffi.new("int[1]")
local addr_num = tonumber(ffi.cast("intptr_t", nbuf))
check("缓冲地址可精确表示为 Lua number", addr_num ~= nil and addr_num > 0, addr_num)

-- 写 N 字节 → ioctl_i(FIONREAD) 应返回 N；循环 300 次远超 JIT 阈值（56）
local N = 300
local bad_arg, bad_count = 0, 0
local buf = ffi.new("unsigned char[64]")
for i = 1, N do
	local want = i % 64
	if want == 0 then want = 64 end
	-- 写 want 字节进管道
	local written = 0
	while written < want do
		local w = tonumber(HAL.sys.write(wfd, buf, want - written))
		if w == nil or w <= 0 then break end
		written = written + w
	end
	-- 被测路径：数值地址作为 Lua number 经 ioctl_i（内部 ffi.cast("unsigned long", val)）
	local rc = HAL.sys.ioctl_i(rfd, FIONREAD, addr_num)
	if rc ~= 0 then
		bad_arg = bad_arg + 1
	else
		local got = nbuf[0]
		if got ~= want then bad_count = bad_count + 1 end
	end
	-- 排空管道（精确读回 want 字节：阻塞模式下空读会挂死，不能循环试探）
	local drained = 0
	while drained < want do
		local r = tonumber(HAL.sys.read(rfd, buf, want - drained))
		if r == nil or r <= 0 then break end
		drained = drained + r
	end
end

check(string.format("%d 次 ioctl_i(数值地址作变参) 全部成功（含 JIT 编译后路径）", N), bad_arg == 0,
	string.format("异常 %d 次（ABI 破损特征：double 位模式进变参 → EFAULT）", bad_arg))
check("FIONREAD 计数与写入字节数一致", bad_count == 0, string.format("计数不符 %d 次", bad_count))

HAL.sys.close(rfd)
HAL.sys.close(wfd)

tester.summary("test_abi_ioctl.lua")
