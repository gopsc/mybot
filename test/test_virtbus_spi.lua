-- test_virtbus_spi.lua - 虚拟 SPI 总线回归（virtbus 0.2.0：spi_* 注入层）
-- 验证 modules/lib/virtbus.lua 的 SPI 契约：
--   1) spi_open 路径白名单、fd 与 I2C 共用编号空间；
--   2) spi_setup 参数校验（mode 0~3 / bits 7~16 / speed>0）与配置留痕；
--   3) 传输族（write/read/write3/write_multi/read_multi）全双工 CS 帧语义：
--      一次调用 = 一个 x 事务（write_multi 64B 也只一条），纯写也有同帧 rx；
--   4) delay_us 钳到 65535、字节校验同 HAL（非字节不发帧 → -1）；
--   5) 无挂载路径/未打开 fd/模型主动故障 → -1；setup 面向控制器，无挂载也成功；
--   6) attach_spi 动态委托、同路径多 fd、close 生命周期；
--   7) I2C/SPI 两套全局在同一注入态下并存；restore/reset 连 spi_* 一起还原；
--   8) LuaJIT 下挂着虚拟 SPI 跑真实 modules/SPI.lua（@SPI chunk build/call/destroy）。
-- 用法（项目根目录）: lua5.4 test/test_virtbus_spi.lua（run_all.sh 自动纳入；纯 Lua
-- 核心断言在 lua5.4 可跑；真实 SPI chunk 集成段仅 LuaJIT 执行）
local tester = dofile("test/lib/tester.lua")
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- txlog 中最后一条 x 帧
local function last_x()
	for i = #vbus.txlog, 1, -1 do
		if vbus.txlog[i].dir == "x" then return vbus.txlog[i] end
	end
end

-- 统计 setup/x 条目
local function count_dir(d)
	local n = 0
	for _, e in ipairs(vbus.txlog) do if e.dir == d then n = n + 1 end end
	return n
end

-- ==================== 1) open / setup ====================
vbus.inject()
tester.check("inject 后 spi_open 已替换", spi_open == vbus.v_spi_open)
tester.check("inject 后 spi_read_multi 已替换", spi_read_multi == vbus.v_spi_read_multi)

local fd = spi_open("/dev/spidev0.0")
tester.check("spi_open 合法路径返回虚拟 fd=3（与 I2C 共用编号空间）", fd == 3)
tester.check("spi_open 非法路径 -1", spi_open("/dev/fake") == -1)
tester.check("spi_open 非字符串 -1", spi_open(nil) == -1)
tester.check("spi_open 缺片选位 -1", spi_open("/dev/spidev0") == -1)

local fd_b = spi_open("/dev/spidev1.2")
tester.check("第二个 SPI fd 顺序编号=4", fd_b == 4)

tester.check("spi_setup 合法参数返回 0", spi_setup(fd, 1, 8, 1000000) == 0)
local se
for i = #vbus.txlog, 1, -1 do
	if vbus.txlog[i].dir == "setup" then se = vbus.txlog[i]; break end
end
tester.check("setup 留痕 mode/bits/speed/path",
	se ~= nil and se.path == "/dev/spidev0.0"
	and se.mode == 1 and se.bits == 8 and se.speed == 1000000)
tester.check("spi_setup mode=4 拒绝", spi_setup(fd, 4, 8, 1e6) == -1)
tester.check("spi_setup mode=-1 拒绝", spi_setup(fd, -1, 8, 1e6) == -1)
tester.check("spi_setup bits=6 拒绝", spi_setup(fd, 0, 6, 1e6) == -1)
tester.check("spi_setup bits=17 拒绝", spi_setup(fd, 0, 17, 1e6) == -1)
tester.check("spi_setup speed=0 拒绝", spi_setup(fd, 0, 8, 0) == -1)
tester.check("spi_setup speed=小数 拒绝", spi_setup(fd, 0, 8, 999.5) == -1)
tester.check("spi_setup mode=小数 拒绝", spi_setup(fd, 0.5, 8, 1e6) == -1)
tester.check("spi_setup bits=小数 拒绝", spi_setup(fd, 0, 8.5, 1e6) == -1)
tester.check("spi_setup 未打开 fd 拒绝", spi_setup(999, 0, 8, 1e6) == -1)
-- 真机 setup 是控制器 ioctl，总线上无器件也成功；同路径此时尚未挂载模型
tester.check("spi_setup 无挂载路径仍成功（控制器语义）", spi_setup(fd_b, 0, 8, 500000) == 0)

-- ==================== 2) attach 与写族（全双工 CS 帧） ====================
local last_tx
local resp = { 0xAA }
local fake = {
	xfer = function(tx) last_tx = tx; local out = {}; for i = 1, #tx do out[i] = resp[i] or 0 end; return out end,
}
vbus.attach_spi("fake-spi", "/dev/spidev0.0", fake)

tester.check("spi_write 返回 0", spi_write(fd, 0x5A) == 0)
tester.check("模型收到帧 {0x5A}", #last_tx == 1 and last_tx[1] == 0x5A)
local x1 = last_x()
tester.check("x 帧留痕 path/tx/rx/ok",
	x1.path == "/dev/spidev0.0" and #x1.tx == 1 and x1.tx[1] == 0x5A
	and #x1.rx == 1 and x1.rx[1] == 0xAA and x1.ok == true and x1.delay == nil)

-- 纯写在真机也全双工：调用方虽丢弃返回值，txlog 仍有同帧 rx（命令态回读可建模）
resp = { 0x77 }
tester.check("纯写同帧 MISO 仍留痕（全双工事实）", (function()
	spi_write(fd, 0x01)
	local e = last_x()
	return e.ok and #e.rx == 1 and e.rx[1] == 0x77
end)())

-- 字节校验同 HAL：非法值不发帧
local before_bad = count_dir("x")
tester.check("spi_write 256 返 -1 且不发帧", spi_write(fd, 256) == -1 and count_dir("x") == before_bad)
tester.check("spi_write -1 返 -1 且不发帧", spi_write(fd, -1) == -1 and count_dir("x") == before_bad)
tester.check("spi_write 非数值 返 -1", spi_write(fd, "z") == -1 and count_dir("x") == before_bad)
-- 主评估 A：字节判据取严格口径（拒绝非整数）——HAL 侧此前静默 floor，两路径相反
tester.check("spi_write 小数 返 -1 且不发帧", spi_write(fd, 1.9) == -1 and count_dir("x") == before_bad)
tester.check("spi_write NaN 返 -1", spi_write(fd, 0 / 0) == -1 and count_dir("x") == before_bad)

-- delay 随帧留痕，钳 65535
spi_write(fd, 0x02, 100)
tester.check("delay_us=100 随帧留痕", last_x().delay == 100)
spi_write(fd, 0x02, 70000)
tester.check("delay_us=70000 钳到 65535", last_x().delay == 65535)
spi_write(fd, 0x02, -5)
tester.check("delay_us 负数按无 delay", last_x().delay == nil)

-- write3 字节序与校验
resp = { 0, 0, 0 }
tester.check("spi_write3 返回 0", spi_write3(fd, 0x11, 0x22, 0x33) == 0)
tester.check("write3 模型按序收三字节",
	#last_tx == 3 and last_tx[1] == 0x11 and last_tx[2] == 0x22 and last_tx[3] == 0x33)
tester.check("write3 单字节非法整帧不发", spi_write3(fd, 0x11, 0x100, 0x33) == -1)
-- 主评估 A：write3 任一字节为非整数即整帧拒绝（严格口径，与 HAL 一致）
tester.check("write3 小数字节整帧不发", spi_write3(fd, 0x11, 0.5, 0x33) == -1)
-- 主评估 A：spi_xfer_full 逐字节严格整数（此前无人覆盖小数字节）
tester.check("xfer_full 小数字节返 nil", spi_xfer_full(fd, { 0x30, 0.5 }) == nil)
tester.check("xfer_full 合法字节返等长表", type(spi_xfer_full(fd, { 0x30, 0x03 })) == "table")

-- write_multi：一次调用一个 CS 帧（不拆），1~64
resp = {}
local before_m = count_dir("x")
tester.check("spi_write_multi 返回 0", spi_write_multi(fd, { 0x01, 0x02, 0x03, 0x04 }) == 0)
tester.check("write_multi 4B 只产生 1 个 x 帧（单次 CS）",
	count_dir("x") == before_m + 1 and #last_x().tx == 4)
do
	local big = {}
	for i = 1, 64 do big[i] = i % 256 end
	tester.check("write_multi 64B 成功", spi_write_multi(fd, big) == 0)
	local big2 = {}
	for i = 1, 65 do big2[i] = 0 end
	tester.check("write_multi 65B 显式 -1", spi_write_multi(fd, big2) == -1)
end
tester.check("write_multi 空表 -1", spi_write_multi(fd, {}) == -1)
tester.check("write_multi 非表 -1", spi_write_multi(fd, 0x55) == -1)
tester.check("write_multi 含非法字节 -1", spi_write_multi(fd, { 0x01, 300 }) == -1)

-- ==================== 3) 读族：dummy MOSI + 大端合并 ====================
resp = { 0x65 }
tester.check("spi_read 返回 MISO 单字节", spi_read(fd) == 0x65)
tester.check("spi_read 的 MOSI 为全 0（真机 tx_buf=NULL）",
	#last_x().tx == 1 and last_x().tx[1] == 0)

resp = { 0x0A, 0x0B, 0x0C, 0x0D }
tester.check("spi_read_multi 4B 大端合并", spi_read_multi(fd, 4) == 0x0A0B0C0D)
tester.check("read_multi 模型收 4 个 dummy 字节",
	#last_x().tx == 4 and last_x().tx[1] == 0 and last_x().tx[4] == 0)
resp = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }
tester.check("spi_read_multi 6B 边界通过（2^53 精度上限）",
	spi_read_multi(fd, 6) == 0x010203040506)
tester.check("spi_read_multi n=7 越界 -1（HAL 上限 6）", spi_read_multi(fd, 7) == -1)
tester.check("spi_read_multi n=0 非法 -1", spi_read_multi(fd, 0) == -1)
-- F-07：HAL 的 spi_read_multi 用 uint_of 归一（小数向下取整后仍合法），
-- 旧 virt 实现按整数严格拒绝——接受集比真机窄，改为逐字对齐 HAL。
tester.check("spi_read_multi n=2.5 按 HAL uint_of 归一为 2（合并 0x0102）",
	spi_read_multi(fd, 2.5) == 0x0102)

-- 模型应答短于请求：补 0（不伪造器件数据，超出部分为 0 对调用方可见）
resp = { 0xAB, 0xCD }
tester.check("模型短应答补 0 合并", spi_read_multi(fd, 4) == 0xABCD0000)

-- ==================== 4) 负路径 ====================
-- 4.1 无挂载路径：setup 成功（前述），传输族全 -1（虚拟层的「设备不在」约定）
tester.check("无挂载 spi_write -1", spi_write(fd_b, 0x01) == -1)
tester.check("无挂载 spi_read -1", spi_read(fd_b) == -1)
tester.check("无挂载 spi_read_multi -1", spi_read_multi(fd_b, 2) == -1)
tester.check("无挂载 失败帧照样留痕 ok=false", last_x().ok == false and last_x().rx == nil)

-- 4.2 模型主动故障
fake.xfer = function() return nil end
tester.check("模型 xfer 返 nil：write -1", spi_write(fd, 0x01) == -1)
tester.check("模型 xfer 返 nil：read -1", spi_read(fd) == -1)
fake.xfer = function() return false end
tester.check("模型 xfer 返 false：write3 -1", spi_write3(fd, 1, 2, 3) == -1)

-- 4.3 未打开 fd
tester.check("未打开 fd spi_write -1", spi_write(999, 0x01) == -1)
tester.check("未打开 fd spi_read -1", spi_read(999) == -1)
tester.check("未打开 fd spi_write_multi -1", spi_write_multi(999, { 1 }) == -1)

-- ==================== 5) 动态委托 / 多 fd / close 生命周期 ====================
fake.xfer = function(tx) local t = {} for i = 1, #tx do t[i] = tx[i] ~= 0 and 0x00 or 0xFF end; return t end
tester.check("attach 后替换 xfer 即时生效（读 dummy 得 0xFF）", spi_read(fd) == 0xFF)

local fd_c = spi_open("/dev/spidev0.0")
tester.check("同路径第二个 fd 命中同一模型", spi_read(fd_c) == 0xFF)

spi_close(fd_c)
tester.check("close 后该 fd 传输 -1", spi_read(fd_c) == -1)
tester.check("close 不影响同路径其他 fd", spi_read(fd) == 0xFF)
spi_close(999) -- 无副作用
tester.check("close 未知 fd 不报错", true)

-- ==================== 6) I2C/SPI 并存与还原 ====================
vbus.attach("i2c-fake@0x23", 0x23, {
	write = function() end,
	read = function(n) local t = {} for i = 1, n do t[i] = 0x12 end; return t end,
})
local ifd = i2c_open("/dev/i2c-1")
i2c_set_addr(ifd, 0x23)
tester.check("同一注入态下 I2C 仍工作", i2c_read_reg(ifd, 0x10) == 0x12)
tester.check("同一注入态下 SPI 仍工作", spi_read(fd) == 0xFF)

vbus.restore()
tester.check("restore 后 spi_open 还原", spi_open == nil)
tester.check("restore 后 spi_write_multi 还原", spi_write_multi == nil)
tester.check("restore 后 i2c_open 还原", i2c_open == nil)

-- ==================== 7) 真实 SPI chunk 集成（仅 LuaJIT） ====================
if rawget(_G, "jit") ~= nil then
	vbus.reset()
	vbus.attach_spi("spi-chunk-dev", "/dev/spidev0.0", {}) -- 只写场景，默认全 0 xfer
	vbus.load_driver("modules/SPI.lua")
	tester.check("load_driver 后 spi_open 仍为虚拟实现", spi_open == vbus.v_spi_open)

	local r = build({ path = "/dev/spidev0.0", spi_mode = 1, bits = 8, speed = 1920000, delay = 100 })
	tester.check("真实 SPI.lua build 在虚拟总线上 OK", tostring(r.result) == "OK")
	tester.check("build 返回虚拟 fd", tonumber(r.fd) == 3)
	local s
	for i = #vbus.txlog, 1, -1 do
		if vbus.txlog[i].dir == "setup" then s = vbus.txlog[i]; break end
	end
	tester.check("chunk build 的 setup 参数留痕",
		s ~= nil and s.mode == 1 and s.bits == 8 and s.speed == 1920000)

	local c = call({ path = "/dev/spidev0.0" })
	tester.check("chunk call 返回 OK/fd/delay",
		tostring(c.result) == "OK" and tonumber(c.fd) == 3 and tonumber(c.delay) == 100)

	local bad = build({ path = "/dev/badpath", spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
	tester.check("chunk build 非法路径 ERR", tostring(bad.result) == "ERR")

	tester.check("chunk destroy OK", tostring(destroy({}).result) == "OK")
	vbus.reset()
	-- load_driver 后 originals 是真实 HAL 函数，reset 还原为真机版（非虚拟版）
	tester.check("reset 后 spi_open 还原为 HAL 版", spi_open ~= vbus.v_spi_open)
else
	tester.check("（lua5.4：跳过真实 SPI chunk 集成段，需 ffi）", true)
end

-- ==================== C7：采纳 fd 必须按总线归表（2026-09-20 审计） ====================
-- 旧实现把「除 uart 外的一切」都当 I2C 登记：adopt_fd(fd, path, addr, "spi")
-- 只写 open_paths/fd_addr，spi_paths[fd] 永远为空 —— 该 fd 上每次 spi_* 调用
-- 都在 `spi_paths[fd] == nil` 处返回 -1（"device absent"），而 txlog 已记下
-- 一条成功的 "adopt"，故障现象与成因完全脱节。
vbus.reset()
vbus.inject()
do
	local afd_spi, afd_i2c = 77, 78
	tester.check("adopt_fd(..., 'spi') 返回 true",
		vbus.adopt_fd(afd_spi, "/dev/spidev2.0", nil, "spi") == true)
	local rc = spi_setup(afd_spi, 1, 8, 1000000)
	tester.check("C7：采纳的 SPI fd 可用（setup 返回 0；修复前恒 -1）", rc == 0, tostring(rc))
	tester.check("C7：采纳的 SPI fd 未被误登记成 I2C（set_addr 拒绝）",
		vbus.v_i2c_set_addr(afd_spi, 0x48) == false)

	tester.check("adopt_fd(..., nil) 仍按 I2C 登记（既有语义不变）",
		vbus.adopt_fd(afd_i2c, "/dev/i2c-9", nil, nil) == true
		and vbus.v_i2c_set_addr(afd_i2c, 0x48) == true)
	tester.check("C7：I2C 采纳的 fd 不被 SPI 认（互不串表）",
		spi_setup(afd_i2c, 1, 8, 1000000) == -1)
end
vbus.reset()

tester.summary("test_virtbus_spi")
return 0
