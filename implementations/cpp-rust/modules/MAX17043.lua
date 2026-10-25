-- MAX17043 单节锂电池电量计 驱动模块（I2C，地址固定 0x36）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MAX17043_VIRT（2026-09-15 自 modules/lib/virtbus/max17043.lua
-- 迁入，单文件驱动+模型实验第二十一个，偶地址稀疏字地图族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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

require_driver("i2c", {
	name = "MAX17043",

	-- 【配置脚本】读版本号与 POR 标志（纯只读，不写寄存器）
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- MAX17043 builder func get a table --------", data)
		end

		-----------------------------------------------------
		-- 版本号（家族内不固定，仅日志；读不到 = 器件不在/总线不通）
		local ver = read_reg16(fd, REG_VER)
		if ver == nil then
			return err("Failed to read MAX17043 version")
		end

		if os.getenv("BOT4CJ_DEBUG") == "1" then
			print(string.format("MAX17043 init OK: addr=0x%02X, version=0x%04X", addr, ver))
		end
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 MAX17043 destroy 仅 arg_table + return OK，等价）


	-- 【调用MAX17043】读电池电压与剩余电量
	-- NOTE: 接收一个参数（表），返回一个结果（表）
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- MAX17043 caller func get a table --------", data)
		end

		-----------------------------------------------------
		local v = read_reg16(fd, REG_VCELL)
		if v == nil then
			return err("Failed to read MAX17043 VCELL")
		end
		local s = read_reg16(fd, REG_SOC)
		if s == nil then
			return err("Failed to read MAX17043 SOC")
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
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MAX17043_VIRT —— 2026-09-15 自 modules/lib/virtbus/max17043.lua
-- 整体迁入（单文件驱动+模型第二十一个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前二十者：① 生产路径零执行（new() 仅虚拟总线测试调用，自包含偶地址
-- 字地图实现；可读表/截幅 helper 移入段内加 max17043_ 前缀避让；new() 内
-- `local max17043 = MAX17043_VIRT` 绑定使模型体零改动沿用）；② 工厂经全局表
-- 而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且
-- 成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，
-- 互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 【偶地址稀疏字地图 I2C 器件】（与 INA219/INA226 的「字索引连续地图」同族
-- 但不同：寄存器指针是字节地址，芯片寄存器全在偶地址且不连续——0x02、0x04、
-- 0x06、0x08、0x0C，命令口 0xFE；写 {ptr,hi,lo}，读 2 字节返回该字 hi/lo，
-- 跨字 burst 按 +2 偶地址续读）：
--   0x02 VCELL  电池电压：12 位、左移 4 位存放（低 4 位恒 0），驱动读后 >>4，
--               LSB 1.25mV，码域 0~4095（满码 5.11875V，寄存器满码字 0xFFF0）；
--               只读测量区——写 ACK 但丢弃，值只能由注入 API 改
--   0x04 SOC    剩余电量：16 位无符号定点，1/256% 增量（raw/256=百分比），
--               高字节整数 %、低字节 1/256%；芯片可报告 >100%（满码 255.996%），
--               驱动不钳；只读测量区，写 ACK 丢弃
--   0x06 MODE   bit15 SLEEP（照存）、bit14 QuickStart（写 1 触发一次快速启动、
--               位自清不落盘）；本驱动不触碰
--   0x08 VERSION 生产版本号（家族内不固定，驱动 build 只读出做存在性检查、
--               不比对值）；ROM 只读，写 ACK 丢弃，who() 可覆写
--   0x0C CONFIG 高字节 RCOMP 温度补偿（POR 0x97 对应 25°C，bit15 是 RCOMP
--               的 MSB 不是复位位）、低字节告警配置；POR 0x971C，全字照存
-- 0xFE CMD    只写命令口：恰写 0x0054 触发全片复位（寄存器回上电态、
--               reset_count+1），其他值 ACK 忽略；不可读
-- 跨字读按真实字节流连续（自 0x02 读 3 字节 = VCELL hi/lo + SOC hi），
-- 连续可读区间 0x02~0x08 四字，其后保留地址 0x0A 断开。
--
-- 驱动纯只读：build 仅「set_addr + 写 0x08 指针 + 读 2B」3 事务零睡眠
-- （版本号读得到即在位，无 ID 比对、无配置写、无复位），call 依次读
-- VCELL/SOC 共 5 事务零睡眠；芯片转换自由运行、结果寄存器恒有值——
-- 无转换门/无 pending/不需要 advance，测量值只由注入 API 改变，模型
-- 绝不自造电池数据（QuickStart 只刻自清语义，不模拟 SOC 跳变）。
--
-- 用法：
--   vbus.load_driver("modules/MAX17043.lua")  -- 定义全局 build/call/destroy 与 MAX17043_VIRT
--   local dev = MAX17043_VIRT.new()
--   dev:set_vcell_v(4.1):set_soc_pct(85)
--   vbus.attach("MAX17043@0x36", 0x36, dev)
--
--   dev:who(0x0000)     -- 覆写版本号（build 不判值，仅供模型级测试）
--   dev.nack_read = true
--
-- 【边界约定】模型只固化偶地址字地图/12 位左移 4/1/256 定点/CMD 全片复位/
-- QuickStart 自清语义；>>4 与 /256 换算在驱动，物理量注入 API 常量仅为
-- 造样本，测试另做独立换算交叉。
-- =====================================================================

MAX17043_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		VCELL  = 0x02,
		SOC    = 0x04,
		MODE   = 0x06,
		VER    = 0x08,
		CONFIG = 0x0C,
		CMD    = 0xFE,
	},
	CFG_DEFAULT = 0x971C,	-- RCOMP=0x97（25°C）+ 低字节告警默认
	VER_DEFAULT = 0x0100,	-- 生产版本号家族内不固定，模型给非零典型值
	CMD_RESET  = 0x0054,	-- 写 CMD 的全片复位魔数
	VCELL_LSB_V = 0.00125,	-- VCELL >>4 后 LSB 1.25mV
	VCELL_MAX   = 4095,	-- 12 位无符号码域
	I2C_ADDR    = 0x36,	-- 芯片固定地址（无地址引脚）
}

-- 可读字（测量/配置）；CMD 是只写口不在其中
local max17043_READABLE = {
	[0x02] = true, [0x04] = true, [0x06] = true,
	[0x08] = true, [0x0C] = true,
}

local function max17043_clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function MAX17043_VIRT.new(opts)
	local max17043 = MAX17043_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local d = {}
	local regs = {}				-- 偶地址 → 16 位值
	local ptr = 0				-- 当前寄存器指针（字节地址）
	local ver_id = opts.version or max17043.VER_DEFAULT
	local reset_cfg = opts.reset_cfg or max17043.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[max17043.REG.VCELL]  = 0
		regs[max17043.REG.SOC]    = 0
		regs[max17043.REG.MODE]   = 0
		regs[max17043.REG.VER]    = ver_id
		regs[max17043.REG.CONFIG] = reset_cfg
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 1 字节 {reg} = 纯指针写（任何地址都 ACK，读时才验可读性）；恰 3 字节
	-- {reg,hi,lo} = 写一个 16 位寄存器；其余长度在本器件协议下不存在，NACK。
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		ptr = p
		if #bytes == 1 then return true end

		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == max17043.REG.VCELL or p == max17043.REG.SOC
			or p == max17043.REG.VER then
			-- 测量结果区/ROM：只读，写 ACK 但丢弃（测量值只能由注入 API 改）
			return true
		elseif p == max17043.REG.MODE then
			-- QuickStart（bit14）自清不落盘；SLEEP（bit15）及其余位照存
			regs[p] = word % 0x4000 + math.floor(word / 0x8000) * 0x8000
			return true
		elseif p == max17043.REG.CONFIG then
			regs[p] = word
			return true
		elseif p == max17043.REG.CMD then
			-- 只写命令口：恰 0x0054 全片复位，其他值 ACK 忽略
			if word == max17043.CMD_RESET then
				reseed()
				reset_count = reset_count + 1
			end
			return true
		end
		-- 未定义偶地址/奇地址字写：整笔 NACK
		return false
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时字节流按偶地址（每 2 字节一字、字间 +2）连续——读 3 字节 =
	-- 当前字 hi/lo + 下一偶地址字 hi（无「奇尾补 0」，与真实字节流一致；
	-- MAX17043 驱动从不发跨字读），途中任一地址不可读整笔 NACK。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if not max17043_READABLE[ptr] then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local words = math.ceil(n / 2)
		for i = 0, words - 1 do
			if not max17043_READABLE[ptr + i * 2] then return nil end
		end
		local out = {}
		for i = 1, n do
			local wi = ptr + math.floor((i - 1) / 2) * 2
			local word = regs[wi] or 0
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- VCELL 码：12 位无符号 0~4095（>>4 之后的码），模型左移 4 存放
	function d:set_vcell_raw(code)
		local c = max17043_clampi(math.floor(tonumber(code) or 0), 0, max17043.VCELL_MAX)
		regs[max17043.REG.VCELL] = c * 16
		return self
	end

	-- SOC 码：u16 0~65535（1/256%，芯片可报告 >100%，不钳到 100）
	function d:set_soc_raw(word)
		regs[max17043.REG.SOC] = max17043_clampi(math.floor(tonumber(word) or 0), 0, 65535)
		return self
	end

	-- MODE/CONFIG 等协议寄存器留原始 16 位码注入口（CONFIG 可直接写）
	function d:set_word(reg, word)
		reg = max17043_clampi(math.floor(reg), 0, 255)
		regs[reg] = max17043_clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 电池电压 V（12 位、1.25mV/LSB，最近码）
	function d:set_vcell_v(v)
		local code = max17043_clampi(math.floor(v / max17043.VCELL_LSB_V + 0.5),
		                    0, max17043.VCELL_MAX)
		regs[max17043.REG.VCELL] = code * 16
		return self
	end

	-- 剩余电量 %（1/256% 定点最近码；允许 >100，u16 饱和 255.996%）
	function d:set_soc_pct(pct)
		local word = max17043_clampi(math.floor(pct * 256 + 0.5), 0, 65535)
		regs[max17043.REG.SOC] = word
		return self
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期，一节典型锂电：电压 3.85±0.25V（3.6~4.1V 常用区间）、
	-- 电量 80±8% 同相正弦，无随机、E2E 数值可复现。
	--   n0  = 3.85V / 80%；n8  = 4.10V / 88%；
	--   n24 = 3.60V / 72%；n32 = 3.85V / 80%。
	-- 连续转换无武装概念，直接更新结果寄存器（守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_vcell_v(3.85 + 0.25 * s)
		self:set_soc_pct(80 + 8 * s)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写 CONFIG 复位默认值（立即置于该值，CMD 复位后也是它；nil=不改）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[max17043.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 VERSION（nil=不改；CMD 全片复位不恢复，测试 section 须显式恢复）
	function d:who(ver)
		if ver ~= nil then
			ver_id = math.floor(ver) % 65536
			regs[max17043.REG.VER] = ver_id
		end
		return self
	end

	-- 驱动 build/call 写过的 3 字节字写 {reg,hi,lo}；1 字节事务是读指针
	function d:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e == 3 then
				out[#out + 1] = { reg = e[1], hi = e[2], lo = e[3],
				                  word = e[2] * 256 + e[3] }
			end
		end
		return out
	end

	function d:reset_count() return reset_count end
	function d:pointer() return ptr end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回上电态（保留故障钩子与 who()/set_reset_cfg() 身份，复位不得解除钩子）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:version() return regs[max17043.REG.VER] or 0 end
	function d:config()  return regs[max17043.REG.CONFIG] or 0 end
	function d:mode()    return regs[max17043.REG.MODE] or 0 end
	function d:word(reg) return regs[reg] or 0 end

	-- VCELL 寄存器字 → >>4（u12 无符号码）
	function d:vcell_raw()
		return math.floor((regs[max17043.REG.VCELL] or 0) / 16)
	end

	-- SOC 寄存器字（u16，1/256%）
	function d:soc_raw()
		return regs[max17043.REG.SOC] or 0
	end

	function d:vcell_v()  return self:vcell_raw() * max17043.VCELL_LSB_V end
	function d:soc_pct()  return self:soc_raw() / 256 end

	return d
end
