-- test_max30102.lua —— MAX30102 真实驱动 + 虚拟 I2C 总线 + 环形 FIFO 模型
-- 用法（项目根目录）: luajit test/test_max30102.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 354 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MAX30102.lua 尾部 MAX30102_VIRT，
-- 2026-09-15 自 virtbus/max30102.lua 迁入）」。本器件是 virtbus 库【首个
-- 「环形 FIFO + 读写指针/溢出计数 + rollover + 18 位样本块读」I2C 器件】
-- （Maxim MAX30102 PPG 传感器，地址固定 0x57）：
--   寄存器是普通 8 位指针，核心在 FIFO 状态机——WR 0x04/OVF 0x05/RD 0x06
--   三个 5 位指针 + 32 深环形槽；FIFO_DATA 0x07 流式读，HR 模式 3 字节/样本、
--   SpO2 模式 6 字节/样本；每通道 18 位 MSB 对齐在 3 字节帧（帧=sample<<6，
--   低 6 位恒 0，满码 0x3FFFF 即 SAT）；FIFO_CFG.ROLLOVER 位决定满后覆盖
--   最旧（RD 自动跟进、OVF 不增）还是丢新（OVF++ 饱和 31、WR 停住）；
--   MODE.RESET 位回 POR、SHDN 位停采；有效输出周期 = 1000×2^SMP_AVE/SR ms。
--
-- 迁移戳破的旧桩假绿：旧桩用 Lua 无限数组 + pushed/popped 计数器建模，
-- push 40（超过 32 深）后给出 avail=8、能读到第 9 个样本——真实硬件 5 位
-- 指针下 rollover 每覆盖一个最旧样本就把 RD 推进一步，push 40 后 WR=RD=8、
-- (WR-RD)%32=0，驱动纯轮询看到的就是 FIFO empty（驱动注释自承「轮询周期
-- 远大于样本周期时指针差回绕、avail 被低估」）。本测试按真实环形语义断言。
--
-- 覆盖：模型侧 POR/普通寄存器与三指针可写/18 位三字节编解码交叉/流式口
-- 跨样本与半样本事务/空读 0/HR 3B/rollover 覆盖推 RD 与关闭丢新 OVF 饱和/
-- RESET 回 POR 自清且保留身份与钩子/SHDN 启停/周期门 9.9vs10.1 边界/
-- queue 注入优先正弦/never_sample/avg·rate 周期/virt_tick 峰谷/坏帧/谓词
-- 钩子；真实 build 9 写序列与配置编码（0x08/0x24/LED 0x20）、reset 5ms
-- 睡眠、LED 继承/舍入/钳制、甄别/RESET/配置写失败与参数负路径；真实 call
-- 指针+数据读事务形态、n 排空 FIFO 序、别名/SAT、wait 10ms 步进轮询、
-- wait 耗尽、rollover empty、周期样本、指针/数据读失败、virt_tick 零睡眠
-- 闭环；destroy SHDN 写与缺 fd/非表负路径。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x57

-- 模型内嵌于驱动文件（MAX30102_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MAX30102.lua")
local smod = MAX30102_VIRT

local dev = smod.new()

local dev = smod.new()
vbus.attach("MAX30102@0x57", ADDR, dev)

-- milli_sleep：累计时长 + 推进采样虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))
check("i2c_set_addr 0x57", i2c_set_addr(fd, ADDR) == true)

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用，保留 build 出来的活动状态）
local function window()
	return #vbus.txlog
end

local function entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do t[#t + 1] = vbus.txlog[i] end
	return t
end
local function writes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "w" then t[#t + 1] = e.bytes end
	end
	return t
end
-- 窗口内 2B 寄存器写 {reg,val}
local function reg_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 2 then t[#t + 1] = { b[1], b[2] } end
	end
	return t
end
-- 窗口内 1B 指针写序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
-- 窗口内读事务返回长度序列
local function read_sizes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "r" then t[#t + 1] = e.bytes.n end
	end
	return t
end
local function set_addrs(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "set" then t[#t + 1] = e.addr end
	end
	return t
end
local function n2b(mark) return #reg_writes(mark) end
local function n1b(mark) return #ptr_writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

-- HAL 快捷
local function regb(r) return i2c_read_reg(fd, r) end
local function regw(r, v) return i2c_write_reg(fd, r, v) end
local function fifo_bytes(n) return i2c_read_multi_bytes(fd, 0x07, n) end

-- 18 位样本 -> 3 字节（独立于驱动解码的 floor/% 公式）
local function enc(s)
	return math.floor(s / 1024) % 256, math.floor(s / 4) % 256, (s % 4) * 64
end
local function build_ok(opts)
	opts = opts or {}
	opts.fd, opts.address = fd, "0x57"
	local r = build(opts)
	check("build OK", r.result == "OK", tostring(r.message))
	return r
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点 API / 经 HAL）
-- =====================================================================
local mark = section()

-- ---- POR 种子 ----
check("POR PART_ID=0x15", dev:part_id() == 0x15, string.format("0x%02X", dev:part_id()))
check("POR FIFO_CFG=0x00（rollover 关）", dev:reg(0x08) == 0x00, string.format("0x%02X", dev:reg(0x08)))
check("POR MODE=0x00", dev:reg(0x09) == 0x00)
check("POR SPO2=0x00", dev:reg(0x0A) == 0x00)
check("POR LED1/LED2=0", dev:reg(0x0C) == 0 and dev:reg(0x0D) == 0)
check("POR 三指针全 0", dev:wr_ptr() == 0 and dev:rd_ptr() == 0 and dev:ovf_counter() == 0)
check("POR FIFO 空", dev:avail() == 0 and dev:occupied() == 0)
check("POR 未采样", not dev:is_active() and dev:mode() == 0 and not dev:shdn())
check("POR period=nil/remaining=nil", dev:period_ms() == nil and dev:remaining_ms() == nil)
check("POR 计数为 0", dev:reset_count() == 0 and dev:produced() == 0)
check("POR PART_ID 经总线读 0x15", regb(0xFF) == 0x15)
check("POR 普通寄存器缺省读 0", regb(0x0B) == 0 and regb(0x10) == 0)

-- ---- 三指针寄存器可写（5 位） ----
mark = section()
check("写 WR=7 同步", regw(0x04, 7) and dev:wr_ptr() == 7, tostring(dev:wr_ptr()))
check("写 OVF=3 同步", regw(0x05, 3) and dev:ovf_counter() == 3, tostring(dev:ovf_counter()))
check("写 RD=5 同步", regw(0x06, 5) and dev:rd_ptr() == 5, tostring(dev:rd_ptr()))
check("写指针取模 32（0x24->4）", regw(0x06, 0x24) and dev:rd_ptr() == 4, tostring(dev:rd_ptr()))

-- ---- 18 位三字节编码交叉（SpO2 6 字节） ----
mark = section()
regw(0x09, 0x03)					-- 进 SpO2 模式（FIFO 仍空）
local enc_cases = {
	{ 0,     0     }, { 1,     3     }, { 262143, 262142 },
	{ 100000, 50000 }, { 131072, 65535 }, { 1023, 4 },
}
for _, c in ipairs(enc_cases) do
	dev:clear_fifo()
	dev:push_sample(c[1], c[2])
	local b = fifo_bytes(6)
	local e0, e1, e2 = enc(c[1])
	local e3, e4, e5 = enc(c[2])
	check(string.format("编码 RED=%d IR=%d", c[1], c[2]),
		b[1] == e0 and b[2] == e1 and b[3] == e2 and b[4] == e3 and b[5] == e4 and b[6] == e5,
		string.format("%d,%d,%d,%d,%d,%d", b[1], b[2], b[3], b[4], b[5], b[6]))
end

-- 读满样本 RD 自增、槽位释放
dev:clear_fifo()
dev:push_sample(111, 222)
fifo_bytes(6)
check("读满 6B 后 RD=1/avail=0", dev:rd_ptr() == 1 and dev:avail() == 0 and dev:occupied() == 0,
      string.format("rd=%d avail=%d occ=%d", dev:rd_ptr(), dev:avail(), dev:occupied()))

-- 空 FIFO 读数据口全 0、RD 不动
dev:clear_fifo()
local b0 = fifo_bytes(6)
check("空读 FIFO_DATA 全 0", b0[1] == 0 and b0[6] == 0 and dev:rd_ptr() == 0)

-- 跨样本长读：12B 一次消费两个样本（用大值让每字节都有区分度）
dev:push_samples({ { red = 100000, ir = 50000 }, { red = 200000, ir = 262143 } })
local b12 = fifo_bytes(12)
check("12B 跨两样本", b12[1] == enc(100000) and b12[4] == enc(50000) and
      b12[7] == enc(200000) and b12[10] == enc(262143) and b12[12] == 192 and
      dev:rd_ptr() == 2 and dev:occupied() == 0,
      string.format("b1=%d b4=%d b7=%d b10=%d rd=%d",
      b12[1], b12[4], b12[7], b12[10], dev:rd_ptr()))

-- 半样本事务：2B 不推进 RD，重新寻址重读同一槽
dev:clear_fifo()
dev:push_sample(262143, 262143)
local bh = fifo_bytes(2)
check("半样本 2B 取前两字节且 RD 不推进", bh[1] == 255 and bh[2] == 255 and
      dev:rd_ptr() == 0 and dev:occupied() == 1)
local bf = fifo_bytes(6)
check("重新寻址 6B 重读同一槽", bf[1] == 255 and bf[3] == 192 and dev:rd_ptr() == 1)

-- ---- HR 模式 3 字节/样本、无 IR ----
mark = section()
regw(0x09, 0x02)
check("HR 模式 sample_size=3", not dev:spo2_mode() and dev:mode() == 2)
dev:push_sample(12345, 99999)		-- ir 在 HR 模式被忽略
local bh3 = fifo_bytes(3)
local h0, h1, h2 = enc(12345)
check("HR 3B 编码仅 RED", bh3[1] == h0 and bh3[2] == h1 and bh3[3] == h2 and dev:rd_ptr() == 1)
-- HR 下连读 6B = 两个 RED 样本（不是 RED+IR）
dev:push_samples({ { red = 200000 }, { red = 100000 } })
local bh6 = fifo_bytes(6)
check("HR 连读 6B 跨两个 RED 样本", bh6[1] == enc(200000) and bh6[4] == enc(100000) and
      dev:rd_ptr() == 3,
      string.format("b1=%d b4=%d rd=%d", bh6[1], bh6[4], dev:rd_ptr()))

-- ---- rollover：覆盖最旧 + RD 自动跟进（32 深环形） ----
mark = section()
regw(0x08, 0x10)					-- rollover 开（B4；SMP_AVE=0）
regw(0x09, 0x03)
for i = 1, 32 do dev:push_sample(9000 + i, 0) end
check("满 32：WR=RD=0、occupied=32、ovf=0",
      dev:wr_ptr() == 0 and dev:rd_ptr() == 0 and dev:occupied() == 32 and dev:ovf_counter() == 0)
dev:push_sample(9033, 0)			-- 第 33：覆盖 slot0
check("第 33 push：WR=RD=1、slot0 已换",
      dev:wr_ptr() == 1 and dev:rd_ptr() == 1 and dev:occupied() == 32 and dev:ovf_counter() == 0,
      string.format("wr=%d rd=%d slot0=%d", dev:wr_ptr(), dev:rd_ptr(), select(1, dev:slot(0))))
for i = 34, 40 do dev:push_sample(9000 + i, 0) end
check("push 40：WR=RD=8、avail=0（驱动公式低估）",
      dev:wr_ptr() == 8 and dev:rd_ptr() == 8 and dev:avail() == 0 and dev:occupied() == 32)
check("slot7=最新样本 9040", select(1, dev:slot(7)) == 9040, tostring(select(1, dev:slot(7))))
check("slot8=最旧未覆盖 9009", select(1, dev:slot(8)) == 9009, tostring(select(1, dev:slot(8))))

-- ---- rollover 关闭：满后丢新、OVF++ 饱和 31、WR 停住 ----
mark = section()
regw(0x09, 0x03)
regw(0x08, 0x00)
dev:clear_fifo()
for i = 1, 32 do dev:push_sample(100 + i, 0) end
check("关 rollover 满 32：WR=0 停住", dev:wr_ptr() == 0 and dev:occupied() == 32)
for i = 1, 2 do dev:push_sample(700 + i, 0) end
check("再 push 2：丢新、OVF=2、旧槽保留",
      dev:ovf_counter() == 2 and dev:wr_ptr() == 0 and
      select(1, dev:slot(0)) == 101 and select(1, dev:slot(31)) == 132,
      string.format("ovf=%d slot0=%s", dev:ovf_counter(), tostring(select(1, dev:slot(0)))))
for i = 1, 60 do dev:push_sample(800, 0) end
check("OVF 饱和在 31", dev:ovf_counter() == 31, tostring(dev:ovf_counter()))

-- ---- RESET / SHDN ----
mark = section()
dev:push_sample(1, 2)
regw(0x0C, 0x55)
regw(0x09, 0x40)					-- RESET
check("RESET 后计数=1", dev:reset_count() == 1)
check("RESET 后寄存器回 POR", dev:reg(0x08) == 0x00 and dev:reg(0x09) == 0x00 and
      dev:reg(0x0C) == 0x00, string.format("0C=%02X", dev:reg(0x0C)))
check("RESET 位读回 0（自清除不落盘）", regb(0x09) == 0x00)
check("RESET 清空 FIFO/指针", dev:occupied() == 0 and dev:wr_ptr() == 0 and dev:rd_ptr() == 0)
check("RESET 保留身份注入", dev:part_id() == 0x15)
dev:set_part_id(0x16)
regw(0x09, 0x40)
check("身份注入跨 RESET 保留（错挂模拟）", regb(0xFF) == 0x16)
-- SHDN 启停（先写 SPO2 配置让周期=rate100 的 10ms）
regw(0x0A, 0x24)
regw(0x09, 0x03)
check("写 SpO2 模式启动", dev:is_active() and dev:remaining_ms() == 10,
      tostring(dev:remaining_ms()))
regw(0x09, 0x80)
check("SHDN 停采（位读回）", dev:shdn() and not dev:is_active() and dev:remaining_ms() == nil and
      regb(0x09) == 0x80)
regw(0x09, 0x03)
check("再写模式恢复采样", dev:is_active() and dev:remaining_ms() == 10)

-- ---- 自动采样周期门 ----
mark = section()
regw(0x08, 0x10)					-- rollover 开（B4）、SMP_AVE=0
regw(0x0A, 0x24)					-- rate=100/adc4096/pw69
regw(0x09, 0x03)					-- rate=100/avg=1 -> 10ms/样本
check("默认周期 10ms", dev:period_ms() == 10, tostring(dev:period_ms()))
dev:advance(9.9)
check("advance 9.9ms 无样本", dev:avail() == 0 and dev:produced() == 0)
dev:advance(0.2)
check("advance 10.1ms 出 1 个", dev:avail() == 1 and dev:produced() == 1,
      string.format("avail=%d produced=%d", dev:avail(), dev:produced()))
dev:clear_fifo()
dev:advance(30)
check("再推 30ms 共 4 个（10/20/30/40 完成点）", dev:avail() == 3 and dev:produced() == 4,
      string.format("avail=%d produced=%d", dev:avail(), dev:produced()))
-- queue 注入优先于正弦
mark = section()
regw(0x0A, 0x24)
regw(0x09, 0x03)
dev:queue_sample(777, 888)
dev:advance(10)
check("queue 注入样本优先", select(1, dev:slot(0)) == 777 and select(2, dev:slot(0)) == 888)
-- never_sample：advance 完全不推
mark = section()
regw(0x0A, 0x24)
regw(0x09, 0x03)
dev:set_never_sample(true)
dev:advance(30)
check("never_sample：advance 不产、remaining 不变", dev:avail() == 0 and
      dev:remaining_ms() == 10)
-- SHDN 期 advance 不产
dev:set_never_sample(false)
regw(0x09, 0x80)
dev:advance(30)
check("SHDN 期 advance 不产", dev:avail() == 0)
-- HR 模式自动产出仅 RED 槽
mark = section()
regw(0x0A, 0x24)
regw(0x09, 0x02)
dev:advance(10)
local hrr, hri = dev:slot(0)
check("HR 自动产出有 RED 无 IR", hrr == 50000 and hri == nil, tostring(hrr) .. "/" .. tostring(hri))
-- avg/rate 组合周期
mark = section()
-- C5（2026-09-20 审计）：SMP_AVE 在 B7..B5、ROLLOVER_EN 在 B4 —— avg=16 是
-- code 4，写入值为 4<<5 | 0x10 = 0x90（旧值 0x48 是错位编码：芯片会读成
-- SMP_AVE=2、rollover 关）。这里直接用新布局构造，模型与驱动同判据。
regw(0x08, 4 * 32 + 0x10)		-- avg=16(code4)+rollover
regw(0x0A, 5 * 4)				-- rate=1000(code5)
regw(0x09, 0x03)
check("avg=16/rate=1000 -> 16ms", dev:period_ms() == 16, tostring(dev:period_ms()))
check("FIFO_CFG 解出 avg_code=4 且 rollover 开", dev:avg_code() == 4 and dev:rollover_en(),
      tostring(dev:avg_code()) .. "/" .. tostring(dev:rollover_en()))
regw(0x08, 0x10)
regw(0x0A, 0x00)				-- rate=50
check("rate=50 -> 20ms", dev:period_ms() == 20, tostring(dev:period_ms()))

-- ---- virt_tick 确定性波形 ----
mark = section()
regw(0x08, 0x10)
regw(0x09, 0x03)
dev:virt_tick(0)
check("tick0：RED=50000/IR=60000", select(1, dev:slot(0)) == 50000 and
      select(2, dev:slot(0)) == 60000)
dev:clear_fifo()
dev:virt_tick(8)
check("tick8 峰：RED=68000/IR=82000", select(1, dev:slot(0)) == 68000 and
      select(2, dev:slot(0)) == 82000)
dev:clear_fifo()
dev:virt_tick(24)
check("tick24 谷：RED=32000/IR=38000", select(1, dev:slot(0)) == 32000 and
      select(2, dev:slot(0)) == 38000)
dev:clear_fifo()
dev:virt_tick(32)
check("tick32=tick0 周期", select(1, dev:slot(0)) == 50000)
-- tick 满后 rollover 覆盖
dev:clear_fifo()
for i = 0, 31 do dev:virt_tick(i) end
check("32 tick：满 occupied=32/WR=RD=0", dev:occupied() == 32 and dev:wr_ptr() == 0)
dev:virt_tick(32)
check("第 33 tick：rollover 推 RD=1", dev:rd_ptr() == 1 and dev:occupied() == 32)

-- ---- 坏帧 NACK ----
mark = section()
check("非 table 写 NACK", dev.write(0x55) == false)
check("0B 写 NACK", dev.write({}) == false)
check("3B 写 NACK", dev.write({ 1, 2, 3 }) == false)
check("无指针纯读 NACK", dev.read(1) == nil)
check("写 FIFO_DATA（只读口）ACK 忽略", dev.write({ 0x07, 0x12 }) == true and
      dev:occupied() == 0)

-- ---- 故障钩子 ----
mark = section()
dev.nack = true
check("nack：写失败/读失败", regw(0x0C, 1) == false and regb(0x0C) == -1)
dev.nack = false
dev.nack_write = true
check("nack_write：寄存器写失败", regw(0x0C, 1) == false)
dev.nack_write = false
check("nack_write 解除后原值仍为 0（失败写未落盘）", regb(0x0C) == 0)
dev.nack_read = true
check("nack_read：只影响读", regw(0x0C, 9) == true and regb(0x0C) == -1)
dev.nack_read = false
dev:fail_write(function(b) return b[1] == 0x0C end)
check("fail_write 谓词定向", regw(0x0C, 1) == false and regw(0x0D, 1) == true)
dev:fail_read(function(p, n) return p == 0x0A end)
check("fail_read 谓词定向", regb(0x0A) == -1 and regb(0x09) == 0)
dev:clear_faults()
check("clear_faults 解除", regw(0x0C, 2) == true and regb(0x0C) == 2)
-- RESET 保留故障钩子（谓词不命中 RESET 帧）
dev:fail_write(function(b) return b[1] == 0x0C end)
check("RESET 写本身成功", regw(0x09, 0x40) == true)
check("RESET 后钩子仍在（0x0C 仍被 NACK）", regw(0x0C, 1) == false)
dev:clear_faults()

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
mark = section()
build_ok()
check("build set_addr 恰 1 次", #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR)
check("build 9 笔 2B 寄存器写", n2b(mark) == 9, tostring(n2b(mark)))
check("build 1 笔 1B 指针（PART_ID）", n1b(mark) == 1 and ptr_writes(mark)[1] == 0xFF,
      table.concat(ptr_writes(mark), ","))
check("build 1 条读事务（PART_ID）", nrd(mark) == 1 and read_sizes(mark)[1] == 1)
local seq = reg_writes(mark)
local expected = {
	{ 0x09, 0x40 }, { 0x08, 0x18 }, { 0x0A, 0x24 }, { 0x0C, 0x20 }, { 0x0D, 0x20 },
	{ 0x04, 0x00 }, { 0x05, 0x00 }, { 0x06, 0x00 }, { 0x09, 0x03 },
}
local seq_ok = #seq == #expected
for i = 1, #expected do
	if seq_ok and (seq[i][1] ~= expected[i][1] or seq[i][2] ~= expected[i][2]) then seq_ok = false end
end
check("build 写序列 RESET->FIFO->SPO2->LED1->LED2->清3指针->MODE", seq_ok)
check("build RESET 实睡 5ms（桩转 advance，复位期不产样）", sleep_total == 5,
      tostring(sleep_total))
check("build 后模型：SpO2/active/rollover/周期10",
      dev:mode() == 3 and dev:is_active() and dev:rollover_en() and dev:period_ms() == 10)
check("build 后配置寄存器 08=0x18(rollover+A_FULL)/0A=0x24/LED=0x20",
      dev:reg(0x08) == 0x18 and dev:reg(0x0A) == 0x24 and
      dev:reg(0x0C) == 0x20 and dev:reg(0x0D) == 0x20)
check("build 后三指针 0/FIFO 空/RESET 计数 1",
      dev:wr_ptr() == 0 and dev:rd_ptr() == 0 and dev:occupied() == 0 and dev:reset_count() == 1)
check("build 后 remaining=10（新鲜采样周期，RESET 的 5ms 不耗它）",
      dev:remaining_ms() == 10, tostring(dev:remaining_ms()))

-- HR build 末写 MODE=0x02
mark = section()
build_ok({ opmode = "hr" })
seq = reg_writes(mark)
check("hr build 末写 0x09=0x02", seq[#seq][1] == 0x09 and seq[#seq][2] == 0x02,
      string.format("%02X=%02X", seq[#seq][1], seq[#seq][2]))
check("hr build 后 3 字节/样本", not dev:spo2_mode())

-- 组合配置编码
mark = section()
build_ok({ rate = "1000", pw = "118", adc = "8192", avg = "16" })
check("组合 SPO2=0x55（adc8192/rate1000/pw118）", dev:reg(0x0A) == 0x55,
      string.format("0x%02X", dev:reg(0x0A)))
-- C5 判别性断言（2026-09-20 审计）：驱动写入的 FIFO_CFG 必须让芯片解出
-- SMP_AVE = code、ROLLOVER 开 —— 旧编码 0x48 会被芯片读成 SMP_AVE=2 +
-- rollover 关（平均档位取半、满后丢样本），而模型同错使本用例曾为假绿。
check("组合 FIFO_CFG=0x98（avg16[7:5]+rollover[4]+A_FULL=8）", dev:reg(0x08) == 0x98,
      string.format("0x%02X", dev:reg(0x08)))
check("组合 FIFO_CFG 解出 avg_code=4", dev:avg_code() == 4, tostring(dev:avg_code()))
check("组合 FIFO_CFG rollover 已使能", dev:rollover_en() == true, tostring(dev:rollover_en()))
check("组合周期 16ms", dev:period_ms() == 16, tostring(dev:period_ms()))

-- LED 继承/舍入/钳制
mark = section()
build_ok({ led1 = "12.8" })
check("12.8mA -> 0x40，led2 缺省继承", dev:reg(0x0C) == 64 and dev:reg(0x0D) == 64)
mark = section()
build_ok({ led1 = "6.3", led2 = "60" })
check("6.3mA 四舍五入 0x20", dev:reg(0x0C) == 32)
check("60mA 超上限钳 0xFF", dev:reg(0x0D) == 255)

-- ---- build 负路径 ----
-- 参数非法：配置解析在 RESET 之前，窗口内只有 set_addr + PART_ID 读，无 2B 写
local function build_err(label, opts, pat)
	mark = section()
	opts.fd, opts.address = fd, "0x57"
	expect_err(label, function() return build(opts) end, pat)
	check(label .. "：零 2B 写（RESET 前拦截）", n2b(mark) == 0 and sleep_total == 0,
	      "w2=" .. n2b(mark) .. " sleep=" .. tostring(sleep_total))
end
build_err("非法 rate", { rate = "333" }, "rate(sps)")
build_err("非法 pw", { pw = "100" }, "pw(us)")
build_err("非法 adc", { adc = "1000" }, "adc(nA)")
build_err("非法 avg", { avg = "3" }, "avg")
build_err("非法 opmode", { opmode = "xxx" }, "opmode")
build_err("非法 n=9", { n = "9" }, "n(samples)")
build_err("非法 led1", { led1 = "abc" }, "led1(mA)")
build_err("rate 超 pw 上限（800@411us）", { rate = "800", pw = "411" }, "exceeds limit")

mark = section()
expect_err("非表参数", function() return build("bad") end, "Invalid Arguments Type")
check("非表零总线事务", #entries(mark) == 0)
expect_err("缺 fd", function() return build({ address = "0x57" }) end, "fd or address")
check("缺 fd 零总线事务", #entries(mark) == 0)

mark = section()
expect_err("set_addr 失败（fd=99）", function()
	return build({ fd = 99, address = "0x57" })
end, "set_addr failed")
check("set_addr 失败零事务", #entries(mark) == 0)

mark = section()
dev:fail_read(function(p) return p == 0xFF end)
expect_err("PART_ID 读失败", function()
	return build({ fd = fd, address = "0x57" })
end, "read Part ID failed")
dev:clear_faults()

mark = section()
dev:set_part_id(0x16)
expect_err("PART_ID 不符", function()
	return build({ fd = fd, address = "0x57" })
end, "unexpected Part ID")
dev:set_part_id(0x15)

mark = section()
dev:fail_write(function(b) return b[1] == 0x09 and b[2] == 0x40 end)
expect_err("RESET 写失败", function()
	return build({ fd = fd, address = "0x57" })
end, "reset write failed")
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return b[1] == 0x08 end)
expect_err("FIFO_CFG 写失败（延迟报错）", function()
	return build({ fd = fd, address = "0x57" })
end, "FIFO config write failed")
check("配置失败即短路：仅 RESET+FIFO 两笔（后续写不再发总线）",
      n2b(mark) == 2, tostring(n2b(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================

-- 空 FIFO：wait=0 立即 ERR、零睡眠、仅两指针读
mark = section()
build_ok()
mark = window()
sleep_total = 0
expect_err("空 FIFO -> ERR", function() return call({ fd = fd, address = "0x57" }) end,
           "FIFO empty")
check("空 FIFO 零睡眠", sleep_total == 0, tostring(sleep_total))
check("空 FIFO 事务：set+2 指针写+2 读、无数据读",
      #set_addrs(mark) == 1 and n1b(mark) == 2 and nrd(mark) == 2 and n2b(mark) == 0)
check("两指针为 0x04/0x06", ptr_writes(mark)[1] == 0x04 and ptr_writes(mark)[2] == 0x06)
check("两条读都是 1B", read_sizes(mark)[1] == 1 and read_sizes(mark)[2] == 1)

-- 单样本全字段
mark = section()
build_ok()
dev:push_sample(100000, 50000)
mark = window()
local r = expect_ok("call 单样本", function() return call({ fd = fd, address = "0x57" }) end)
if r then
	check("count=1/avail=1/SAT=0", r.count == 1 and r.avail == 1 and r.SAT == 0,
	      string.format("%s/%s/%s", tostring(r.count), tostring(r.avail), tostring(r.SAT)))
	check("RED/IR 别名=RED0/IR0", r.RED == 100000 and r.IR == 50000 and
	      r.RED0 == 100000 and r.IR0 == 50000)
end
check("单样本事务：3 指针写（04/06/07）", n1b(mark) == 3 and
      ptr_writes(mark)[3] == 0x07, table.concat(ptr_writes(mark), ","))
check("3 条读事务，末条 6B", nrd(mark) == 3 and read_sizes(mark)[1] == 1 and
      read_sizes(mark)[2] == 1 and read_sizes(mark)[3] == 6,
      table.concat(read_sizes(mark), ","))
check("读完 RD=1/avail=0", dev:rd_ptr() == 1 and dev:avail() == 0)

-- 18 位边界 + SAT
mark = section()
build_ok()
dev:push_samples({
	{ red = 0, ir = 262143 }, { red = 1, ir = 131072 },
	{ red = 65535, ir = 262142 }, { red = 262143, ir = 1023 },
})
mark = window()
r = expect_ok("call 4 边界样本", function() return call({ fd = fd, address = "0x57", n = "8" }) end)
if r then
	check("count=4/avail=4", r.count == 4 and r.avail == 4)
	check("s0=0/262143", r.RED0 == 0 and r.IR0 == 262143)
	check("s1=1/131072", r.RED1 == 1 and r.IR1 == 131072)
	check("s2=65535/262142", r.RED2 == 65535 and r.IR2 == 262142)
	check("s3=262143/1023", r.RED3 == 262143 and r.IR3 == 1023)
	check("满码置 SAT=1", r.SAT == 1)
	check("别名=最新 RED3/IR3", r.RED == 262143 and r.IR == 1023)
end
check("4 样本：6 条读事务（2 指针+4×6B）", nrd(mark) == 6 and n1b(mark) == 6)

-- n 排空：FIFO 旧->新序、别名最新、余量续读
mark = section()
build_ok()
for i = 1, 5 do dev:push_sample(1000 + i, 2000 + i) end
mark = window()
r = expect_ok("call n=3 排空至多 3", function() return call({ fd = fd, address = "0x57", n = "3" }) end)
if r then
	check("count=3/avail=5", r.count == 3 and r.avail == 5,
	      string.format("%s/%s", tostring(r.count), tostring(r.avail)))
	check("序旧->新 RED0=1001/RED2=1003", r.RED0 == 1001 and r.RED2 == 1003)
	check("IR0=2001/IR2=2003", r.IR0 == 2001 and r.IR2 == 2003)
	check("别名 RED=1003", r.RED == 1003)
end
r = expect_ok("再 call 续读余量 2", function() return call({ fd = fd, address = "0x57", n = "3" }) end)
if r then
	check("余 2：count=2/RED0=1004/RED1=1005",
	      r.count == 2 and r.RED0 == 1004 and r.RED1 == 1005 and r.RED == 1005)
end
expect_err("第三次 FIFO 空", function() return call({ fd = fd, address = "0x57" }) end, "FIFO empty")

-- wait 轮询：10ms 步进，到点取注入样本
mark = section()
build_ok({ wait = "30" })
dev:queue_sample(777, 888)
sleep_total = 0
mark = window()
r = expect_ok("wait 等 10ms 到样本", function()
	return call({ fd = fd, address = "0x57" })
end)
if r then
	check("等到注入 777/888", r.RED == 777 and r.IR == 888, tostring(r.RED) .. "/" .. tostring(r.IR))
end
check("实睡 10ms（一轮）", sleep_total == 10, tostring(sleep_total))
check("5 条读（2+2 轮询指针+1 数据）", nrd(mark) == 5 and n1b(mark) == 5,
      table.concat(read_sizes(mark), ","))
check("指针序列 04,06,04,06,07", table.concat(ptr_writes(mark), ",") == "4,6,4,6,7")

-- wait 耗尽：never_sample，wait=30 睡 3 轮
mark = section()
build_ok({ wait = "30" })
dev:set_never_sample(true)
sleep_total = 0
mark = window()
expect_err("wait=30 耗尽 -> empty", function()
	return call({ fd = fd, address = "0x57" })
end, "FIFO empty")
check("实睡 30ms（3×10ms 步进）", sleep_total == 30, tostring(sleep_total))
check("8 条读全是 1B 指针（无数据读）", nrd(mark) == 8 and n1b(mark) == 8 and
      read_sizes(mark)[8] == 1, table.concat(read_sizes(mark), ","))
dev:set_never_sample(false)

-- wait=5 也按 10ms 步进睡一轮
mark = section()
build_ok({ wait = "5" })
dev:set_never_sample(true)
sleep_total = 0
mark = window()
expect_err("wait=5 仍睡 10ms 一步", function()
	return call({ fd = fd, address = "0x57" })
end, "FIFO empty")
check("实睡 10ms", sleep_total == 10)
dev:set_never_sample(false)

-- HR 模式 call：3B 数据读、无 IR 键
mark = section()
build_ok({ opmode = "hr" })
dev:push_sample(12345, 99999)
mark = window()
r = expect_ok("hr call 仅红光", function() return call({ fd = fd, address = "0x57" }) end)
if r then
	check("RED=12345", r.RED == 12345 and r.RED0 == 12345)
	check("无 IR/IR0 键", r.IR == nil and r.IR0 == nil)
end
check("hr 数据读 3B", read_sizes(mark)[3] == 3, table.concat(read_sizes(mark), ","))

-- rollover 积压整圈：真实硬件 avail=0，驱动报 empty（旧桩曾假绿为 avail=8）
mark = section()
build_ok()
for i = 1, 40 do dev:push_sample(9000 + i, 0) end
expect_err("rollover 积压 40：指针差回绕 -> empty", function()
	return call({ fd = fd, address = "0x57", n = "8" })
end, "FIFO empty")

-- 自动周期样本经 call 读出（advance 正弦）
mark = section()
build_ok()
dev:advance(10)
r = expect_ok("advance 10ms 后 call 正弦样本", function()
	return call({ fd = fd, address = "0x57" })
end)
if r then
	check("首拍正弦 RED=50000/IR=60000", r.RED == 50000 and r.IR == 60000,
	      tostring(r.RED) .. "/" .. tostring(r.IR))
end

-- virt_tick 零睡眠三拍闭环
mark = section()
build_ok()
sleep_total = 0
local tick_expect = { { 0, 50000, 60000 }, { 1, nil, nil }, { 8, 68000, 82000 } }
for _, t in ipairs(tick_expect) do
	dev:virt_tick(t[1])
	local rr = call({ fd = fd, address = "0x57" })
	if t[2] then
		check(string.format("tick(%d) 闭环 RED=%d IR=%d", t[1], t[2], t[3]),
		      rr.result == "OK" and rr.RED == t[2] and rr.IR == t[3])
	else
		check(string.format("tick(%d) 有样本", t[1]), rr.result == "OK" and rr.RED ~= nil)
	end
end
check("tick 闭环零睡眠", sleep_total == 0, tostring(sleep_total))

-- ---- call 负路径 ----
mark = section()
expect_err("call 非表", function() return call(42) end, "Invalid Arguments")
check("非表零事务", #entries(mark) == 0)
expect_err("call 缺 fd", function() return call({ address = "0x57" }) end, "fd or address")
check("缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("call set_addr 失败", function()
	return call({ fd = 99, address = "0x57" })
end, "set_addr failed")
check("set_addr 失败零事务", #entries(mark) == 0)

mark = section()
build_ok()
dev:fail_read(function(p) return p == 0x04 end)
mark = window()
expect_err("WR 指针读失败", function()
	return call({ fd = fd, address = "0x57" })
end, "read FIFO pointers failed")
dev:clear_faults()

mark = section()
build_ok()
dev:push_sample(7, 7)
dev:fail_read(function(p) return p == 0x07 end)
mark = window()
expect_err("FIFO 数据读失败", function()
	return call({ fd = fd, address = "0x57" })
end, "FIFO data read failed")
check("数据失败：2 指针读成功、1 数据读被 NACK", nrd(mark) == 2 + 1)
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy
-- =====================================================================
mark = section()
build_ok()
mark = window()
expect_ok("destroy 置 SHDN", function() return destroy({ fd = fd, address = "0x57" }) end)
check("destroy 唯一写 0x09=0x80", n2b(mark) == 1 and n1b(mark) == 0 and
      reg_writes(mark)[1][1] == 0x09 and reg_writes(mark)[1][2] == 0x80)
check("destroy 后 SHDN/停采", dev:shdn() and not dev:is_active())

mark = section()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
check("缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("非表零事务", #entries(mark) == 0)

mark = section()
expect_ok("destroy set_addr 失败不发写", function()
	return destroy({ fd = 99, address = "0x57" })
end)
check("set_addr 失败零事务", #entries(mark) == 0)

tester.summary("test_max30102")
