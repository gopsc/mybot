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

-- 加载纯 Lua 基层硬件抽象层（HAL）
-- 调试打印辅助 print_table、驱动公共样板 drv_common（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
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
	local c = tonumber(data.chip)
	if c == nil then
		return err("Invalid Argument: chip (pwmchip number, e.g. 0)")
	end
	-- channel：必填，勿写 '-'（占位符会被跳过或继承上一行，静默用错通道）
	local h = tonumber(data.channel)
	if h == nil then
		return err("Invalid Argument: channel (must not be '-')")
	end

	-- frequency：可选，缺省 1000Hz
	local freq = tonumber(data.frequency)
	if freq == nil then freq = 1000 end
	if freq <= 0 then
		return err("Invalid Argument: frequency (must be > 0)")
	end

	-- duty：可选；未给则不上电输出（只配频率，等首帧 call）
	local duty = tonumber(data.duty)
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
	local has_duty = (tonumber(data.duty) ~= nil)
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
	local duty = tonumber(data.duty)
	if duty == nil then duty = tonumber(data.value) end
	if duty == nil then duty = cur_duty end
	if duty < 0 or duty > 100 then
		return err("Invalid Argument: duty (expect 0~100, got " .. tostring(duty) .. ")")
	end

	local freq = tonumber(data.frequency)
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
