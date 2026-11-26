-- mpath.lua —— 多模块路径解析（issue #19）
-- BOT4CJ_MODULE_PATH 支持用 ':' 分隔多个路径，按序查找驱动文件与共享库；
-- 未设置时保持默认 "./modules"，单路径用法完全向后兼容。
--
-- 沙箱说明：Lua.cj sandbox_lua 禁用了 io.open（及 os.execute/remove/rename），
-- 故存在性探测统一用 loadfile（仅编译不执行，无副作用；与 dofile 同受
-- package.path 无关，直接按路径探测）。驱动后续 dofile(mpath.resolve(rel))
-- 与原先 dofile(路径拼接) 的执行语义一致。
local mpath = {}

-- 返回路径列表：按 ':' 拆分，去空去重保持顺序；空结果回退默认 "./modules"
-- env 参数仅供测试直传注入；生产调用不传，读取 BOT4CJ_MODULE_PATH。
function mpath.paths(env)
	local raw = env or os.getenv("BOT4CJ_MODULE_PATH") or "./modules"
	local out, seen = {}, {}
	for p in raw:gmatch("[^:]+") do
		if not seen[p] then
			out[#out + 1] = p
			seen[p] = true
		end
	end
	if #out == 0 then
		out = { "./modules" }
	end
	return out
end

-- 在多个路径中按序查找 rel（相对模块根的路径，如 "lib/HAL.lua"），
-- 返回第一个存在文件的完整路径；全部不存在时返回最后一个路径拼接，
-- 保持原有"文件不存在"的加载报错语义（路径可诊断、行为可预期）。
function mpath.resolve(rel, env)
	local ps = mpath.paths(env)
	local last = ps[#ps] .. "/" .. rel
	for _, p in ipairs(ps) do
		local cand = p .. "/" .. rel
		if loadfile(cand) then
			return cand
		end
		last = cand
	end
	return last
end

-- 便捷封装：多路径解析后 dofile（等价原 dofile(拼接) 的执行语义）
function mpath.dofile(rel, env)
	return dofile(mpath.resolve(rel, env))
end

return mpath
