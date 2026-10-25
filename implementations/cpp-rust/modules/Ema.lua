local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
-- Ema.lua - 指数移动平均滤波硬件变量驱动
-- bot4cj 仓颉语言机器人框架
--
-- 矩阵名 Ema → 本文件（通用 Lua 硬件变量）。与 Kalman.lua 同构：src 列引用守护/传感器，
-- call 逐拍做 EMA 平滑，输出既作 out 也别名 v0（「虚拟传感器」，下游按 v0 统一消费）。
-- 滤波器实例存模块级 local，状态跨 call 保持（本变量 lua_State 独占）。
--
-- @Ema 矩阵列：
--   name   变量名
--   alpha  平滑系数 (0,1]（默认 0.2；越小越平滑、滞后越大）
--   src    引用的源变量名（守护/传感器）——其 v0.. 经引用机制流入本变量元数据
--   field  可选，滤哪个字段（默认 v0）
--   init   可选，初始输出值（缺省用首样本初始化）
--
-- 引用链示例：@Daemon(采样) → @Ema(src=守护) → @Monitor(src=滤波变量)
-- 也可不经 src，直接在 @Action 里以 <name>.in 列喂待滤值。

local EmaLib = dofile(mpath.resolve("lib/ema.lua"))

local f = nil			-- EMA 实例（build 创建，跨 call 保持状态）
local field = "v0"		-- 待滤字段名（可由 field 列配置）
local last = nil			-- 最近一次 call 输出快照（read 用，P4/M1）

function build(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	-- 非有限回落缺省（drv_common 单点）：`tonumber(..) or 0.2` 挡不住 NaN
	-- （NaN 是 truthy），alpha 列写 "nan" 会让整条序列变成 NaN（2026-09-20 评估）
	local alpha = num_or(data.alpha, 0.2)
	if data.field ~= nil and data.field ~= "" then field = data.field end
	local ok, inst = pcall(EmaLib.new, alpha, data.init)
	if not ok then
		return err(tostring(inst))
	end
	f = inst
	return { result = "OK", alpha = alpha, field = field }
end

function call(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	if f == nil then
		return err("Ema not built")
	end
	-- 输入优先级：@Action 直接传入的 in > 引用源的 field 字段（in 是 Lua 关键字，用 ["in"]）
	-- 样本列走 finite_of（非有限即 nil）：`tonumber` 放行 NaN 而库会抛错，
	-- 裸异常逃出 call 不是驱动契约（2026-09-20 评估）
	local raw = finite_of(data["in"])
	if raw == nil then raw = finite_of(data[field]) end
	if raw == nil then
		return err("no input value (field=" .. tostring(field) .. ")")
	end
	local out = f:filter(raw)
	last = { result = "OK", out = out, v0 = out, raw = raw }
	return last
end

-- P4/M1：引用语义 = 无副作用读快照（不推进滤波状态）
function read(data)
	if last == nil then
		return err("no sample yet")
	end
	return last
end

function destroy(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	f = nil
	return { result = "OK" }
end
