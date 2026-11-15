-- test_sgp30_host_state.lua —— SGP30 baseline 的宿主 state 文件分支
--
-- 独立 luajit 测试用 HAL.sys mock 覆盖了 fallback 路径；本用例在加载驱动前
-- 注入 state_read/state_write 全局，强制 SGP30 走宿主分支，验证：
--   * build 从 state 读 6 字节基线并下发 Set_baseline；
--   * destroy 通过 Get_baseline 取回基线并 state_write 落盘；
--   * 落盘内容与恢复内容逐字节一致。
-- 真实 C++ 文件落盘/路径拒绝由 test/cpp/test_hal_state.cpp 覆盖。
-- 用法（项目根目录）: luajit test/test_sgp30_host_state.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 必须在 dofile SGP30.lua 之前注入：SGP30 在加载期决定 HOST_STATE。
local files = {}
local reads, writes = 0, 0
function state_read(name)
	reads = reads + 1
	local data = files[name]
	if data == nil then return nil end
	local out = {}
	for i = 1, #data do out[i] = data:byte(i) end
	return out
end
function state_write(name, data)
	writes = writes + 1
	local out = {}
	for i = 1, #data do out[i] = string.char(data[i]) end
	files[name] = table.concat(out)
	return 0
end

local BASELINE = "sgp30-baseline.bin"
-- 两字 0x1234 / 0x5678 + Sensirion CRC-8（poly 0x31、init 0xFF）
files[BASELINE] = string.char(0x12, 0x34, 0x37, 0x56, 0x78, 0x7D)

vbus.load_driver("modules/SGP30.lua")
local dev = SGP30_VIRT.new()
vbus.attach("SGP30@0x58", 0x58, dev)

local sleep_total = 0
function milli_sleep(ms)
	sleep_total = sleep_total + ms
	dev:advance(ms)
end

local fd = i2c_open("/dev/i2c-1")
check("i2c_open 虚拟 fd", fd == 3, tostring(fd))

local built = build({ fd = fd, address = "0x58", baseline = BASELINE })
check("build 成功", type(built) == "table" and built.result == "OK")
check("build 经 state 读取基线段", reads >= 1, tostring(reads))
local w1, w2 = dev:baseline()
check("Set_baseline 恢复两字", w1 == 0x1234 and w2 == 0x5678,
	string.format("%04X/%04X", w1 or -1, w2 or -1))

local destroyed = destroy({ fd = fd, address = "0x58" })
check("destroy 成功", type(destroyed) == "table" and destroyed.result == "OK")
check("destroy 经 state 写回基线段", writes == 1, tostring(writes))
check("state 文件仍为 6 字节", #files[BASELINE] == 6, tostring(#files[BASELINE]))
check("state 文件内容与恢复值一致",
	files[BASELINE] == string.char(0x12, 0x34, 0x37, 0x56, 0x78, 0x7D))

tester.summary("SGP30 host state")
