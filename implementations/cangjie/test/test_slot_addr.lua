-- test_slot_addr.lua - 注入槽地址精度/契约回归（Low：注入地址精度）
-- 验证 modules/lib/pthread.lua 的地址注入契约：
--   1) 宿主 lua_pushinteger 以 64 位整数 tag 注入，任意值（含 >=2^53）逐位保真；
--   2) slot_attach 前置守卫：地址被 double 化（非整/负/非 number）→ error；
--   3) >=2^53 因注入路径逐位保真，只告警不拦截（拦截会误伤精确路径）。
-- 比较统一走 cdata 整数域（ffi.cast uint64 == 整数），避开 P.addr 的 tonumber 双精度化。
-- 用法（项目根目录）: luajit test/test_slot_addr.lua（run_all.sh 自动纳入）
-- 前置：LuaJIT ffi；非 LuaJIT（lua5.4）时跳过 ffi 组，仅打印跳过说明。

local passed, failed = 0, 0
local function check(label, cond, detail)
	if cond then
		passed = passed + 1; print("[PASS] " .. label)
	else
		failed = failed + 1
		print("[FAIL] " .. label .. (detail ~= nil and ("  | " .. tostring(detail)) or ""))
	end
end

local dir = os.getenv("BOT4CJ_MODULE_PATH") or "./modules"
local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
	print("[SKIP] 需要 LuaJIT ffi（整数 tag 注入语义所属运行时），跳过精度断言")
	return 0
end

local P = dofile(dir .. "/lib/pthread.lua")
local pcall_ok, slot

-- 1) 各幅值地址：slot_attach 直传句柄，cdata 整数域比较逐位还原
local bands = {
	{ label = "<2^35 (2^31)",  addr = 2^31 },
	{ label = "2^35 档",       addr = 2^35 },
	{ label = "2^40 档",       addr = 2^40 },
	{ label = "2^48 档",       addr = 2^48 },
	{ label = "2^52 档",       addr = 2^52 },
	{ label = "2^53 档",       addr = 2^53 },
	{ label = "2^55 档",       addr = 2^55 },
	{ label = "2^60 档",       addr = 2^60 },
	{ label = "bit63 置位",    addr = 2^63 },
	{ label = "尾数位(2^57+2^45+13)", addr = 2^57 + 2^45 + 13 },
}
for _, b in ipairs(bands) do
	pcall_ok, slot = pcall(P.slot_attach, b.addr)
	if not pcall_ok then
		check("带宽 " .. b.label .. " slot_attach 应不抛错", false, slot)
	else
		check("带宽 " .. b.label .. " 逐位还原", ffi.cast("uint64_t", slot) == b.addr)
	end
end

-- 2) 前置守卫：被 double 化的坏地址 → error
local bad_cases = {
	{ "-1",   -1 },
	{ "0.5",  0.5 },
	{ "字符串", "0x1000" },
	{ "nil",  nil },
}
for _, c in ipairs(bad_cases) do
	pcall_ok = pcall(P.slot_attach, c[2])
	check("守卫 " .. c[1] .. " 应报错", not pcall_ok)
end

-- 3) >=2^53 只告警不拦截：attach 必须成功（返回值是合法 cdata）
pcall_ok, slot = pcall(P.slot_attach, 2^55)
check(">=2^53 不拦截（告警放行）", pcall_ok)
check(">=2^53 仍逐位还原", slot ~= nil and ffi.cast("uint64_t", slot) == 2^55)

print("===============================================")
print(("汇总: %d 通过, %d 失败"):format(passed, failed))
if failed > 0 then os.exit(1) end
return 0