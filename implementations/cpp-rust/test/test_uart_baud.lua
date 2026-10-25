-- test_uart_baud.lua —— UART 波特率编码适配回归（审计 P0-3）
-- glibc 2.42 起 B* 常量从旧 ABI 编号（B9600=13）改为字面 Hz（B9600=9600），
-- hal/uart.lua 运行时探测 glibc 版本后二选一。本用例核对：
--   ① 探测结果与 gnu_get_libc_version 一致（本机 glibc 下选表正确）；
--   ② 生效映射表键集与 UART_BAUDS 白名单一致（防两表漂移）；
--   ③ 生效表的值域形态（全 Hz 或全旧编号）与所选表吻合。
-- 运行：luajit test/test_uart_baud.lua（无需真机）

local tester = dofile("test/lib/tester.lua")
local ffi = require("ffi")
local HAL = dofile("modules/lib/HAL.lua")

-- 独立重推 glibc 版本（不引用 HAL 内部函数，避免同义反复式假绿）。
-- 非 glibc（musl）无此符号：pcall 取符号，期望 HAL 选旧编号表（musl 的 B* 即
-- Linux ABI 旧编号，test_uart_consts 在 alpine 下已实证）。
pcall(ffi.cdef, [[ const char* gnu_get_libc_version(void); ]])
local has_sym, p = pcall(function() return ffi.C.gnu_get_libc_version() end)
local ver = (has_sym and p ~= nil) and ffi.string(p) or ""
local major, minor = string.match(ver, "(%d+)%.(%d+)")
local useHz = major ~= nil and (tonumber(major) * 1000 + tonumber(minor)) >= 2042

if has_sym then
	tester.check("gnu_get_libc_version 可解析: " .. ver, major ~= nil, ver)
else
	tester.check("非 glibc（无 gnu_get_libc_version）→ HAL.sys.version() 须返 nil 而非抛错",
		HAL.sys.version() == nil)
end
tester.check("HAL.UART_B_CONST 已导出", type(HAL.UART_B_CONST) == "table")

-- UART_BAUDS 白名单（与 hal/uart.lua 同步维护）
local BAUDS = { 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
	230400, 460800, 500000, 921600, 1000000 }

-- ② 键集与白名单一致：白名单每个波特率都有映射，且无多余键
local keys = 0
for _ in pairs(HAL.UART_B_CONST) do keys = keys + 1 end
tester.check("映射表键数与白名单一致 (13)", keys == #BAUDS, "got " .. keys)
local missing = {}
for _, b in ipairs(BAUDS) do
	if HAL.UART_B_CONST[b] == nil then missing[#missing + 1] = b end
end
tester.check("白名单每个波特率都有映射", #missing == 0, table.concat(missing, ","))

-- ③ 所选表形态与 glibc 版本判定一致
local expect_hz = useHz
local allHz, allLegacy = true, true
for _, b in ipairs(BAUDS) do
	local v = HAL.UART_B_CONST[b]
	if v ~= b then allHz = false end
	if v == b then allLegacy = false end
end
if useHz then
	tester.check("glibc >= 2.42: 生效表为字面 Hz 表", allHz, "表中存在与 Hz 不等的值")
else
	tester.check("glibc < 2.42: 生效表为旧 ABI 编号表", allLegacy, "表中存在与 Hz 相等的值")
end

tester.summary("uart_baud")
