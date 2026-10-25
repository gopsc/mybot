-- test_spi_int.lua - SPI 参数整数判据的「真机 HAL 路径 vs proto=virt 路径」对偶回归
--
-- 背景（2026-09-20 主评估 A）：同一条 SPI 参数判据此前两库相反——
--   HAL.spi_setup 走 bus.uint_of（内部 math.floor **静默取整**）：
--     spi_setup(fd, 1.9, 8.0, 1e6) 在真机上变成 mode=1 并成功；
--   而 virtbus.v_spi_setup 显式拒绝 mode ~= math.floor(mode) → 直接失败。
--   同族：HAL.spi_write/spi_write3/spi_xfer_full 走 byte_of（同样静默 floor），
--   virtbus 对应函数显式拒绝非整数。
--   判据**反向**漂移（真机宽松、仿真严格）与正向漂移同样是破坏总线契约的
--   「仿真绿真机红且无报错」——修复方向取**严格**口径（拒绝非整数），与同仓
--   先例一致（HAL GPIO offset 显式拒绝小数），并下沉到 bus_contract.int_of 单点。
--
-- 本文件钉死核心不变式：**同一组入参在两条路径上结论必须一致**（都拒绝/都接受）。
-- 判别性：改前 HAL 侧接受小数（返回 0/成功）、virtbus 侧拒绝 → 对偶断言必失败。
--
-- 用法（项目根目录）: luajit test/test_spi_int.lua
local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- ==================== 真机路径：HAL + mock 系统调用层 ====================
-- 同 test_hal_ffi 的间接层方法：替换 HAL.sys.* 记录/放行，不触硬件。
local HAL = dofile("modules/lib/HAL.lua")
HAL.sys.open = function() return 3 end
HAL.sys.close = function() end
HAL.sys.ioctl_p = function() return 0 end	-- setup 三 ioctl 与传输 ioctl 全成功
-- 2026-09-30 方案 A 重构：新增总线传输原语 mock
HAL.sys.spi_setup = function() return 0 end
HAL.sys.spi_xfer = function() return 0 end

local hfd = spi_open("/dev/spidev0.0")
check("HAL：spi_open 成功", hfd == 3, tostring(hfd))

local hal = {}
hal.setup_int   = spi_setup(hfd, 3, 8, 1000000) == 0		-- 合法整数
hal.setup_mode  = spi_setup(hfd, 1.9, 8, 1000000) == 0		-- mode 小数
hal.setup_bits  = spi_setup(hfd, 1, 8.5, 1000000) == 0		-- bits 小数
hal.setup_speed = spi_setup(hfd, 1, 8, 999.5) == 0		-- speed 小数
hal.write_int   = spi_write(hfd, 0x5A) == 0			-- 合法整数
hal.write_frac  = spi_write(hfd, 1.9) == 0			-- 小数
hal.write3_ok   = spi_write3(hfd, 0x11, 0x22, 0x33) == 0
hal.write3_frac = spi_write3(hfd, 0x11, 0x22, 0.5) == 0
hal.xfer_ok     = spi_xfer_full(hfd, { 0x30, 0x03, 0x00 }) ~= nil
hal.xfer_frac   = spi_xfer_full(hfd, { 0x30, 0x03, 0.5 }) ~= nil

-- ==================== 仿真路径：virtbus 注入（proto=virt） ====================
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()
vbus.attach_spi("spi-int-dev", "/dev/spidev0.0", {})	-- 缺省 xfer 返回等长全 0
vbus.inject()
local vfd = spi_open("/dev/spidev0.0")
check("virtbus：spi_open 成功", vfd == 3, tostring(vfd))

local vir = {}
vir.setup_int   = spi_setup(vfd, 3, 8, 1000000) == 0
vir.setup_mode  = spi_setup(vfd, 1.9, 8, 1000000) == 0
vir.setup_bits  = spi_setup(vfd, 1, 8.5, 1000000) == 0
vir.setup_speed = spi_setup(vfd, 1, 8, 999.5) == 0
vir.write_int   = spi_write(vfd, 0x5A) == 0
vir.write_frac  = spi_write(vfd, 1.9) == 0
vir.write3_ok   = spi_write3(vfd, 0x11, 0x22, 0x33) == 0
vir.write3_frac = spi_write3(vfd, 0x11, 0x22, 0.5) == 0
vir.xfer_ok     = spi_xfer_full(vfd, { 0x30, 0x03, 0x00 }) ~= nil
vir.xfer_frac   = spi_xfer_full(vfd, { 0x30, 0x03, 0.5 }) ~= nil
vbus.reset()

-- ==================== 两路径对偶断言 ====================
local cases = {
	{ "spi_setup 合法整数接受", "setup_int",   true },
	{ "spi_setup mode 小数拒绝", "setup_mode",  false },
	{ "spi_setup bits 小数拒绝", "setup_bits",  false },
	{ "spi_setup speed 小数拒绝", "setup_speed", false },
	{ "spi_write 合法整数接受", "write_int",   true },
	{ "spi_write 小数拒绝", "write_frac",  false },
	{ "spi_write3 合法整数接受", "write3_ok",   true },
	{ "spi_write3 含小数拒绝", "write3_frac", false },
	{ "spi_xfer_full 合法整数接受", "xfer_ok",    true },
	{ "spi_xfer_full 含小数拒绝", "xfer_frac",  false },
}
for _, c in ipairs(cases) do
	local label, key, want = c[1], c[2], c[3]
	check("HAL：" .. label, hal[key] == want)
	check("virtbus：" .. label, vir[key] == want)
	check("两路径结论一致（" .. label .. "）", hal[key] == vir[key],
		"HAL=" .. tostring(hal[key]) .. " virt=" .. tostring(vir[key]))
end

tester.summary("test_spi_int")
return 0
