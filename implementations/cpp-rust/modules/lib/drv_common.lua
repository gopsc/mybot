-- drv_common.lua - 驱动公共样板（modules/lib/）
-- bot4cj 仓颉语言机器人框架
--
-- 收敛 Low 项"样板重复"：各 I2C 驱动内联重复的开头样板：
--   1. type(data) ~= "table" 参数校验（build/call/destroy 每函数一份）
--   2. fd/address 存在性 + i2c_set_addr 校验（build 与 call 双份）
--      —— i2c_pair()（存在性 + set_addr）；额外校验需插在 set_addr 之前的
--      驱动用 i2c_check()（仅存在性）自行把 set_addr 留到校验之后
--   3. { result = "ERR", message = ... } 返回表构造（err()）
-- 行为与各驱动旧内联版本等价；调用点语义不变。
-- 驱动顶部在 HAL 之后 dofile 加载；依赖 i2c_set_addr（HAL）在此运行时可解析。
-- 幂等：同状态机内只定义一次（多个驱动文件 dofile 本库时安全）。
-- 用本库私有标记判断重复加载——若用 arg_table 等全局函数的存在性判断，
-- 状态机「先定义了同名全局函数但缺 err/i2c_pair」时会整体 return，消费者则崩溃。
if __BOT4CJ_DRV_COMMON_LOADED ~= nil then return end
__BOT4CJ_DRV_COMMON_LOADED = true

-- 统一 ERR 返回契约（与各驱动旧内联 {result="ERR",message=...} 一致）
function err(msg)
	return {  result = "ERR",  message = msg  }
end

-- ---- 整数钳位单点（M2/B2-4，2026-09-20）-------------------------------
-- 收敛散落各驱动（ADS1015/ADS1115/AS3935/BH1745/BMI270/BMM150/EMC2101/
-- INA226/INA3221/LSM6DSV）的本地 clampi 拷贝：此前 floor+tonumber 与裸比
-- 两派语法并存，同一语义两样写法，新增驱动照抄哪份都算拷贝。单点取防御派
-- ——非法值夹到端点；裸比派驱动的入参本已是数，等价。
-- NaN/inf 拦截（2026-09-20 审计收口）：LuaJIT 下 math.floor(NaN)=NaN，而
-- NaN 与任何数比较均为假——若传入 number 型 NaN，旧实现会**直接返回 NaN**，
-- 与「非法值夹到端点」契约相悖，并把 NaN 泄漏给下游（全仓 C2 口径一致）。
-- 这里在 floor 之前统一拒绝非数字/nil/非有限，回落下界 lo。
function clampi(v, lo, hi)
	v = tonumber(v)
	if v == nil or v ~= v or v == math.huge or v == -math.huge then return lo end
	v = math.floor(v)
	if v < lo then return lo elseif v > hi then return hi else return v end
end

-- ---- build 全程守卫（fd 回滚防线）------------------------------------------
-- 教训同 sensor_daemon 的 build 就地 pcall：build 在打开总线句柄之后若抛
-- Lua error（后续接入的配置步骤、器件自检等），裸调用会跳过 fd 回滚；宿主
-- 随即 lua_close（HAL 无 ffi.gc 终结器），fd 永久泄漏在进程里。此处统一
-- pcall：异常折成 ERR 契约表，折返前尽力执行 rollback 关闭已打开的句柄。
-- rollback 必须幂等：正常路径的「重复 build 先关旧句柄」守卫已关过时不得误关。
function guard_build(rollback, fn, data)
	local ok, r = pcall(fn, data)
	if ok then return r end
	if type(rollback) == "function" then pcall(rollback) end
	return err("build() raised: " .. tostring(r))
end

-- ---- destroy 约定：资源不可用即静默成功 ------------------------------------
-- destroy 的职责是「尽力释放」，不是「校验入参」：器件可能因 build 失败或
-- 总线已先行释放而拿不到 fd/address，此时返回 ERR 会把一次正常的收尾报成
-- 失败（--tcp 会话下表现为退出码非零、日志里一串 Deactive warning）。故
-- destroy 内统一写成：
--   local fd, addr = tonumber(data.fd), tonumber(data.address)
--   if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
--       ...与器件状态有关的收尾动作...
--   end
--   return { result = "OK" }
-- 即「资源不可用 → 跳过动作，仍报 OK」。例外：ADS1115 的 destroy 有显式
-- ERR 契约回归用例（test_ads1115.lua 覆盖缺 fd/缺 addr/set_addr 失败三条），
-- 属被测试固定的既有契约，不在本约定改范内。

-- ---- 非守护路径的虚拟总线前置（proto=virt 的设备行）---------------------
-- 背景：注入虚拟总线此前只发生在 sensor_daemon.lua（守护路径）里，所以全部
-- virt 端到端用例都是守护型，@Action 直接驱动的写路径（舵机/DAC）无从仿真。
-- N-26：本函数是**独立入口**（不再缝进 arg_table 内部）——arg_table 只是它的
-- 一个调用方；挂载分派与守护路径共用 virtbus.attach_model。这样注入可在
-- arg_table 之外单独调用/测试，职责不再混在参数校验里。
-- 注入必须在驱动碰总线之前完成，故 arg_table（各驱动入口第一行）仍代调它。
local virt_state = "idle"		-- idle → done | error:<原因>；每状态机只尝试一次

-- 独立入口：准备虚拟总线（加载 virtbus → 发现并挂载 *_VIRT 模型 → inject）
-- 返回 nil 表示无需动作或已就绪；返回字符串表示必须中止本次驱动调用
function virt_prepare(data)
	-- fix-plan 3-3：BOT4CJ_MODULE_PATH 各段逐段探测（此前只取首段，多路径
	-- 布局下首段没有 virtbus.lua 即误报 cannot load）。保持原有「无仓库
	-- 缺省布局兜底」的报错契约：找不到仍走 error 分支（见下）。
	local vbus
	for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
		local ok, v = pcall(dofile, p .. "/lib/virtbus.lua")
		if ok and type(v) == "table" then vbus = v break end
	end
	if type(vbus) ~= "table" then
		virt_state = "error:cannot load lib/virtbus.lua"
		return virt_state:sub(7)
	end
	-- 守护路径已注入过：模型实例归它管，这里再 attach 一份会出现
	-- 「守护泵 A 实例、驱动写 B 实例」的静默错位，故整体跳过。
	if vbus._injected then virt_state = "done"; return nil end

	-- 模型按约定发现（D2-6/F1-8，2026-09-21）：本状态机只加载一个驱动文件，
	-- 其内嵌全局至多一个 *_VIRT。pairs(_G) 的遍历顺序不确定，旧实现在出现两个
	-- 模型时「静默取最后一个」——挂错模型读到的是另一颗器件的寄存器语义，
	-- 比报错难查得多。故：恰好一个 → 用它；两个及以上 → 明确报错并点名双方。
	local found = {}
	for k in pairs(_G) do
		if type(k) == "string" and k:match("^(.+)_VIRT$") then
			found[#found + 1] = k
		end
	end
	if #found > 1 then
		table.sort(found)		-- 报错文案与 pairs 顺序无关，测试可逐字断言
		virt_state = "error:multiple <DRIVER>_VIRT models in one lua_State: "
			.. table.concat(found, ", ")
			.. " (host keeps one lua_State per hardware variable; do not load"
			.. " two drivers into the same state)"
		return virt_state:sub(7)
	end
	local model, driver
	if #found == 1 then
		model = rawget(_G, found[1])
		driver = found[1]:match("^(.+)_VIRT$")
	end

	local addr = tonumber(data.address)
	if addr ~= nil and model == nil then
		-- 设备行要求仿真却拿不到模型：绝不静默回落到真实总线（那会让
		-- 「无硬件跑通」的测试悄悄打到真机舵机上），必须报错中止。
		virt_state = "error:" .. tostring(driver or "device")
			.. " declared proto=virt but no embedded <DRIVER>_VIRT model was found"
		return virt_state:sub(7)
	end

	-- 工厂表 → 实例（与 sensor_daemon 同约定）：挂载的必须是实例——virtbus 的
	-- 动态委托取 dev.write / dev.on_write，工厂表身上没有这些方法，直接把工厂
	-- attach 会让「写静默成功、读永远无应答」（PCA9685 直写 E2E 的旧缺口，
	-- SCSCL 的 PING 探测把该缺口暴露为构建失败）。BUS 标记先取工厂（实例可省）。
	local bus = (model ~= nil) and rawget(model, "BUS") or nil
	if model ~= nil and type(model.new) == "function" then
		local ok_new, inst = pcall(model.new)
		if not ok_new or type(inst) ~= "table" then
			virt_state = "error:" .. tostring(driver or "device")
				.. " model new() failed: " .. tostring(inst)
			return virt_state:sub(7)
		end
		model = inst
		if bus == nil then bus = rawget(inst, "BUS") end
	end

	-- 挂载分派与守护路径共用 virtbus.attach_model（N-26）：
	--   UART 模型身份是 tty 路径（来自 @UART 引用快照，modules/UART.lua 的
	--   call 下发 fd/baud/path）；I2C 模型身份是 address。
	--   总线行（I2C/SPI/UART 变量自身）无 address，跳过 attach，仅靠下面的
	--   inject 让它的 open 变成虚拟 open。
	--   注：SPI 模型的直驱挂载未启用（片选路径来源未经确认，保持今日行为
	--   ——SPI 器件当前一律走守护路径仿真），故 kind=="spi" 时不 attach。
	if model ~= nil then
		-- kind 直接用上面已算出的 bus（工厂表 BUS 优先、实例 BUS 兜底）——
		-- 不能用 model_kind(model)：此时 model 已重赋为**实例**，而实例未必
		-- 带 BUS 标记（标记常只写在工厂表上），会误判成 i2c 而漏挂 UART/SPI 模型
		local kind = bus or "i2c"
		if kind == "uart" then
			if type(data.path) ~= "string" then
				virt_state = "error:" .. tostring(driver)
					.. " is a BUS=\"uart\" model but metadata has no tty path"
					.. " (missing @UART reference column or UART call did not send path?)"
				return virt_state:sub(7)
			end
			vbus.attach_model("VIRT:" .. tostring(driver) .. "@" .. data.path,
				model, addr, data.path, "uart")
		elseif kind ~= "spi" and addr ~= nil then
			vbus.attach_model("VIRT:" .. tostring(driver) .. "@" .. tostring(addr),
				model, addr, data.path, "i2c")
		end
	end
	-- fd 由总线变量（modules/I2C.lua、modules/UART.lua）在它自己的状态机里 open
	-- 出来；本状态机要先把这个进程级整数登记进本地 virtbus，否则 i2c_set_addr /
	-- uart_read 等认不出该句柄。
	if data.fd ~= nil then vbus.adopt_fd(data.fd, data.path, addr, bus) end
	vbus.inject()
	virt_state = "done"

	local what
	if addr ~= nil then
		what = tostring(driver) .. (" @0x" .. string.format("%X", addr))
	elseif bus == "uart" then
		what = tostring(driver) .. " @" .. tostring(data.path)
	else
		what = tostring(data.name or "bus")
	end
	print(" [drv_common] *** VIRTUAL HARDWARE -- NO REAL DEVICE *** (" .. what .. ")")
	return nil
end

-- 请求参数必须是表；否则返回 ERR
-- 用法：local ok, e = arg_table(data); if not ok then return e end
-- 附带一次性的虚拟总线前置（代调独立入口 virt_prepare，见上），故必须保持
-- 在各驱动入口的首个调用位置。
function arg_table(data)
	if type(data) ~= "table" then
		return false, err("Invalid Arguments Type: table")
	end
	if virt_state ~= "idle" then
		if virt_state ~= "done" then
			-- 前置曾失败：每次调用都重放同一原因，绝不放行到总线调用
			return false, err("proto=virt setup failed: " .. virt_state:sub(7))
		end
	elseif data.proto == "virt" then
		local why = virt_prepare(data)
		if why then return false, err("proto=virt setup failed: " .. why) end
	else
		virt_state = "done"		-- 真机路径：一次比较即永久关闭本前置
	end
	return true, nil
end

-- I2C 传感器 fd/address 存在性校验（不含 set_addr）
-- 用法：local fd, addr, e = i2c_check(data); if fd == nil then return e end
-- 返回：成功 => (fd, addr, nil)；失败 => (nil, -1, err表)
-- 供「额外校验须插在 set_addr 之前」的驱动使用（如 MS5611 的 OSR 档位、
-- PCF8574 的地址族）：这些驱动约定非法配置值不碰总线，set_addr（ioctl
-- I2C_SLAVE）须留到校验通过之后，故不能直接用 i2c_pair。
function i2c_check(data)
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return nil, -1, err("Invalid Argument: fd or address")
	end
	return fd, addr, nil
end

-- I2C 传感器 build/call 公共前置：fd/address 存在性 + set_addr
-- 用法：local fd, addr, e = i2c_pair(data); if fd == nil then return e end
-- 返回：成功 => (fd, addr, nil)；失败 => (nil, -1, err表)
-- 原各驱动 build 与 call 双份校验语义一致，统一于此
function i2c_pair(data)
	local fd, addr, ek = i2c_check(data)
	if fd == nil then return nil, -1, ek end
	if not i2c_set_addr(fd, addr) then
		return nil, -1, err("Invalid Argument: fd or address (set_addr failed)")
	end
	return fd, addr, nil
end

-- ---- 数值列解析（N-24）-----------------------------------------------------

-- 数值归一化单点仍在 lib/bus_contract.lua（finite_of）——**本库不自带第二份
-- 判定**。同一状态机里 HAL/virtbus 已 dofile 过它，全局 __BOT4CJ_BUS_CONTRACT
-- 即那张表；脱离宿主直跑（luajit 单测、scscl_scan）时按模块路径逐段探测一次
-- （与 virt_prepare 同一手法；bus_contract 自带重入口守卫，身份不变）。
local bus = __BOT4CJ_BUS_CONTRACT
if bus == nil then
	for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
		local ok, v = pcall(dofile, p .. "/lib/bus_contract.lua")
		if ok and type(v) == "table" then bus = v break end
	end
end
-- 兜底：布局异常导致 bus_contract 不可达时，判定不得静默退化成「NaN 放行」
-- ——那正是本防线要堵的洞。兜底分支与 finite_of 逐字同判据，仅此一处。
-- 导出为全局（`local` 曾使它只能被本文件内的 int_or/num_or 使用）：驱动解析
-- **样本列**（`in`/`value` 之类）时需要的正是「tonumber + 非有限拒绝、非法
-- 返回 nil」这一档语义——用 `or` 兜不住 NaN（NaN 是 truthy），而 num_or 的
-- 回落缺省语义对样本列并不合适（2026-09-20 评估：Ema/Kalman 的输入样本）。
function finite_of(v)
	if bus ~= nil then return bus.finite_of(v) end
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
	return n
end

-- 数值列 → 钳到 [lo, hi] 的整数；非法（非数字/非有限）/占位符 '-' 归缺省 def
-- 全仓 4 份逐字相同的内联实现（VL53L0X / VL53L4CD / AS7262 / AS3935）收敛于此。
-- 注意这是**钳制**语义（就近取边界），与「越界报 ERR」不同：后者由各驱动
-- 显式校验（如 APDS9900 的 atime 范围、MS5611 的 OSR 档位）承担。
-- NaN/inf 必须回落 def 而非参与钳制：NaN 与任何数比较都为 false，会原样穿
-- 出去当数值用（2026-09-20 审计 C2）。
function int_or(v, def, lo, hi)
	local n = finite_of(v)
	if n == nil then return def end
	n = math.floor(n)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

-- 数值列 → tonumber 结果；缺省/非法（含非有限）回落 def（不钳制、不取整）
-- 原 ADS1015 / ADS1115 / ADS1256 各自的 tonum 局部量（逐字相同）
-- 注意 `tonumber(v) or def` 挡不住 NaN（NaN 是 truthy），故经 finite_of。
function num_or(v, def)
	if v == nil then return def end
	local n = finite_of(v)
	if n == nil then return def end
	return n
end

-- ---- 分块读寄存器块（N-24）------------------------------------------------

-- 读 reg 起 n 字节，返回 1-based 大端字节表（[1] 为最高位）；任一读失败返回 nil。
-- 必须分块：HAL 的合并读把整块拼成一个 double，超过 6 字节即超 2^53 精度
-- （见 lib/hal/i2c.lua 的 i2c_read_multi 注释），故 chunk 缺省 6；需要更小事务
-- 的驱动显式传参（BME280 校准块传 4）。尾部不足一块时按剩余长度读。
-- 原 BME688 / BME280 各自的 read_block 局部量（骨架相同，仅 chunk 不同）
function read_block_bytes(fd, reg, n, chunk)
	chunk = chunk or 6
	local out = {}
	local done = 0
	while done < n do
		local len = math.min(chunk, n - done)
		local v = i2c_read_multi(fd, reg + done, len)
		if v < 0 then return nil end
		for i = 0, len - 1 do
			out[done + i + 1] = math.floor(v / 256 ^ (len - 1 - i)) % 256
		end
		done = done + len
	end
	return out
end

-- ---- 声明式驱动框架（P2 驱动代码生成·方案 A，2026-09-30）-----------------
-- 收敛 57 份驱动文件里重复的四段样板：
--   ① 标准前导（mpath 解析 + HAL/print_table/drv_common dofile）~5 行 × 57
--   ② arg_table 守卫（build/call/destroy 各一份，3 行 × 3 × 57）
--   ③ 总线校验（i2c_pair / tonumber(fd)×2 / fd+uart 三族，2~4 行 × 2 × 57）
--   ④ 空 destroy（~40 份驱动 5 行 return {result="OK"}）
-- 驱动文件现在只需：
--   local require_driver = require_driver   -- 已随 drv_common 注入全局
--   require_driver("i2c", {
--       name = "BME280",
--       build = function(ctx, data) ... end,
--       call  = function(ctx, data) ... end,
--       -- destroy 缺省 = 空操作（覆盖多数驱动）；需要收尾动作的驱动显式给
--   })
--   -- 虚拟器件模型（*_VIRT）照常写在文件尾部，框架不动它
--
-- 契约（与旧手写驱动逐字等价，保证测试零改动）：
--   · 包装 build/call 先 arg_table → 再总线校验 → 再调用户函数
--   · 用户函数接收 ctx 表：{fd, addr(仅 i2c), state, name}
--     —— ctx.state 是 spec.state 透传（模块级跨 call 状态的容器）
--   · 错误文案与旧内联版本一致（"Invalid Argument: fd or address" 等），
--     旧测试断言文案不变
--   · 用户函数返回值即驱动返回值（{result="OK",...} 或 err(...)）
--   · 用户函数内可继续用 i2c_read_reg/spi_write/uart_read 等 HAL 全局，
--     以及驱动文件内的 local（bitc/模块级状态/辅助函数）—— 闭包链不变
--
-- 为什么 dofile 前导放框架内：驱动文件不再写 5 行前导，省下的不止是键击
-- ——新驱动作者漏 dofile drv_common 是过去半年的高频新手坑（err() 找不到、
-- i2c_pair 找不到），把前导收进框架后此坑从根上消失。dofile 在 lua 里天然
-- 幂等（HAL/print_table/drv_common 都带 __..._LOADED 守卫），多次加载安全。
function require_driver(bus, spec)
	if type(spec) ~= "table" then
		error("require_driver: spec must be a table", 2)
	end

	-- ① 标准前导剩余部分（dofile 幂等，多驱动状态机内重复加载安全）
	-- 驱动文件调 require_driver 之前须先 dofile drv_common（1 行 prelude，
	-- 本库自带 require_driver 定义，无法绕过——函数不存在时无从调用）。
	-- HAL + print_table 由这里代劳；新驱动作者漏加载是过去高频新手坑，
	-- 5 行前导 → 1 行，且漏加载的后果从「静默崩溃」变成「require_driver
	-- 未定义」的明确报错。
	-- 2026-10-01 审计收口：mpath 引导从「只取首段的单段 match」改为与
	-- virt_prepare（fix-plan 3-3）/HAL.lua 同规的逐段探测——首段没有
	-- mpath.lua 的多路径布局下加载必失败；旧形态正是 run_all.sh 的
	-- lint-module-path-bootstrap 门要拦的已知坏形态。
	local mp = __mpath
	if mp == nil then
		local probed
		for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
			local ok, m = pcall(dofile, p .. "/lib/mpath.lua")
			if ok and type(m) == "table" then probed = m break end
		end
		mp = probed or dofile("./modules/lib/mpath.lua")
	end
	dofile(mp.resolve("lib/HAL.lua"))
	dofile(mp.resolve("lib/print_table.lua"))

	-- ② 总线校验分派（三族文案与旧驱动内联版本逐字对齐）
	-- 统一返回 (fd, addr, err)：成功 = (fd, addr_or_nil, nil)；失败 = (nil, nil, err表)
	-- addr 仅 i2c 非 nil；spi/uart 失败路径也返回三值，避免调用方解包错位
	local i2c_default_addr = spec.i2c_addr_default
	local validators = {
		i2c = function(d)
			-- 缺省地址器件（如 AMG8833 硬件固定 0x69）：address 列可省
			if i2c_default_addr ~= nil and tonumber(d.address) == nil then
				local fd = tonumber(d.fd)
				if fd == nil then
					return nil, nil, err("Invalid Argument: fd or address")
				end
				if not i2c_set_addr(fd, i2c_default_addr) then
					return nil, nil, err("Invalid Argument: fd or address (set_addr failed)")
				end
				return fd, i2c_default_addr, nil
			end
			local fd, addr, ek = i2c_pair(d)
			if fd == nil then return nil, nil, ek end
			return fd, addr, nil
		end,
		spi = function(d)
			local fd = tonumber(d.fd)
			if fd == nil then
				return nil, nil, err("Invalid Argument: fd")
			end
			return fd, nil, nil
		end,
		uart = function(d)
			-- fd 0 合法（HAL 约定 >= 0 即成功）；与 MHZ19/SCSCL 旧口径一致
			local fd = tonumber(d.fd)
			if fd == nil or fd < 0 then
				return nil, nil, err("Invalid Argument: fd (does the UART column reference an @UART variable?)")
			end
			return fd, nil, nil
		end,
	}
	local validate = validators[bus]
	if validate == nil then
		error("require_driver: unknown bus type: " .. tostring(bus), 2)
	end

	-- ③ 用户必须提供 build/call（destroy 可缺省 = 空操作）
	if type(spec.build) ~= "function" or type(spec.call) ~= "function" then
		error("require_driver: spec.build and spec.call are required", 2)
	end

	local user_build  = spec.build
	local user_call   = spec.call
	local user_destroy = spec.destroy
	local state = spec.state or {}
	local name  = spec.name or "unknown"

	-- ④ 包装 build：arg_table → 总线校验 → 用户 build(ctx, data)
	function build(data)
		local ok, ek = arg_table(data)
		if not ok then return ek end
		local fd, addr, ek2 = validate(data)
		if fd == nil then return ek2 end
		return user_build({
			fd = fd, addr = addr, state = state, name = name,
		}, data)
	end

	-- ⑤ 包装 call：同上
	function call(data)
		local ok, ek = arg_table(data)
		if not ok then return ek end
		local fd, addr, ek2 = validate(data)
		if fd == nil then return ek2 end
		return user_call({
			fd = fd, addr = addr, state = state, name = name,
		}, data)
	end

	-- ⑥ 包装 destroy：缺省即空操作（覆盖 ~40 份驱动）；自定义版本仍走 arg_table
	if user_destroy then
		function destroy(data)
			local ok, ek = arg_table(data)
			if not ok then return ek end
			return user_destroy({
				state = state, name = name,
			}, data)
		end
	else
		function destroy(data)
			local ok, ek = arg_table(data)
			if not ok then return ek end
			return { result = "OK" }
		end
	end

	return spec
end