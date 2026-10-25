-- test_virtbus_regmap.lua - 通用寄存器组虚拟器件模型回归
-- 验证 modules/lib/virtbus/regmap.lua：
--   1) 直接驱动模型（不经总线）：指针写/寄存器写/burst 自增/16 位补码/回绕；
--   2) 挂到 virtbus 后经全局 i2c_* 访问：i2c_write_reg + i2c_read_reg /
--      i2c_read_multi_bytes 的「写指针 + burst 读」链路（MPU6050 类器件的前置验证）；
--   3) ptr16 模式（VL53Lx 类 16 位指针器件）；
--   4) nack 故障注入、reset 复位。
-- 纯 Lua（不依赖 ffi；virtbus 与 regmap 均无 ffi 依赖），lua5.4/luajit 均可跑。
-- 用法（项目根目录）: luajit test/test_virtbus_regmap.lua（run_all.sh 自动纳入）
local tester = dofile("test/lib/tester.lua")
local check = tester.check
local regmap = dofile("modules/lib/virtbus/regmap.lua")

-- ==================== 1) 直接驱动模型：8 位指针器件 ====================
local dev = regmap.new({ [0x75] = 0x68, [0x10] = 0x5A })

-- 单字节写 = 设置读指针；随后 read burst 从该地址起、指针自增
check("write{reg} 设指针返回成功", dev.write({ 0x75 }) == true)
local t = dev.read(1)
check("read(1) 从指针取 0x68", #t == 1 and t[1] == 0x68)
check("读后指针自增到 0x76", dev.ptr == 0x76)

dev:set_word(0x3B, 0x1234)
dev.write({ 0x3B })
t = dev.read(3)
check("burst 读 3 字节连续且自增", t[1] == 0x12 and t[2] == 0x34 and t[3] == 0 and dev.ptr == 0x3E)
check("get_word 大端合回 0x1234", dev:get_word(0x3B) == 0x1234)

-- 负数按 16 位补码写入（驱动侧的符号扩展在驱动里，模型只复现字节事实）
dev:set_word(0x3B, -1)
check("set_word(-1) 写补码 0xFFFF", dev:get(0x3B) == 0xFF and dev:get(0x3C) == 0xFF)
check("get_sword 解释回 -1", dev:get_sword(0x3B) == -1)
dev:set_word(0x3B, -32768)
check("set_word(-32768) → 0x8000", dev:get_sword(0x3B) == -32768)

-- 多字节写 = 连续寄存器写
check("write{reg,v...} 连续写", dev.write({ 0x40, 0xA1, 0xB2 }) == true)
check("连续写第 1 字节", dev:get(0x40) == 0xA1)
check("连续写第 2 字节", dev:get(0x41) == 0xB2)

-- 未预置寄存器读 0；burst 越过 0xFF 回绕到 0x00
dev.write({ 0xFF })
t = dev.read(2)
check("burst 跨 256 边界回绕（0xFF,0x00 均读 0）", t[1] == 0 and t[2] == 0 and dev.ptr == 0x01)

-- 写事务留痕（副本，改原表不影响日志）
dev.write({ 0x10, 0x01 })
local logged = dev.write_log[#dev.write_log]
check("write_log 记录事务", logged[1] == 0x10 and logged[2] == 0x01)

-- 非法事务
check("空/非表写拒绝 (false)", dev.write({}) == false and dev.write("x") == false)

-- ==================== 2) nack 故障注入与 reset ====================
dev.nack = true
check("nack 时写返回 false", dev.write({ 0x10, 0x01 }) == false)
check("nack 时读返回 nil", dev.read(2) == nil)
dev.nack = false
-- 定向故障：只写 NACK（读仍正常）/ 只读 NACK（写仍正常）
dev.nack_write = true
check("nack_write 时写 false", dev.write({ 0x10, 0x01 }) == false)
check("nack_write 不影响读", dev.read(1) ~= nil)
dev.nack_write = false
dev.nack_read = true
check("nack_read 时读 nil", dev.read(1) == nil)
check("nack_read 不影响写", dev.write({ 0x10, 0x01 }) == true)
dev:reset({ [0x75] = 0x68 })
check("reset 后故障清除、指针归零",
	dev.nack == false and dev.nack_read == false and dev.nack_write == false
	and dev.ptr == 0 and dev:get(0x75) == 0x68)
check("reset 清空旧寄存器", dev:get(0x10) == nil)

-- ==================== 3) 挂到 virtbus 经全局 i2c_* 访问 ====================
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()
local imu = regmap.new({ [0x75] = 0x68 })
imu:set_word(0x3B, -1234)
vbus.attach("regmap-dev@0x68", 0x68, imu)
vbus.inject()

local fd = i2c_open("/dev/i2c-1")
check("总线层 set_addr", i2c_set_addr(fd, 0x68) == true)
check("i2c_write_reg 成功（布尔 true）", i2c_write_reg(fd, 0x6B, 0x00) == true)
check("写寄存器落到模型（0x6B=0x00）", imu:get(0x6B) == 0x00)

check("i2c_read_reg 读到 WHO_AM_I=0x68", i2c_read_reg(fd, 0x75) == 0x68)

-- 0x3B 起 6 字节 burst：-1234 补码 + 后续 0
local burst = i2c_read_multi_bytes(fd, 0x3B, 6)
local function sword(b, i)
	local u = b[i] * 256 + b[i + 1]
	if u >= 32768 then u = u - 65536 end
	return u
end
check("burst 6 字节且首字补码为 -1234",
	burst ~= nil and #burst == 6 and sword(burst, 1) == -1234
	and burst[3] == 0 and burst[6] == 0)

-- 大端合并路径（be_merge 为无符号值，与 get_word 一致；符号解释在驱动侧）
check("i2c_read_multi 大端合并 2 字节", i2c_read_multi(fd, 0x3B, 2) == imu:get_word(0x3B))

-- 总线视角的 NACK
imu.nack = true
check("模型 NACK 传导到 write_reg (false)", i2c_write_reg(fd, 0x01, 0x02) == false)
check("模型 NACK 传导到指针读", i2c_read_reg(fd, 0x75) == -1)
imu.nack = false
imu.nack_read = true
check("nack_read：write_reg 仍成功 (true)", i2c_write_reg(fd, 0x01, 0x02) == true)
check("nack_read：读失败 -1", i2c_read_reg(fd, 0x75) == -1)
imu:reset({ [0x75] = 0x68 })
check("撤销 NACK 恢复", i2c_read_reg(fd, 0x75) == 0x68)
i2c_close(fd)
vbus.restore()

-- ==================== 4) 16 位指针器件（ptr16） ====================
local tof = regmap.new({}, { ptr16 = true })
tof:set_word(0x0087, 0x0001)
check("ptr16 两字节写设指针", tof.write({ 0x00, 0x87 }) == true and tof.ptr == 0x0087)
t = tof.read(2)
check("ptr16 burst 读结果", t[1] == 0x00 and t[2] == 0x01 and tof.ptr == 0x0089)
check("ptr16 三字节写为寄存器写", tof.write({ 0x00, 0x87, 0x03 }) == true)
check("ptr16 写入落到 0x0087", tof:get(0x0087) == 0x03)

tester.summary("test_virtbus_regmap")
return 0
