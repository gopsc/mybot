-- MT6826S 15 位磁编码器 驱动模块（SPI 模式 3，麦歌恩 AMR 在轴安装）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SPI (
--       name String, path String, spi_mode String, bits String, speed String, delay String
--   );
--   INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
--     VALUES ('spi-0', '/dev/spidev0.0', '3', '8', '1000000', '0');
--   CREATE TABLE MT6826S (
--       name String,
--       SPI  String,
--       zero String
--   );
--   INSERT INTO MT6826S (name, SPI, zero) VALUES ('enc-0', 'spi-0', '-');
-- @SPI 的 spi_mode 必须配 3（CPOL=1 CPHA=1，数据手册 8.6.2）；时钟周期下限
--   64ns（约 15MHz），建议 1MHz 起步；bits 配 8
-- zero = 零位偏移（°）：输出 = (原始角 - zero) mod 360，关节安装偏移用；
--   芯片级零位（ZERO_POS 寄存器 0x009/0x00A + EEPROM 固化）请按手册 8.8.6
--   流程操作，本驱动不写 EEPROM
--
-- call 无需参数，返回
--   { result, ANGLE(°, 0~360, 已扣 zero), RAW(15 位原始码), STATUS(0~7), CRC_OK }
--   STATUS 位（0=正常）：bit0 超速告警 bit1 磁场弱告警 bit2 欠压告警；
--   CRC_OK=0 表示帧校验失败（已重试一次仍失败），数值照常返回交消费者决策
--   （同 SGP30 CRC_OK 契约）
--
-- 实现要点（依官方数据手册 Rev1.1 第 8.6/11 章，本地逐页核对）：
--   1. 24 位帧 = 命令 4 位 + 地址 12 位 + 数据 8 位：读 0011 / 写 0110 /
--      烧 EEPROM 1100 / 连续角度读 1010。MISO 在命令+地址段为 Hi-Z，数据在末字节
--   2. 角度寄存器（只读）：0x003=ANGLE[14:7]，0x004=ANGLE[6:0]<<1（bit0 恒 0），
--      0x005=高 5 位恒 0 + STATUS[2:0]，0x006=CRC。CSN 下降沿锁存四寄存器快照
--   3. CRC-8（多项式 0x07，MSB 先行）覆盖 0x003~0x005 共 24 位；手册未写明
--      初值，按 MT68xx 家族惯例取 0x00——若真机 CRC_OK 恒 0 请反馈核对
--   4. HAL 无全双工 SPI 封装：读帧需同帧收发（MOSI 命令 + MISO 数据），
--      本驱动经 HAL.sys.ioctl_p 间接层自组 spi_ioc_transfer 单次全双工传输
--      （结构体 cdef 与 ioctl 号均 HAL 已定义；间接层可离线 mock）
--   5. 逐寄存器读（0x003~0x006 各一帧）：锁存语义下快照跨 CSN 保持，CRC
--      校验兜底一致性；不匹配自动重读一轮

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 同时持有 HAL 表：全双工帧走 HAL.sys 间接层（可离线 mock）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local HAL = dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local ffi = require("ffi")		-- spi_ioc_transfer 结构体（HAL 已完成 cdef）

-- 调试开关：编码器逐拍读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令与寄存器 ====================
local CMD_READ  = 0x3			-- 0011 读寄存器
local REG_ANGLE_H = 0x003		-- ANGLE[14:7]
local REG_ANGLE_L = 0x004		-- ANGLE[6:0]<<1（bit0 恒 0）
local REG_STATUS  = 0x005		-- [7:3]恒 0，[2:0]STATUS
local REG_CRC     = 0x006		-- CRC（覆盖 0x003~0x005）

local ANGLE_MAX = 32768			-- 15 位满量程（360°）

-- ==================== 全双工帧（HAL.sys 间接层） ====================
-- tx: 1 基字节值表；返回等长 1 基接收字节表；失败返回 nil
-- 单次 spi_ioc_transfer 全双工传输，delay_us 语义与 HAL spi_xfer 一致
local function spi_frame(fd, tx, delay_us)
	local n = #tx
	local txbuf = ffi.new("uint8_t[?]", n)
	for i = 1, n do
		local b = math.floor(tonumber(tx[i]) or -1)
		if b < 0 or b > 255 then return nil end
		txbuf[i - 1] = b
	end
	local rxbuf = ffi.new("uint8_t[?]", n)
	local msg = ffi.new("spi_ioc_transfer[1]")
	msg[0].tx_buf = ffi.cast("unsigned long long", ffi.cast("const uint8_t *", txbuf))
	msg[0].rx_buf = ffi.cast("unsigned long long", ffi.cast("uint8_t *", rxbuf))
	msg[0].len = n
	local du = tonumber(delay_us)
	if du ~= nil and du > 0 then
		if du > 65535 then du = 65535 end
		msg[0].delay_usecs = math.floor(du)
	end
	local r = HAL.sys.ioctl_p(fd, HAL.SPI_IOC_MESSAGE_1, msg)
	if r == nil or r < 0 then return nil end
	local out = {}
	for i = 0, n - 1 do out[i + 1] = tonumber(rxbuf[i]) end
	return out
end

-- 读一个寄存器：24 位帧 [0011|A11..A8, A7..A0, 无效位]，数据在 MISO 末字节
local function read_reg(fd, reg, delay_us)
	local rx = spi_frame(fd, { CMD_READ * 16 + math.floor(reg / 256) % 16, reg % 256, 0x00 }, delay_us)
	if rx == nil then return nil end
	return rx[3]
end

-- CRC-8：多项式 0x07，初值 0x00，MSB 先行（覆盖 0x003~0x005 三字节）
local function crc8(bytes)
	local crc = 0x00
	for _, b in ipairs(bytes) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.bxor(bitc.band(bitc.lshift(crc, 1), 0xFF), 0x07)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end

-- ==================== 模块级配置 ====================
local dev_delay		-- @SPI 矩阵的传输延时（us），随 fd 从元数据流入
local cfg_zero		-- 零位偏移（°）

-- 读一组角度快照（四寄存器），校验固定位与 CRC；失败返回 nil
local function read_snapshot(fd)
	local h = read_reg(fd, REG_ANGLE_H, dev_delay)
	if h == nil then return nil end
	local l = read_reg(fd, REG_ANGLE_L, dev_delay)
	local st = read_reg(fd, REG_STATUS, dev_delay)
	local crc = read_reg(fd, REG_CRC, dev_delay)
	if l == nil or st == nil or crc == nil then return nil end
	-- 固定值校验：0x004 bit0 恒 0，0x005 高 5 位恒 0（协议一致性 + 在位佐证）
	if l % 2 ~= 0 then return nil end
	if math.floor(st / 8) ~= 0 then return nil end
	local raw = h * 128 + math.floor(l / 2)
	local ok = (crc8({ h, l, st }) == crc)
	return raw, st, ok
end

-- ==================== 配置脚本 ====================
-- 无运行时配置寄存器可写（EEPROM 项零位/线数等按手册用编程流程），仅做在位自检
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MT6826S builder func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end
	dev_delay = tonumber(data.delay) or 0

	local z = tonumber(data.zero)
	cfg_zero = (z ~= nil and z ~= 0) and z % 360 or 0

	-- 在位自检：读固定值寄存器（0x005 高 5 位恒 0；0x004 bit0 恒 0）
	local raw, st, ok = read_snapshot(fd)
	if raw == nil then
		return {
			result = "ERR",
			message = "MT6826S not responding (fixed-bit check failed, check SPI mode 3 and wiring)"
		}
	end

	print(string.format("MT6826S init OK: fd=%d delay=%dus zero=%.1fdeg status=%d crc_ok=%s",
		fd, dev_delay, cfg_zero, st, tostring(ok)))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 读一次角度快照；CRC 失败自动重读一轮，仍失败置 CRC_OK=0
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MT6826S caller func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	local raw, st, ok = read_snapshot(fd)
	if raw == nil or not ok then
		-- 传输失败/固定位违例/CRC 不符（快照撕裂特征）：整轮重试一次
		raw, st, ok = read_snapshot(fd)
	end
	if raw == nil then
		return {
			result = "ERR",
			message = "MT6826S not responding (read failed)"
		}
	end

	local deg = raw * 360.0 / ANGLE_MAX
	if cfg_zero ~= nil and cfg_zero ~= 0 then
		deg = (deg - cfg_zero) % 360
	end

	return {
		result = "OK",
		ANGLE = deg,
		RAW = raw,
		STATUS = st,
		CRC_OK = ok and 1 or 0
	}

end

-- ==================== 销毁 ====================
-- 只读器件无关断寄存器；总线 fd 归 SPI 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end
