-- LCD1206 字符液晶显示 驱动模块（I2C 背包，HD44780 兼容 + PCF8574 转接）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 LCD1206_VIRT（单文件驱动+模型；同协议独立实现，改协议两处同步）
--
-- 特点：
--   - HD44780 兼容控制器，4 位模式经 PCF8574 I2C 背包驱动
--   - 背包引脚映射（标准蓝色背包）：
--       P0=RS  P1=RW(恒写0)  P2=E  P3=BL  P4=D4  P5=D5  P6=D6  P7=D7
--   - 地址族：PCF8574=0x20~0x27，PCF8574A=0x38~0x3F
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LCD1206 (
--       name    String,
--       I2C     String,
--       address String,
--       cols    String,   -- 可选：每行字符数（缺省 16）
--       rows    String    -- 可选：行数（缺省 2）
--   );
--   INSERT INTO LCD1206 (name, I2C, address) VALUES ('lcd0', 'i2c-1', '0x27');
--
-- call 参数：
--   text      : 要显示的文本（按字节写入 HD44780；ASCII 0x20~0x7E 直显，
--               高位字节命中器件内置 ROM 的片假名/自定义字符区）
--   line      : 行号（0 起始，缺省 0）
--   col       : 列号（0 起始，缺省 0）
--   clear     : "1" = 写之前先清屏（约 1.5ms）
--   home      : "1" = 写之前先归位（不清内容，光标回左上角）
--   backlight : "1"/"0" 背光开关（不传则保持当前）
--   command   : 直接发 HD44780 命令字节（高级用法，忽略 text/line/col/clear/home）
--
-- call 返回 { result, COLS, ROWS, BACKLIGHT }

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：显示器写操作，默认关闭逐次打印
local DEBUG = false

-- ==================== HD44780 命令 ====================
local CMD_CLEAR      = 0x01		-- 清屏（执行时间 >1.52ms）
local CMD_HOME       = 0x02		-- 归位（光标回 0x00，内容不变）
local CMD_ENTRY_MODE = 0x04		-- 输入模式基址（|0x02=增量, |0x01=画面跟随）
local CMD_FUNC_2L    = 0x28		-- 功能设置：4 位, 2 行, 5x8 点阵
local CMD_FUNC_1L    = 0x20		-- 功能设置：4 位, 1 行, 5x8 点阵
local DISP_ON        = 0x0C		-- 显示开, 光标关, 闪烁关
local DISP_OFF       = 0x08		-- 显示关

-- ==================== 背包引脚映射 ====================
local PIN_RS = 0x01		-- P0: Register Select（0=命令, 1=数据）
local PIN_EN = 0x04		-- P2: Enable（高→低脉冲锁存 nibble）
local PIN_BL = 0x08		-- P3: Backlight（1=背光开）

-- ==================== 行偏移地址（HD44780 DDRAM）====================
-- 1602: 行 0=0x00, 行 1=0x40
-- 2004: 行 0=0x00, 行 1=0x40, 行 2=0x14, 行 3=0x54
local ROW_OFFSETS = { 0x00, 0x40, 0x14, 0x54 }

-- ==================== 模块级配置 ====================
local cfg_cols = 16
local cfg_rows = 2
local cfg_bl   = true		-- 背光状态（跨 call 保持）

-- 发送一个字节到 HD44780（4 位模式：拆成两个 nibble，各带 E 脉冲）
local function send_byte(fd, data, rs)
	local rs_bit = rs and PIN_RS or 0
	local bl_bit = cfg_bl and PIN_BL or 0

	-- 高 nibble：数据位 D4-D7 = data & 0xF0
	local hi = bitc.band(data, 0xF0)
	if i2c_write_multi(fd, bitc.bor(hi, rs_bit, bl_bit, PIN_EN)) ~= 0 then return false end
	if i2c_write_multi(fd, bitc.bor(hi, rs_bit, bl_bit)) ~= 0 then return false end

	-- 低 nibble：data << 4 取高 4 位
	local lo = bitc.band(bitc.lshift(data, 4), 0xF0)
	if i2c_write_multi(fd, bitc.bor(lo, rs_bit, bl_bit, PIN_EN)) ~= 0 then return false end
	if i2c_write_multi(fd, bitc.bor(lo, rs_bit, bl_bit)) ~= 0 then return false end

	return true
end

-- 发送命令（RS=0）
local function send_cmd(fd, cmd)
	return send_byte(fd, cmd, false)
end

-- 发送数据（RS=1）
local function send_data(fd, byte)
	return send_byte(fd, byte, true)
end

-- 初始化阶段的单 nibble 发送（HD44780 尚处 8 位模式，只认 D4-D7 上的高 nibble）
local function send_init_nibble(fd, nibble_high)
	local bl_bit = PIN_BL	-- 初始化期间背光保持开
	local base = bitc.bor(nibble_high, bl_bit)
	if i2c_write_multi(fd, bitc.bor(base, PIN_EN)) ~= 0 then return false end
	if i2c_write_multi(fd, base) ~= 0 then return false end
	return true
end

-- 更新背光引脚状态（不发命令，只刷新 PCF8574 输出锁存的 BL 位）
local function update_backlight(fd)
	local bl_bit = cfg_bl and PIN_BL or 0
	return i2c_write_multi(fd, bl_bit) == 0
end

require_driver("i2c", {
	name = "LCD1206",

	-- ==================== 配置脚本 ====================
	-- HD44780 4 位模式初始化序列（数据手册 Figure 24）：
	-- 上电后器件在 8 位模式，需先发 3 次单 nibble 握手再切 4 位
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- LCD1206 builder func get a table --------", data)
		end

		local fd = ctx.fd
		local addr = ctx.addr

		-- 地址族校验：PCF8574=0x20~0x27，PCF8574A=0x38~0x3F
		local in_family = (addr >= 0x20 and addr <= 0x27) or (addr >= 0x38 and addr <= 0x3F)
		if not in_family then
			return err(string.format("LCD1206 invalid address 0x%02X (expect 0x20~0x27 or 0x38~0x3F for PCF8574A)", addr))
		end

		-- 行列配置
		cfg_cols = int_or(data.cols, 16, 1, 40)
		cfg_rows = int_or(data.rows, 2, 1, 4)
		cfg_bl = true

		-- 步骤 1：0x03（8 位模式），等 >4.1ms
		if not send_init_nibble(fd, 0x30) then
			return err("LCD1206 not responding (init step 1, check address and wiring)")
		end
		milli_sleep(5)

		-- 步骤 2：0x03，等 >100μs
		if not send_init_nibble(fd, 0x30) then
			return err("LCD1206 not responding (init step 2)")
		end
		milli_sleep(1)

		-- 步骤 3：0x03
		if not send_init_nibble(fd, 0x30) then
			return err("LCD1206 not responding (init step 3)")
		end

		-- 步骤 4：0x02 切到 4 位模式（此后命令均为双 nibble）
		if not send_init_nibble(fd, 0x20) then
			return err("LCD1206 not responding (init step 4)")
		end

		-- 以下为 4 位模式双 nibble 命令
		local func_cmd = cfg_rows > 1 and CMD_FUNC_2L or CMD_FUNC_1L
		if not send_cmd(fd, func_cmd) then
			return err("LCD1206 not responding (function set)")
		end

		if not send_cmd(fd, DISP_ON) then
			return err("LCD1206 not responding (display on)")
		end

		if not send_cmd(fd, CMD_CLEAR) then
			return err("LCD1206 not responding (clear)")
		end
		milli_sleep(2)	-- 清屏需要 >1.52ms

		-- 输入模式：光标右移，画面不跟随
		if not send_cmd(fd, CMD_ENTRY_MODE + 0x02) then
			return err("LCD1206 not responding (entry mode)")
		end

		print(string.format("LCD1206 init OK: addr=0x%02X %dx%d", addr, cfg_cols, cfg_rows))
		return {  result = "OK"  }
	end,

	-- ==================== 调用 ====================
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- LCD1206 caller func get a table --------", data)
		end

		local fd = ctx.fd

		-- 背光控制（优先处理，影响后续所有发送的 BL 位）
		if data.backlight ~= nil then
			local on = tostring(data.backlight) == "1" or tostring(data.backlight) == "true"
			cfg_bl = on
			if not update_backlight(fd) then
				return err("LCD1206 not responding (backlight)")
			end
		end

		-- 直接命令模式（高级用法：跳过文本/定位逻辑）
		if data.command ~= nil then
			local cmd = finite_of(data.command)
			if cmd == nil then
				return err("Invalid Argument: command '" .. tostring(data.command) .. "'")
			end
			if not send_cmd(fd, math.floor(cmd)) then
				return err("LCD1206 not responding (command)")
			end
			return {  result = "OK",  COLS = cfg_cols,  ROWS = cfg_rows,
			          BACKLIGHT = cfg_bl and 1 or 0  }
		end

		-- 清屏
		if tostring(data.clear) == "1" then
			if not send_cmd(fd, CMD_CLEAR) then
				return err("LCD1206 not responding (clear)")
			end
			milli_sleep(2)
		end

		-- 归位
		if tostring(data.home) == "1" then
			if not send_cmd(fd, CMD_HOME) then
				return err("LCD1206 not responding (home)")
			end
			milli_sleep(2)
		end

		-- 定位到指定行列（设 DDRAM 地址）
		local line = int_or(data.line, 0, 0, cfg_rows - 1)
		local col  = int_or(data.col,  0, 0, cfg_cols - 1)
		local ddram_addr = (ROW_OFFSETS[line + 1] or 0) + col
		if not send_cmd(fd, 0x80 + ddram_addr) then
			return err("LCD1206 not responding (set cursor)")
		end

		-- 逐字节写文本
		local text = tostring(data.text or "")
		for i = 1, #text do
			local ch = text:byte(i)
			if ch >= 0x20 then	-- 跳过 ASCII 控制字符
				if not send_data(fd, ch) then
					return err("LCD1206 not responding (write data)")
				end
			end
		end

		return {  result = "OK",  COLS = cfg_cols,  ROWS = cfg_rows,
		          BACKLIGHT = cfg_bl and 1 or 0  }
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】LCD1206_VIRT —— HD44780 + PCF8574 背包仿真
-- 约定同其他驱动：① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零外部
-- 依赖）；② 工厂经全局表而非文件 return；③ 模型与驱动保持独立实现，互证防假绿。
--
-- 定位：【PCF8574 字节级写 → E 边沿检测 → nibble 拼接 → HD44780 命令解码】
-- 协议事实（HD44780 数据手册 + PCF8574 背包标准接线）：
--   1) PCF8574 的 8 位输出：P0=RS, P1=RW, P2=E, P3=BL, P4-P7=D4-D7
--   2) 4 位模式：每字节拆成两个 nibble，各带 E 脉冲（高→低下降沿锁存）
--   3) 初始化序列：上电后器件在 8 位模式，前 3 次单 nibble 0x03 + 1 次 0x02
--      切到 4 位模式，之后才是双 nibble 命令
--   4) RS=0 为命令（清屏/归位/功能设置/地址设置等），RS=1 为数据（DDRAM/CGRAM 写）
--   5) DDRAM 80 字节（行 0=0x00, 行 1=0x40, 行 2=0x14, 行 3=0x54）
--
-- 用法：
--   vbus.load_driver("modules/LCD1206.lua")
--   local lcd = LCD1206_VIRT.new({ cols = 16, rows = 2 })
--   vbus.attach("lcd1206@0x27", 0x27, lcd)
--
--   lcd:line_text(0)        -- 读第 0 行显示文本
--   lcd:display_text()      -- 读全部行
--   lcd:set_ddram(0, 0x41)  -- 注入 DDRAM 内容
--   lcd.nack = true          -- 故障注入
--   lcd:reset()              -- 重新上电
-- =====================================================================

LCD1206_VIRT = { _VERSION = "0.1.0" }

-- 纯算术按位与（8 位，模型不引 bitcompat，与 PCF8574_VIRT 同手法）
local function band8(a, b)
	a = a % 256
	b = b % 256
	local r, p = 0, 1
	for _ = 1, 8 do
		if a % 2 == 1 and b % 2 == 1 then r = r + p end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		p = p * 2
	end
	return r
end

local ROW_OFF = { 0x00, 0x40, 0x14, 0x54 }

function LCD1206_VIRT.new(opts)
	opts = opts or {}
	local d = {}

	local cols = opts.cols or 16
	local rows = opts.rows or 2

	-- HD44780 内部状态
	local ddram = {}
	for i = 0, 79 do ddram[i] = 0x20 end	-- 空格填充
	local cgram = {}
	for i = 0, 63 do cgram[i] = 0 end

	local addr_counter = 0
	local addr_is_cgram = false		-- false=DDRAM 模式, true=CGRAM 模式
	local entry_id = true			-- true=地址增量
	local display_on = false
	local cursor_on, blink_on = false, false
	local is_4bit = false			-- 初始化完成后切 true
	local backlight = true

	-- 4 位协议状态
	local pending_nibble = nil		-- 等待第二个 nibble（高 nibble 暂存）
	local pending_rs = false
	local e_prev = false			-- 上一次 E 引脚状态

	-- 事务留痕
	local cmds = {}					-- 已执行的命令/数据字节序列
	local write_count = 0

	-- 故障钩子
	d.nack = false

	-- 执行一个完整的命令/数据字节（RS 区分命令与数据）
	local function exec_byte(byte, rs)
		cmds[#cmds + 1] = { byte = byte, rs = rs }

		if rs then
			-- 写数据到 DDRAM 或 CGRAM
			local limit = addr_is_cgram and 64 or 80
			if addr_is_cgram then
				cgram[addr_counter % 64] = byte % 256
			else
				ddram[addr_counter % 80] = byte % 256
			end
			if entry_id then
				addr_counter = (addr_counter + 1) % limit
			else
				addr_counter = (addr_counter - 1 + limit) % limit
			end
			return
		end

		-- 命令解码
		if byte >= 0x80 then
			-- Set DDRAM address: 1AAAAAAA
			addr_counter = byte % 128
			addr_is_cgram = false
		elseif byte >= 0x40 then
			-- Set CGRAM address: 01AAAAAA
			addr_counter = byte % 64
			addr_is_cgram = true
		elseif byte >= 0x20 then
			-- Function Set: DL(bit4)/N(bit3)/F(bit2)
			-- 只记录，不改变 is_4bit（初始化序列已处理）
		elseif byte >= 0x10 then
			-- Cursor/Display shift（简化：不实现移位行为）
		elseif byte >= 0x0C then
			-- Display ON/OFF: 00001DCB
			display_on = (band8(byte, 0x04) ~= 0)
			cursor_on  = (band8(byte, 0x02) ~= 0)
			blink_on   = (band8(byte, 0x01) ~= 0)
		elseif byte >= 0x08 then
			-- Display OFF: 00001xxx (D=0)
			display_on = false
		elseif byte >= 0x04 then
			-- Entry Mode Set: 000001ID
			entry_id = (band8(byte, 0x02) ~= 0)
		elseif byte == 0x02 then
			-- Return Home
			addr_counter = 0
		elseif byte == 0x01 then
			-- Clear Display
			for i = 0, 79 do ddram[i] = 0x20 end
			addr_counter = 0
			entry_id = true
		end
		-- byte == 0x03：初始化序列握手（8 位模式命令），无操作
	end

	-- 处理 PCF8574 级别的字节写：提取引脚状态，检测 E 边沿，拼接 nibble
	local function process_byte(byte)
		local rs = (byte % 2 == 1)					-- P0
		local en = (math.floor(byte / 4) % 2 == 1)	-- P2
		local bl = (math.floor(byte / 8) % 2 == 1)	-- P3
		local nibble = math.floor(byte / 16) % 16	-- P4-P7

		backlight = bl

		-- E 下降沿（高→低）锁存 nibble
		if e_prev and not en then
			if not is_4bit then
				-- 8 位模式初始化阶段：单 nibble 即完整命令（值 = nibble 本身）
				exec_byte(nibble, rs)
				-- 收到 0x02 切到 4 位模式
				if nibble == 0x02 then
					is_4bit = true
					pending_nibble = nil
				end
			else
				-- 4 位模式：拼接高 nibble + 低 nibble
				if pending_nibble == nil then
					pending_nibble = nibble
					pending_rs = rs
				else
					local full_byte = pending_nibble * 16 + nibble
					exec_byte(full_byte, pending_rs)
					pending_nibble = nil
				end
			end
		end

		e_prev = en
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if d.nack then return false end
		for i = 1, #bytes do
			local b = bytes[i]
			if type(b) ~= "number" or b ~= math.floor(b) or b < 0 or b > 255 then
				return false
			end
			process_byte(b)
		end
		write_count = write_count + 1
		return true
	end

	function d.read(n)
		if d.nack then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end
		local limit = addr_is_cgram and 64 or 80
		local tab = addr_is_cgram and cgram or ddram
		local out = {}
		for i = 1, n do
			out[i] = tab[addr_counter % limit] or 0x20
			if entry_id then
				addr_counter = (addr_counter + 1) % limit
			else
				addr_counter = (addr_counter - 1 + limit) % limit
			end
		end
		return out
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 读取指定行的显示文本（0 起始行号）
	function d:line_text(row)
		row = math.floor(tonumber(row) or 0)
		if row < 0 or row >= rows then return nil end
		local offset = ROW_OFF[row + 1] or 0
		local s = {}
		for i = 0, cols - 1 do
			local ch = ddram[(offset + i) % 80] or 0x20
			if ch >= 0x20 and ch <= 0x7E then
				s[#s + 1] = string.char(ch)
			else
				s[#s + 1] = "?"
			end
		end
		return table.concat(s)
	end

	-- 读取全部行显示内容
	function d:display_text()
		local lines = {}
		for r = 0, rows - 1 do
			lines[#lines + 1] = self:line_text(r)
		end
		return lines
	end

	-- 注入 DDRAM 内容（测试用）
	function d:set_ddram(addr, byte)
		ddram[math.floor(addr) % 80] = math.floor(byte) % 256
		return self
	end

	function d:clear_faults()
		d.nack = false
		return self
	end

	function d:reset()
		for i = 0, 79 do ddram[i] = 0x20 end
		for i = 0, 63 do cgram[i] = 0 end
		addr_counter = 0
		addr_is_cgram = false
		entry_id = true
		display_on, cursor_on, blink_on = false, false, false
		is_4bit = false
		backlight = true
		pending_nibble = nil
		e_prev = false
		cmds = {}
		write_count = 0
		return self
	end

	-- 守护逐拍造数：不做任何事（显示器是输出设备，不产生传感器数据）
	function d:virt_tick(n)
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:is_display_on() return display_on end
	function d:is_cursor_on() return cursor_on end
	function d:is_blink_on() return blink_on end
	function d:backlight() return backlight end
	function d:addr_counter() return addr_counter end
	function d:cmd_count() return #cmds end
	function d:commands() return cmds end
	function d:write_count() return write_count end

	return d
end
