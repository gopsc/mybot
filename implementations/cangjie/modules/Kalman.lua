local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/drv_common.lua"))
-- Kalman.lua - 一维卡尔曼滤波硬件变量驱动（方式 A）
-- bot4cj 仓颉语言机器人框架
--
-- 矩阵名 Kalman → 本文件（通用 Lua 硬件变量）。引用一个源变量（@Daemon 守护或传感器）
-- 取其采样值，逐拍滤波；输出既作 out、也别名 v0——使本变量成为「虚拟传感器」，
-- 下游消费者按 v0 读取即可，与守护输出统一。
--
-- 滤波器实例存模块级 local，状态跨 call 保持（本硬件变量的 lua_State 独占、贯穿始终）。
--
-- @Kalman 矩阵列：
--   name   变量名
--   Q      系统噪声协方差（默认 20；越大越信任测量）
--   R      测量噪声协方差（默认 200；越大越信任模型）
--   src    引用的源变量名（守护/传感器）——经引用机制其 v0.. 流入本变量元数据
--   field  可选，滤哪个字段（默认 v0）
--
-- 两种喂数方式：
--   1) src 引用源变量：call 读 data[field]（默认 data.v0，来自被引用守护）
--   2) @Action 直接传：以 <name>.in 列传入待滤值，call 优先读 data.in

local KalmanLib = dofile(mpath.resolve("lib/kalman.lua"))

local kf = nil			-- 滤波器实例（build 创建，跨 call 保持状态）
local field = "v0"		-- 待滤字段名（可由 field 列配置）
local last = nil			-- 最近一次 call 输出快照（read 用，P4/M1）

function build(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	local Q = tonumber(data.Q) or 20
	local R = tonumber(data.R) or 200
	if data.field ~= nil and data.field ~= "" then field = data.field end
	-- lib/kalman.lua 对 Q<0 / R<=0 直接 error——pcall 转成 ERR 契约，
	-- 非法配置不得以裸 Lua 异常逃出 build（与 Ema.lua 的 pcall 一致）
	local ok_new, kf_new = pcall(KalmanLib.new, Q, R)
	if not ok_new then
		return { result = "ERR", message = "Invalid Kalman Q/R: " .. tostring(kf_new) }
	end
	kf = kf_new
	return { result = "OK", Q = Q, R = R, field = field }
end

function call(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	if kf == nil then
		return { result = "ERR", message = "Kalman not built" }
	end

	-- 输入优先级：@Action 直接传入的 in > 引用源的 field 字段
	-- （注意 in 是 Lua 关键字，须用 data["in"] 而非 data.in）
	local raw = tonumber(data["in"])
	if raw == nil then raw = tonumber(data[field]) end
	if raw == nil then
		return { result = "ERR", message = "no input value (field=" .. tostring(field) .. ")" }
	end

	local out = kf:filter(raw)
	-- out 为滤波结果；同时别名 v0，使本变量可被当作「虚拟传感器」按 v0 消费
	last = { result = "OK", out = out, v0 = out, raw = raw }
	return last
end

-- P4/M1：引用语义 = 无副作用读快照（不推进滤波状态）
function read(data)
	if last == nil then
		return { result = "ERR", message = "no sample yet" }
	end
	return last
end

function destroy(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	kf = nil
	return { result = "OK" }
end
