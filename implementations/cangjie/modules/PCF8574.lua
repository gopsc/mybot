-- PCF8574 8 位准双向 IO 扩展器 驱动模块（I2C）
-- bot4cj 仓颉语言机器人框架
-- NXP PCF8574（T=SO16 封装后缀）：无寄存器图——写一字节 = 输出锁存，
-- 读一字节 = 引脚即时状态。总线限 100kHz 标准模式（不支持 400kHz）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE PCF8574 (
--       name    String,
--       I2C     String,
--       address String,
--       out     String    -- 上电初始输出锁存 0~255（缺省 0xFF = 全部弱上拉/输入态）
--   );
--   INSERT INTO PCF8574 (name, I2C, address, out)
--     VALUES ('io-0', 'i2c-1', '0x20', '255');
-- 地址族：PCF8574 = 0x20~0x27（A2/A1/A0 引脚），PCF8574A 变体 = 0x38~0x3F，
--   其他地址直接报错（常见接错器件）
--
-- call 返回 { result, PINS(引脚即时状态 0~255), OUT(当前输出锁存) }：
--   传 out=0~255 先写锁存再回读；不传则纯读引脚。
-- 准双向语义（无方向寄存器）：写 1 = 弱上拉（可被外部拉低，当输入），
--   写 0 = 强驱动低（当输出）；外部拉低恒胜过弱上拉。全输入姿势：out=255 后读。
--
-- 硬件注意：灌电流强（单脚约 25mA，可直点 LED/继电器板晶体管），拉电流极弱
--   （约百 uA）——输出高靠外部上拉，勿用它直接供电；INT 引脚本驱动未用（轮询）。
-- 在位探测：I2C ACK 即存在性证据（器件无 ID 寄存器），build 读一次确认。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：IO 扩展器逐拍读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 模块级配置 ====================
local cfg_latch		-- 当前输出锁存（跨 call 保持于本变量独立状态机）

-- 读引脚即时状态（0~255）；失败返回 nil
local function read_pins(fd)
	local v = i2c_read(fd, 1)
	if v < 0 then return nil end
	return v % 256
end

-- ==================== 配置脚本 ====================
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- PCF8574 builder func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end
	-- 地址族校验：8574 = 0x20~0x27，8574A = 0x38~0x3F
	local in_family = (addr >= 0x20 and addr <= 0x27) or (addr >= 0x38 and addr <= 0x3F)
	if not in_family then
		return {
			result = "ERR",
			message = string.format("PCF8574 invalid address 0x%02X (expect 0x20~0x27 or 0x38~0x3F for PCF8574A)", addr)
		}
	end
	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-- 在位探测：读一次引脚（ACK 即存在性证据）
	local pins = read_pins(fd)
	if pins == nil then
		return {
			result = "ERR",
			message = "PCF8574 not responding (read failed, check address and wiring)"
		}
	end

	-- 初始输出锁存（缺省 0xFF：POR 默认全弱上拉，显式写以对齐状态）
	local out = tonumber(data.out)
	if out == nil or data.out == "-" or data.out == "" then out = 0xFF end
	out = math.floor(out)
	if out < 0 or out > 255 then
		return {
			result = "ERR",
			message = "Invalid Argument: out '" .. tostring(data.out) .. "' (range 0~255)"
		}
	end
	if i2c_write_multi(fd, out) ~= 0 then
		return {
			result = "ERR",
			message = "PCF8574 not responding (latch write failed)"
		}
	end
	cfg_latch = out

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("PCF8574 init OK: addr=0x%02X latch=0x%02X pins=0x%02X",
			addr, out, pins))
	end
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- out=0~255 写输出锁存；不传则纯读引脚。两种情况都回读引脚即时状态。
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- PCF8574 caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------
	local out = tonumber(data.out)
	if out ~= nil then
		out = math.floor(out)
		if out < 0 or out > 255 then
			return {
				result = "ERR",
				message = "Invalid Argument: out '" .. tostring(data.out) .. "' (range 0~255)"
			}
		end
		if i2c_write_multi(fd, out) ~= 0 then
			return {
				result = "ERR",
				message = "PCF8574 not responding (latch write failed)"
			}
		end
		cfg_latch = out
	end

	local pins = read_pins(fd)
	if pins == nil then
		return {
			result = "ERR",
			message = "PCF8574 not responding (read failed)"
		}
	end

	return {
		result = "OK",
		PINS = pins,
		OUT = cfg_latch or 0xFF
	}

end

-- ==================== 销毁 ====================
-- 无关断寄存器；锁存保持到断电；fd 归 I2C 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end
