-- MAX17043 单节锂电池电量计 驱动模块（I2C，地址固定 0x36）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MAX17043 (
--       name    String,
--       I2C     String,
--       address String
--   );
--   INSERT INTO MAX17043 (name, I2C, address) VALUES ('fuel-0', 'i2c-1', '0x36');
-- 地址芯片固定为 0x36（无地址引脚），一条总线只能挂一颗，address 列照填 0x36 即可
--
-- call 无需额外参数，返回
--   { result, VCELL(电池电压 V), SOC(剩余电量 %，保留 1/256 小数) }
-- 接 sensor_daemon：fields=VCELL|SOC（浮点，勿配 sign）
--
-- 实现要点（寄存器语义依 Linux 内核 drivers/power/supply/max17040_battery.c 钉死）：
--   1. VCELL（0x02）：12 位、左移 4 位存放（读后 >>4），LSB 1.25mV
--      （max17040_family 表：shift=4, mul=1250µV, div=1）
--   2. SOC（0x04）：16 位定点数，1/256% 增量（raw / 256 = 百分比）；
--      内核取整为 >>8，本驱动保留小数精度
--   3. 本驱动纯只读：build 不写任何寄存器。MAX17043 没有 ID 寄存器也没有
--      POR/STATUS 寄存器（那是 MAX17048 起新增的 0x1A）；CONFIG（0x0C）
--      高字节是 RCOMP 温度补偿系数（默认 0x97 对应 25°C），bit15 属于
--      RCOMP 的 MSB 而非独立标志位，勿当 POR 位使用
--   4. QuickStart（MODE 0x06 的位操作）未实现：内核同样不触碰该寄存器；
--      如需请按数据手册补充（写错位有误开睡眠模式的风险）
--   5. 复位字 0x0054 -> CMD（0xFE）可全片复位（内核 reset_val），本驱动不用
--   6. 需真电池才有意义：空载/无电池时 VCELL 趋近 0、SOC 无意义

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：电量计读取频率低，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_VCELL  = 0x02		-- 电池电压：12 位左移 4，LSB 1.25mV
local REG_SOC    = 0x04		-- 剩余电量：1/256% 增量
local REG_MODE   = 0x06		-- QuickStart/睡眠控制（本驱动不触碰）
local REG_VER    = 0x08		-- 版本号（家族内不固定，仅日志上报）
local REG_CONFIG = 0x0C		-- 高字节 RCOMP（默认 0x97），低字节告警配置
local REG_CMD    = 0xFE		-- 命令字：写 0x0054 全片复位（本驱动不用）

local VCELL_LSB_V = 0.00125		-- VCELL LSB：1.25mV（>>4 后 12 位）

-- 读 16 位寄存器原始值；失败（-1）返回 nil（2 字节合并恒为正且精确，无回绕）
local function read_reg16(fd, reg)
	local v = i2c_read_multi(fd, reg, 2)
	if v < 0 then return nil end
	return v
end

-- 【配置脚本】读版本号与 POR 标志（纯只读，不写寄存器）
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MAX17043 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 版本号（家族内不固定，仅日志；读不到 = 器件不在/总线不通）
	local ver = read_reg16(fd, REG_VER)
	if ver == nil then
		return {
			result = "ERR",
			message = "Failed to read MAX17043 version"
		}
	end

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("MAX17043 init OK: addr=0x%02X, version=0x%04X", addr, ver))
	end
	return {  result = "OK"  }

end

-- 【销毁MAX17043】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用MAX17043】读电池电压与剩余电量
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MAX17043 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	local v = read_reg16(fd, REG_VCELL)
	if v == nil then
		return {
			result = "ERR",
			message = "Failed to read MAX17043 VCELL"
		}
	end
	local s = read_reg16(fd, REG_SOC)
	if s == nil then
		return {
			result = "ERR",
			message = "Failed to read MAX17043 SOC"
		}
	end

	-- 返回字典：SOC 保留 1/256% 小数精度（内核取整为 >>8）
	local ret = {
		result = "OK",
		VCELL = bitc.rshift(v, 4) * VCELL_LSB_V,
		SOC   = s / 256.0
	}

	if DEBUG then
		print(string.format("MAX17043: VCELL=%.3fV SOC=%.2f%%", ret.VCELL, ret.SOC))
	end

	return ret

end
