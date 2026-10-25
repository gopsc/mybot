-- test_virtbus.lua - 虚拟 I2C 总线回归（issue #18：虚拟硬件用于无真机测试）
-- 验证 modules/lib/virtbus.lua 的契约：
--   1) attach 器件模型 + inject 后，全局 i2c_* 被替换，驱动链路走虚拟总线；
--   2) 写族（write_reg/write_multi/write_reg16）字节表正确送达 dev.write；
--   3) 指针式读族（read_reg/read_multi/read_multi_bytes/read_reg16）先向模型
--      发寄存器指针再读（对齐 HAL I2C_RDWR），纯读族（read/read_bytes）不发指针；
--      返回值按 HAL 语义组装（大端合并或字节表），数据来自 dev.read；
--   4) 无器件地址命中 = NACK（写 -1、读 -1/nil），负路径可测；
--   5) txlog 记录每次事务（方向/地址/内容），用于行为序列断言；
--   6) restore/reset 正确还原全局函数（不影响后续测试）。
-- 用法（项目根目录）: lua5.4 test/test_virtbus.lua（run_all.sh 自动纳入；纯 Lua）
local tester = dofile("test/lib/tester.lua")
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- ==================== 1) 注入与基本读写 ====================
local last_write, last_read_n
local fake_dev = {
	write = function(bytes) last_write = bytes end,
	read = function(n) last_read_n = n; return { 0x12, 0x34 } end,
}
vbus.attach("fake@0x23", 0x23, fake_dev)
vbus.inject()
tester.check("inject 幂等", vbus._injected == true)

local fd = i2c_open("/dev/i2c-1")
tester.check("i2c_open 返回虚拟 fd", fd == 3)
tester.check("i2c_open 非法路径返回 -1", i2c_open("/dev/fake") == -1)
tester.check("i2c_set_addr 绑定", i2c_set_addr(fd, 0x23) == true)
tester.check("i2c_set_addr 未打开 fd 拒绝", i2c_set_addr(999, 0x23) == false)

tester.check("write_reg 返回 true（HAL 布尔契约）", i2c_write_reg(fd, 0x01, 0xAB) == true)
tester.check("write_reg 送达 {reg,val}", #last_write == 2 and last_write[1] == 0x01 and last_write[2] == 0xAB)

tester.check("write_multi 返回 0 且字节序正确",
	i2c_write_multi(fd, 0x10, 0x11, 0x12) == 0 and
	#last_write == 3 and last_write[1] == 0x10 and last_write[2] == 0x11 and last_write[3] == 0x12)

tester.check("write_reg16 返回 0 且大端指针",
	i2c_write_reg16(fd, 0x0102, 0xAA) == 0 and
	#last_write == 3 and last_write[1] == 0x01 and last_write[2] == 0x02 and last_write[3] == 0xAA)

-- ==================== 2) 读族语义 ====================
fake_dev.read = function(n) last_read_n = n; return { 0x12, 0x34 } end
tester.check("read_reg 返回单字节", i2c_read_reg(fd, 0x40) == 0x12)
tester.check("read_reg 读前先送 8 位指针 0x40",
	#last_write == 1 and last_write[1] == 0x40)
tester.check("read_multi 大端合并", i2c_read_multi(fd, 0x00, 2) == 0x1234)
tester.check("read_multi 读前送指针 0x00",
	#last_write == 1 and last_write[1] == 0x00)
tester.check("read 大端合并（纯读）", i2c_read(fd, 2) == 0x1234)
local tb = i2c_read_multi_bytes(fd, 0x00, 2)
tester.check("read_multi_bytes 返回字节表", tb ~= nil and #tb == 2 and tb[1] == 0x12 and tb[2] == 0x34)
local before_pure = #vbus.txlog
local rb = i2c_read_bytes(fd, 2)
tester.check("read_bytes 返回字节表", rb ~= nil)
tester.check("read_bytes 纯读只产生一笔读事务（无指针写）",
	#vbus.txlog == before_pure + 1 and vbus.txlog[#vbus.txlog].dir == "r")
tester.check("read_reg16 大端合并", i2c_read_reg16(fd, 0x0102, 2) == 0x1234)
tester.check("read_reg16 读前送 16 位大端指针",
	#last_write == 2 and last_write[1] == 0x01 and last_write[2] == 0x02)
tester.check("器件 read 收到请求长度", last_read_n == 2)

-- 长度约束对齐 HAL：合并值类越界显式失败，字节表类钳到 1~16
tester.check("read n=9 越界显式 -1（HAL 上限 8）", i2c_read(fd, 9) == -1)
tester.check("read n=0 非法显式 -1", i2c_read(fd, 0) == -1)
tester.check("read_multi n=7 越界显式 -1（HAL 上限 6）", i2c_read_multi(fd, 0x00, 7) == -1)
tester.check("read_reg16 n=7 越界显式 -1", i2c_read_reg16(fd, 0x0102, 7) == -1)
i2c_read_bytes(fd, 20)
tester.check("read_bytes n=20 钳到 16 下发模型", last_read_n == 16)
i2c_read_multi_bytes(fd, 0x00, 20)
tester.check("read_multi_bytes n=20 钳到 16（指针写后按 16 读）", last_read_n == 16)

-- ==================== 2.5) 模型主动 NACK（故障注入契约） ====================
fake_dev.write = function() return false end
fake_dev.read = function() return nil end
tester.check("模型 write 返回 false 时 write_reg 按 NACK (false)", i2c_write_reg(fd, 0x01, 0xAB) == false)
tester.check("模型 write 返回 false 时 write_multi 按 NACK (-1)", i2c_write_multi(fd, 0x01, 0xAB) == -1)
tester.check("模型 read 返回 nil 时纯读按 NACK", i2c_read(fd, 2) == -1)
tester.check("指针写被模型 NACK 时整笔读失败", i2c_read_reg(fd, 0x40) == -1)
tester.check("指针 NACK 后不产生读事务", vbus.txlog[#vbus.txlog].dir == "w")
fake_dev.write = function(bytes) last_write = bytes end
fake_dev.read = function(n) last_read_n = n; return { 0x12, 0x34 } end

-- ==================== 3) NACK 负路径（无器件地址） ====================
local fd2 = i2c_open("/dev/i2c-2")
i2c_set_addr(fd2, 0x50)
tester.check("无器件 write_reg 返回 false (NACK)", i2c_write_reg(fd2, 1, 2) == false)
tester.check("无器件 write_multi 返回 -1 (NACK)", i2c_write_multi(fd2, 1, 2) == -1)
tester.check("无器件读返回 -1", i2c_read_reg(fd2, 1) == -1)
tester.check("无器件 read_multi_bytes 返回 nil", i2c_read_multi_bytes(fd2, 1, 2) == nil)
tester.check("无器件 read_bytes 返回 nil", i2c_read_bytes(fd2, 2) == nil)

-- ==================== 4) txlog 事务序列 ====================
local seq = {}
for _, e in ipairs(vbus.txlog) do
	if e.dir == "open" then seq[#seq + 1] = "open" elseif e.dir == "set" then
		seq[#seq + 1] = "set" elseif e.dir == "w" then
		seq[#seq + 1] = "w" else seq[#seq + 1] = "r" end
end
tester.check("txlog 首个事务为 open", seq[1] == "open")
tester.check("txlog 含 set", seq[2] == "set")
tester.check("txlog 写读交替记录有序", seq[3] == "w")
local wr = vbus.txlog[3]
tester.check("txlog 写事务内容", wr.bytes[1] == 0x01 and wr.bytes[2] == 0xAB and wr.addr == 0x23)

-- ==================== 5) close 与 restore ====================
i2c_close(fd)
i2c_close(fd2)
vbus.restore()
tester.check("restore 后 i2c_open 为空", i2c_open == nil)
vbus.inject()
vbus.reset()
tester.check("reset 清空日志", #vbus.txlog == 0)
tester.check("reset 还原全局 i2c_open", i2c_open == nil)

tester.summary("test_virtbus")
return 0