-- hal/pwm.lua —— HAL 的 PWM 域（Linux sysfs）
-- bot4cj 仓颉语言机器人框架
--
-- 本文件是 modules/lib/HAL.lua 的**分块**，不是可独立加载的模块：由门面按序
-- loadfile 后以 ctx 表传入共享上下文（见门面「各总线域加载」段）。
-- 正文自 HAL.lua 逐字搬迁（26.2 按域拆分），注释与错误文案未改写。
local ctx = assert(..., "hal/pwm.lua 须由 modules/lib/HAL.lua 聚合加载（不支持单独 dofile）")
local HAL, ffi, bus = ctx.HAL, ctx.ffi, ctx.bus

------------------------------------------------------------------
-- PWM（Linux sysfs：/sys/class/pwm/pwmchipN/pwmM）
------------------------------------------------------------------
-- 波形由 SoC（Pi 5 为 RP1）的 PWM 控制器自行产生，Lua 侧只写
-- period / duty_cycle / enable 三个属性——无 CPU 占用、无软件抖动。
-- 这是本框架唯一可行的 PWM 路径：软件 bit-bang 要么阻塞主线程的动作播放，
-- 要么在守护线程里 ffi usleep 自旋耗尽 schd-worker 池（README 已记死锁）。
--
-- 【为何用 ffi 而不是 io 库】Lua.cj 的 sandbox_lua 中和了 io.open/io.lines，
-- 驱动写不了 sysfs；这里走 HAL.sys.open/write（ffi 直调 libc），
-- 既保持沙箱不变，也与各总线段的写法一致。
--
-- 【sysfs 已 deprecated 但可用】树莓派 OS（Bookworm）默认挂载 /sys/class/pwm；
-- 将来若需多通道原子配置可换 /dev/pwmchip* 的字符设备 uAPI——届时按
-- test/test_ioctl_nums.c 的方法实证 ioctl 编号与结构体尺寸，别硬编码。
--
-- 接口：pwm_exported / pwm_export / pwm_config / pwm_set_polarity /
--       pwm_enable / pwm_unexport
-- chip、channel 必须是非负整数（防路径穿越），其余一律拒绝并打印诊断。
-- 典型：CM0 / Pi Zero 2 W 的 PWM1 复用 GPIO19（ALT5）→ chip=0 channel=1。

-- 平台差异单点见本文件顶部 HAL.platform（pwm_sysfs_root）：下面 pwm_chip_path /
-- pwm_attr_path 直接取 HAL.platform.pwm_sysfs_root，此处**不再**重复赋值
-- ——曾有一行 `HAL.PWM_SYSFS_ROOT = "/sys/class/pwm"` 把它重置回字面量，
-- 使移植/仿真桩改 HAL.platform.pwm_sysfs_root 时静默失效。
HAL.pwm_state = {}			-- "chip/channel" -> {freq, duty, period_ns, duty_ns, enabled}

local O_WRONLY = 1
local O_RDONLY = 0

-- sysfs 写失败几乎总是这两种原因，给出人话提示（errno 已由后端 consts 表重导出）
local function errno_hint(e)
	if e == HAL.ENOENT then
		return "ENOENT(node not found: PWM overlay not enabled, or pwmchip number incorrect?)"
	elseif e == HAL.EACCES then
		return "EACCES(permission denied: export/unexport usually requires root, need udev rule or sudo -E)"
	elseif e == HAL.EINVAL then
		return "EINVAL(parameter rejected by kernel)"
	end
	return "errno=" .. tostring(e)
end

-- 规范化非负整数 id（拒绝负数、小数、"../"、超范围值），非法返回 nil。
-- 上限 65535：既覆盖真实 pwmchip 编号，也避免 tostring 对大数输出科学
-- 计数法（如 1e+15）污染路径。
local function pwm_id(v)
	local n = tonumber(v)
	if n == nil or n < 0 or n > 65535 or n ~= math.floor(n) then return nil end
	return tostring(math.floor(n))
end

-- pwmchip 级属性路径（export / unexport）
local function pwm_chip_path(chip, attr)
	local c = pwm_id(chip)
	if c == nil then
		print("HAL: invalid pwm chip: " .. tostring(chip))
		return nil
	end
	return HAL.platform.pwm_sysfs_root .. "/pwmchip" .. c .. "/" .. attr
end

-- 通道级属性路径（period / duty_cycle / enable / polarity）
local function pwm_attr_path(chip, channel, attr)
	local c, h = pwm_id(chip), pwm_id(channel)
	if c == nil or h == nil then
		print("HAL: invalid pwm chip/channel: " .. tostring(chip) .. "/" .. tostring(channel))
		return nil
	end
	return HAL.platform.pwm_sysfs_root .. "/pwmchip" .. c .. "/pwm" .. h .. "/" .. attr
end

-- 向任意 sysfs 文件写入字符串；成功 true，失败打印路径并 false
local function sysfs_write(path, val)
	if type(path) ~= "string" then return false end
	local fd = tonumber(HAL.sys.open(path, O_WRONLY + HAL.O_CLOEXEC))
	if fd == nil or fd < 0 then
		print("HAL: pwm open failed: " .. path .. " " .. errno_hint(HAL.sys.errno()))
		return false
	end
	local s = tostring(val)
	-- ffi.copy 从 Lua 字符串拷贝（不显式给 len）会连同结尾 NUL 一起拷
	-- （#s+1 字节）；缓冲只开 #s 会固定越界 1 字节、写坏相邻 GC 对象，
	-- 下一次 GC 扫描时段错误（崩溃点与写操作相隔甚远，极难查）。
	-- 缓冲留 1 字节给 NUL；实际写计数仍用 #s，NUL 不发给内核。
	local buf = ffi.new("char[?]", #s + 1)
	ffi.copy(buf, s)
	local n = tonumber(HAL.sys.write(fd, buf, #s))
	HAL.sys.close(fd)
	if n == nil or n < #s then
		print("HAL: pwm write failed: " .. path .. " <- " .. s .. " " .. errno_hint(HAL.sys.errno()))
		return false
	end
	return true
end

-- 读 pwmchip 的通道数（npwm）；读不到返回 nil
-- 通道号必须小于该值，export 越界通道时内核静默不生成目录，
-- 故失败诊断必须带上它（只说"没生效"无法区分越界与权限）。
function pwm_npwm(chip)
	local p = pwm_chip_path(chip, "npwm")
	if p == nil then return nil end
	local fd = tonumber(HAL.sys.open(p, O_RDONLY + HAL.O_CLOEXEC))
	if fd == nil or fd < 0 then return nil end
	local buf = ffi.new("char[16]")
	local n = tonumber(HAL.sys.read(fd, buf, 16))
	HAL.sys.close(fd)
	if n == nil or n <= 0 then return nil end
	return tonumber(ffi.string(buf, n))
end

-- 通道是否已导出（以 enable 属性能否打开为准）
-- 用 O_RDONLY 探测：存在性判断不该受写权限影响——
-- enable 默认 0644 root:root，非 root 用 O_WRONLY 探测会拿到 EACCES 误判为"未导出"
function pwm_exported(chip, channel)
	local path = pwm_attr_path(chip, channel, "enable")
	if path == nil then return false end
	local fd = tonumber(HAL.sys.open(path, O_RDONLY + HAL.O_CLOEXEC))
	if fd == nil or fd < 0 then return false end
	HAL.sys.close(fd)
	return true
end

-- 导出通道；已导出则直接成功（重复 export 会被内核以 EINVAL 拒绝）
function pwm_export(chip, channel)
	if pwm_exported(chip, channel) then return true end
	local p = pwm_chip_path(chip, "export")
	local h = pwm_id(channel)
	if p == nil or h == nil then
		print("HAL: invalid pwm channel: " .. tostring(channel))
		return false
	end
	-- 前置校验：越界通道号内核只回一个 EINVAL，错误信息本身无法自解释。
	-- 最常见的误用是把 channel 当成 GPIO 引脚号填（如 17）——
	-- 引脚由 config.txt 的 dtoverlay 决定，与 channel 无关。
	local n = pwm_npwm(chip)
	if n ~= nil and tonumber(h) >= n then
		print("HAL: pwm channel " .. h .. " out of range on pwmchip" .. tostring(chip) ..
			": this chip only has " .. tostring(n) .. " channel(s) (valid range 0~" .. tostring(n - 1) .. "). " ..
			"channel is the PWM hardware channel number, not a GPIO pin -- pin assignment is controlled by dtoverlay.")
		return false
	end
	if not sysfs_write(p, h) then return false end
	if not pwm_exported(chip, channel) then
		-- 写入成功却没生成目录，最常见是通道号越界（内核静默忽略）
		local n = pwm_npwm(chip)
		if n ~= nil then
			print("HAL: pwm export did not take effect: pwmchip" .. tostring(chip) ..
				" pwm" .. tostring(h) .. " -- this chip only has " .. tostring(n) ..
				" channel(s), channel must be 0~" .. tostring(n - 1) ..
				" (for dual channel use dtoverlay=pwm-2chan and reboot)")
		else
			print("HAL: pwm export did not take effect: pwmchip" .. tostring(chip) ..
				" pwm" .. tostring(h) .. " (cannot read npwm, check /sys/class/pwm mount and permissions)")
		end
		return false
	end
	return true
end

-- 设载波频率与占空比（duty 为百分比 0~100）
-- 返回 (true, period_ns, duty_ns) 或 false
function pwm_config(chip, channel, freq_hz, duty_pct)
	-- 审计 2026-09-20（中）：本函数此前是全文件唯一漏掉非有限值防线的地方——
	-- `f <= 0` 与 `d < 0 or d > 100` 对 NaN/inf 恒假（NaN 比较恒假；inf 满足
	-- `> 0` 且不满足 `> 100` 时 duty 亦然），于是 freq=inf 会算出 period_ns=1
	-- （1ns 周期）并**写进 sysfs 成功返回 true**，freq=nan 更会把字面量 "nan"
	-- 写进 period/duty_cycle（内核 EINVAL，报错成因指向内核而非入参）。
	-- 判据走总线契约单点 bus.finite_of（与 HAL 其余入参一致）。
	local f = bus and bus.finite_of(freq_hz)
	local d = bus and bus.finite_of(duty_pct)
	if f == nil or f <= 0 then
		print("HAL: invalid pwm frequency: " .. tostring(freq_hz))
		return false
	end
	if d == nil or d < 0 or d > 100 then
		print("HAL: invalid pwm duty: " .. tostring(duty_pct) .. " (expect 0~100)")
		return false
	end
	local period_ns = math.floor(1e9 / f + 0.5)
	if period_ns < 1 then period_ns = 1 end
	local duty_ns = math.floor(period_ns * d / 100 + 0.5)
	if duty_ns > period_ns then duty_ns = period_ns end

	-- 写序：内核要求 duty_cycle <= period，故先把 duty 归零再改 period。
	-- 否则「新 period 小于旧 duty」会被内核以 EINVAL 拒绝——降频必踩。
	-- 代价是切换瞬间多一个低电平周期，对电机/LED 无实际影响。
	if not sysfs_write(pwm_attr_path(chip, channel, "duty_cycle"), 0) then return false end
	if not sysfs_write(pwm_attr_path(chip, channel, "period"), period_ns) then return false end
	if not sysfs_write(pwm_attr_path(chip, channel, "duty_cycle"), duty_ns) then return false end

	local key = tostring(pwm_id(chip)) .. "/" .. tostring(pwm_id(channel))
	local st = HAL.pwm_state[key] or {}
	st.freq, st.duty = f, d
	st.period_ns, st.duty_ns = period_ns, duty_ns
	HAL.pwm_state[key] = st
	return true, period_ns, duty_ns
end

-- 极性：inversed = 输出反相（低电平有效的驱动板用）
function pwm_set_polarity(chip, channel, inversed)
	return sysfs_write(pwm_attr_path(chip, channel, "polarity"),
		inversed and "inversed" or "normal")
end

-- 使能 / 关闭输出
function pwm_enable(chip, channel, on)
	local ok = sysfs_write(pwm_attr_path(chip, channel, "enable"), (on and 1 or 0))
	if ok then
		local key = tostring(pwm_id(chip)) .. "/" .. tostring(pwm_id(channel))
		local st = HAL.pwm_state[key] or {}
		st.enabled = on and true or false
		HAL.pwm_state[key] = st
	end
	return ok
end

-- 取消导出（先停输出，避免取消后引脚停在某个电平上继续驱动负载）
function pwm_unexport(chip, channel)
	local p = pwm_chip_path(chip, "unexport")
	local h = pwm_id(channel)
	if p == nil or h == nil then return false end
	pwm_enable(chip, channel, false)
	local ok = sysfs_write(p, h)
	if ok then HAL.pwm_state[tostring(pwm_id(chip)) .. "/" .. tostring(h)] = nil end
	return ok
end
