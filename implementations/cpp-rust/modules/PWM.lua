-- PWM 硬件脉宽调制 驱动模块
-- bot4cj 仓颉语言机器人框架
--
-- 波形由 SoC（Pi 5 为 RP1）的 PWM 控制器产生，Lua 侧只写 sysfs 属性
-- （period / duty_cycle / enable），不掉 CPU、不抖动——本框架不做软件
-- bit-bang PWM：那会阻塞动作播放或在守护线程里耗尽 worker 池（见 README）。
--
-- 用途：LED 调光、直流电机调速（L298N 等驱动板的 EN 脚）等。
-- 舵机请走 PCA9685（50Hz 多路），不要用本模块。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE PWM (
--       name      String,
--       chip      String,
--       channel   String,
--       frequency String,
--       duty      String,
--       invert    String
--   );
--   INSERT INTO PWM (name, chip, channel, frequency, duty, invert)
--     VALUES ('pwm0', '0', '1', '20000', '0', '-');
-- chip      pwmchip 编号（CM0/Pi Zero 2 W 通常 0；Pi 5 需 gpiodetect 确认）
-- channel   控制器通道号，只能是 0 或 1（chip=0 时：0=PWM0，1=PWM1）
--           ⚠️ 不是 GPIO 引脚号！填 17 之类的引脚号会直接报越界。
--           引脚由 config.txt 的 dtoverlay 决定，见下方【引脚在哪里选】
-- frequency 载波频率 Hz（可选，缺省 1000）：电机 10k~20k，LED 1k 上下
-- duty      上电占空比 0~100（可选）——给了才在 build 期使能输出，
--           不给（'-'）则只配频率、保持关闭，等第一帧 call 再输出
-- invert    '1' = 输出反相（低电平有效的驱动板）；缺省 normal
--
-- call 参数：duty（0~100，优先）；也接受 value 作别名（与 GPIO 的列风格一致）；
--           frequency 可逐帧改频率；两者都省略时沿用上一次配置。
-- 返回 { result, frequency, duty, period_ns, duty_ns, enabled }
--
-- 【引脚在哪里选】sysfs 没有"选引脚"这个属性——引脚由设备树静态绑定：
--   在 /boot/firmware/config.txt 里配 dtoverlay 参数，**重启生效**。
--   BCM2710（CM0 / Pi Zero 2 W / Pi 3）的合法组合：
--     PWM0: GPIO12(func=4) GPIO18(func=2) GPIO40(func=4) GPIO52(func=5)
--     PWM1: GPIO13(func=4) GPIO19(func=2) GPIO41(func=4) GPIO45(func=4) GPIO53(func=5)
--   例：dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4
--       → channel 0 走 GPIO12，channel 1 走 GPIO13
--   验证：raspi-gpio get <pin> 应显示 ALT0/ALT5 而非 INPUT/OUTPUT。
--   注意：export 成功 ≠ 有物理输出。overlay 没给该通道配脚时，
--   period/duty 照样写得进去，但引脚仍是普通 GPIO，外面量不到波形。
--
-- 注意：
--   - 同一引脚不能既被 gpiod 请求又被配成 PWM（功能复用互斥，二选一）
--   - 取消导出后引脚回到未配置状态，停机后的电平要靠硬件上下拉兜底
--   - 需要 root 或 pwm 组权限才能写 /sys/class/pwm（export/unexport 默认仅 root）

-- 标准前导：HAL/print_table/drv_common 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 模块级状态：每个硬件变量持有独立 lua_State，故此状态天然按实例隔离
local chip, channel = nil, nil
local exported = false
local enabled = false
local cur_freq, cur_duty = 0, 0


-- 【配置脚本】导出通道、设极性、配置初始频率与占空比
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- PWM builder func get a table --------", data)

	-----------------------------------------------------
	-- chip：0 是合法值，故只判缺失/非数值，不能像 GPIO 那样用 "0" 当哨兵
	-- 26.3：finite_of 而非 tonumber——与同一 build 函数里的 frequency/duty（下面
	-- 两处均 finite_of）口径一致，这是本函数仅剩的两列裸 tonumber。非有限值过
	-- tonumber 出的是 number（`== nil` 为假），会一路走到 pwm_export；真机上被
	-- hal/pwm.lua 的 pwm_id 兜住（`n ~= math.floor(n)` 命中 NaN、65535 上界命中
	-- inf）返回 false，于是报「Failed to export PWM pwmchipnan pwmnan」——听着像
	-- sysfs/内核出了问题，实际是配置列写了非数值。提前拦下让错误指名本列。
	local c = finite_of(data.chip)
	if c == nil then
		return err("Invalid Argument: chip (pwmchip number, e.g. 0)")
	end
	-- channel：必填，勿写 '-'（占位符会被跳过或继承上一行，静默用错通道）
	local h = finite_of(data.channel)
	if h == nil then
		return err("Invalid Argument: channel (must not be '-')")
	end

	-- frequency：可选，缺省 1000Hz
	-- 审计 2026-09-20（中）：非有限值必须拒绝——`freq <= 0` 对 NaN/inf 恒假，
	-- inf 会让 pwm_config 算出 period_ns=1（1ns 周期）并写进 sysfs 成功返回。
	local freq = finite_of(data.frequency)
	if freq == nil then freq = 1000 end
	if freq <= 0 then
		return err("Invalid Argument: frequency (must be > 0)")
	end

	-- duty：可选；未给则不上电输出（只配频率，等首帧 call）
	local duty = finite_of(data.duty)
	if duty == nil then duty = 0 end
	if duty < 0 or duty > 100 then
		return err("Invalid Argument: duty (expect 0~100)")
	end

	-----------------------------------------------------
	-- 重复 build 先撤销先前导出的通道（与 I2C/GPIO/SPI/UART 的重复 build
	-- 守卫一致；否则换 chip/channel 再 build 会残留占用旧通道）
	if exported then
		pwm_unexport(chip, channel)
		exported = false
	end

	if not pwm_export(c, h) then
		return err("Failed to export PWM pwmchip" .. tostring(c) .. " pwm" .. tostring(h))
	end
	exported = true
	chip, channel = c, h

	-- 极性：低电平有效的驱动板配 invert='1'
	if tostring(data.invert) == "1" then
		if not pwm_set_polarity(c, h, true) then
			pwm_unexport(c, h)
			exported = false
			return err("Failed to set PWM polarity")
		end
	end

	local cfg_ok, period_ns, duty_ns = pwm_config(c, h, freq, duty)
	if not cfg_ok then
		-- 资源回滚：导出成功但配置失败，撤销导出（避免残留占用通道）
		pwm_unexport(c, h)
		exported = false
		return err("Failed to configure PWM (chip=" .. tostring(c) ..
			" channel=" .. tostring(h) .. " freq=" .. tostring(freq) .. ")")
	end
	cur_freq, cur_duty = freq, duty

	-- 仅当显式给了 duty 才在 build 期使能——与 GPIO 的 init 语义一致，
	-- 未给 duty 时不会意外驱动负载
	-- 26.3：判据用 finite_of 而非 tonumber——'nan'/'1e400' 过 tonumber 出的是
	-- number（Lua 里 truthy），`~= nil` 恒真，于是上面取值处刚把非有限值归成 0、
	-- 这里却又认定「用户给了 duty」而主动使能输出，同文件对同一列两种口径。
	-- 与本文件 build/call 两处取值（均 finite_of）对齐后，非有限值一律按
	-- 「未给 duty」处理：只配频率、不上电输出。
	local has_duty = (finite_of(data.duty) ~= nil)
	if has_duty and not pwm_enable(c, h, true) then
		pwm_unexport(c, h)
		exported = false
		return err("Failed to enable PWM output")
	end
	enabled = has_duty

	-- %s 而非 %d：chip/channel 经 tonumber 后可能是浮点（如 '0.0'），
	-- 直接给 %d 在 LuaJIT 下会抛 "no integer representation"
	print(string.format("PWM init OK: pwmchip%s pwm%s, %gHz duty=%.1f%%%s%s",
		tostring(c), tostring(h), freq, duty,
		tostring(data.invert) == "1" and " (inversed)" or "",
		enabled and "" or " (output idle until first call)"))

	return {
		result    = "OK",
		frequency = freq,
		duty      = duty,
		period_ns = period_ns,
		duty_ns   = duty_ns,
		enabled   = enabled
	}

end


-- 【销毁PWM】关闭输出并取消导出（释放通道占用）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- PWM ender func get a table --------", data)

	if not exported then
		return {  result = "OK",  released = false  }
	end

	local ok_un = pwm_unexport(chip, channel)
	exported, enabled = false, false

	if not ok_un then
		return err("Failed to unexport PWM channel")
	end

	return {  result = "OK",  released = true  }

end


-- 【调用PWM】设置占空比（可同时改频率）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- PWM caller func get a table --------", data)

	if not exported then
		return err("PWM not initialized (build first)")
	end

	-----------------------------------------------------
	-- duty 优先，其次 value（别名，便于 .mt 里写 pwm0.value），
	-- 都没有则沿用上一次配置（controller 转发场景可能不带 duty）
	-- 审计 2026-09-20（中）：call 路径与 build 同款——非有限值必须拒绝，
	-- 否则 pwm_config 的 `d < 0 or d > 100` 对 NaN 恒假、inf 亦放行。
	local duty = finite_of(data.duty)
	if duty == nil then duty = finite_of(data.value) end
	if duty == nil then duty = cur_duty end
	if duty < 0 or duty > 100 then
		return err("Invalid Argument: duty (expect 0~100, got " .. tostring(duty) .. ")")
	end

	local freq = finite_of(data.frequency)
	if freq == nil then freq = cur_freq end
	if freq <= 0 then
		return err("Invalid Argument: frequency (must be > 0)")
	end

	-----------------------------------------------------
	local cfg_ok, period_ns, duty_ns = pwm_config(chip, channel, freq, duty)
	if not cfg_ok then
		return err("Failed to configure PWM")
	end
	cur_freq, cur_duty = freq, duty

	if not enabled then
		if not pwm_enable(chip, channel, true) then
			return err("Failed to enable PWM output")
		end
		enabled = true
	end

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("PWM: pwmchip%s pwm%s %gHz duty=%.1f%% (%s/%s ns)",
			tostring(chip), tostring(channel), freq, duty,
			tostring(duty_ns), tostring(period_ns)))
	end

	return {
		result    = "OK",
		frequency = freq,
		duty      = duty,
		period_ns = period_ns,
		duty_ns   = duty_ns,
		enabled   = enabled
	}

end
