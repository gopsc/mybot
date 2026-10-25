-- MCP4725 12 位 I2C DAC 驱动模块（模拟量输出，EEPROM 断电保持）
-- bot4cj 仓颉语言机器人框架
-- Microchip，I2C 地址 0x62（A0=GND）/0x63（A0=VDD），12 位 0~VDD 输出
-- （VDD 即参考电压），轨到轨输出，建立时间 6µs
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MCP4725 (
--       name    String,
--       I2C     String,
--       address String,
--       vref    String
--   );
--   INSERT INTO MCP4725 (name, I2C, address, vref)
--     VALUES ('dac0', 'i2c-1', '-', '-');
-- address = 0x62/0x63（A0 引脚，'-' 缺省 0x62）
-- vref    = 参考电压 V（=VDD，volt 列换算用，'-' 缺省 5.0）
--
-- call 契约（双用，同 EMC2101）：
--   带参设置（优先级 level > volt > percent）：
--     level 0~4095 原始码 | volt 输出电压 V（0~vref 钳位）| percent 0~100
--     eep =1 时走"写 DAC+EEPROM"并轮询 RDY（断电保持）；缺省快速写（易失，
--     2 字节事务，适合高频更新）
--   无参读回（MCP4725 有读回能力，比 TPL0501 强）：
--     { result, level(DAC 当前码), eeprom(EEPROM 保存码), pd(掉电位), volt }
-- 接 sensor_daemon：fields=level|eeprom（整数；读回路径无需参数）
--
-- 实现要点（命令位布局依 Adafruit CircuitPython MCP4725 库核实，MIT）：
--   1. 无寄存器地图——命令嵌在 I2C 写流首字节高 3 位（C2..C0）
--   2. 快速写 2 字节：[0x00 | 值>>8, 值 & 0xFF]（C2..C0=000，仅更新 DAC）
--   3. 写 DAC+EEPROM 3 字节：[0x60, 值>>4 & 0xFF, 值<<4 & 0xFF]（C2..C0=011）；
--      EEPROM 写周期约 25ms，期间读回首字节 bit7=RDY（0=忙 1=完成），
--      50ms 步进轮询 500ms 超时
--   4. 读回 5 字节：byte0 = RDY+掉电位回显，byte1/2 = DAC 值
--      （(b1<<4 | b2>>4) & 0xFFF），byte3/4 = EEPROM 值（(b3&0xF)<<8 | b4）
--   5. 换算：volt -> 码 = floor(volt x 4096 / vref + 0.5)（数据手册传递
--      函数 VOUT = VREF x 码/4096；volt=vref 时码钳 4095）；percent ->
--      码 = floor(pct x 4095 / 100 + 0.5)（100% = 满码）
--   6. 通用呼叫复位（地址 0x00 + 0x06，模拟上电重载 EEPROM）本驱动未用；
--      掉电模式（PD1:0）亦未暴露

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：DAC 一般配置后长跑，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 命令字 ====================
local CMD_FAST       = 0x00		-- 快速写（C2..C0=000，仅 DAC）
local CMD_DAC_EEPROM = 0x60		-- 写 DAC+EEPROM（C2..C0=011）

local RDY_MASK       = 0x80		-- 读回 byte0 bit7：EEPROM 写完成
local EEPROM_TIMEOUT_MS = 500
local EEPROM_POLL_MS = 50

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local vref = 5.0

-- 读回 5 字节 -> {pd, level, eeprom}（字节布局见头注释）
local function decode_readback(v)
	local b0 = math.floor(v / 256 ^ 4) % 256
	local b1 = math.floor(v / 256 ^ 3) % 256
	local b2 = math.floor(v / 256 ^ 2) % 256
	local b3 = math.floor(v / 256) % 256
	local b4 = v % 256
	return {
		pd = math.floor(b0 / 16) % 4,
		level = (b1 * 16 + math.floor(b2 / 16)) % 4096,
		eeprom = (b3 % 16) * 256 + b4,
		rdy = (b0 % 256) >= 0x80
	}
end

-- 【配置脚本】读回一次作为在位验证（无寄存器可校验器件，读通即在）
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MCP4725 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address) or 0x62
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-- 参考电压列（'-' 缺省 5.0；非正数同缺省，防除零）
	local v = tonumber(data.vref)
	if v == nil or v <= 0 then v = 5.0 end
	vref = v

	-----------------------------------------------------
	local r = i2c_read(fd, 5)
	if r < 0 then
		return {
			result = "ERR",
			message = "Failed to read MCP4725 (器件在位检查)"
		}
	end
	local rb = decode_readback(r)

	print(string.format("MCP4725 init OK: addr=0x%02X, vref=%.2fV, DAC=%d, EEPROM=%d",
		addr, vref, rb.level, rb.eeprom))
	return {  result = "OK"  }

end

-- 【销毁MCP4725】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用MCP4725】双用：带参设置输出（level/volt/percent，eep 持久化），
-- 无参读回当前 DAC/EEPROM 码
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MCP4725 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	-- 无参：读回
	local level = tonumber(data.level)
	local volt = tonumber(data.volt)
	local percent = tonumber(data.percent)
	local eep = (tonumber(data.eep) or 0) ~= 0

	if level == nil and volt == nil and percent == nil then
		local r = i2c_read(fd, 5)
		if r < 0 then
			return {
				result = "ERR",
				message = "Failed to read MCP4725"
			}
		end
		local rb = decode_readback(r)
		return {
			result  = "OK",
			level   = rb.level,
			eeprom  = rb.eeprom,
			pd      = rb.pd,
			volt    = rb.level * vref / 4096,
			rdy     = rb.rdy and 1 or 0
		}
	end

	-----------------------------------------------------
	-- 带参：按优先级 level > volt > percent 换算目标码
	local code
	if level ~= nil then
		code = math.floor(level)
	elseif volt ~= nil then
		code = math.floor(volt * 4096 / vref + 0.5)
	else
		code = math.floor(percent * 4095 / 100 + 0.5)
	end
	if code < 0 then code = 0 end
	if code > 4095 then code = 4095 end

	if eep then
		-- 写 DAC+EEPROM（3 字节，C2..C0=011）
		if i2c_write_multi(fd, CMD_DAC_EEPROM,
			math.floor(code / 16) % 256, (code * 16) % 256) ~= 0 then
			return {
				result = "ERR",
				message = "Failed to write MCP4725 DAC+EEPROM"
			}
		end
		-- 轮询 RDY（50ms 步进 500ms 超时；1 字节读的合并值即 byte0）
		for _ = 1, 10 do
			milli_sleep(EEPROM_POLL_MS)
			local r = i2c_read(fd, 1)
			-- 总线读失败（-1）必须与"未就绪"区分：断线误报成
			-- "EEPROM 写超时"会把排障引向错误方向（2026-09 审计）
			if r < 0 then
				return {
					result = "ERR",
					message = "MCP4725 EEPROM write: bus read failed while polling RDY"
				}
			end
			if r >= RDY_MASK then
				dbg(string.format("MCP4725 EEPROM write done: code=%d", code))
				return {
					result  = "OK",
					level   = code,
					volt    = code * vref / 4096,
					percent = code * 100 / 4095,
					eeprom  = 1
				}
			end
		end
		return {
			result = "ERR",
			message = "MCP4725 EEPROM write timeout (RDY not set in 500ms)"
		}
	end

	-- 快速写（2 字节，仅 DAC，适合高频更新）
	if i2c_write_multi(fd, CMD_FAST + math.floor(code / 256) % 256, code % 256) ~= 0 then
		return {
			result = "ERR",
			message = "Failed to write MCP4725 DAC"
		}
	end

	dbg(string.format("MCP4725 set: code=%d", code))
	return {
		result  = "OK",
		level   = code,
		volt    = code * vref / 4096,
		percent = code * 100 / 4095,
		eeprom  = 0
	}

end
