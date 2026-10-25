-- test/lib/tester.lua — 共享离线测试框架
-- 用法：从项目根目录 dofile("test/lib/tester.lua")，返回 tester 表。
-- 幂等：同一进程内重复 dofile 返回既有实例（不重复计数）。
-- 兼容 run_all.sh 约定：每条断言打印 [PASS]/[FAIL] 行，失败时 summary() os.exit(1)。
--
-- API：
--   check(label, cond[, detail])            单条断言
--   expect_ok(label, fn)                    期望 fn 不抛且返回 {result="OK"}；返回 res
--   expect_err(label, fn, msgpat)           期望返回 {result="ERR"} 且 message 含 msgpat（纯文本匹配）
--   expect_cmds(label, log, expect[, field])命令序列断言：log[i][field]，field 默认 "cmd"
--   summary([tag])                         打印汇总，有失败则 os.exit(1)

if tester ~= nil then return tester end
local tester = { passed = 0, failed = 0, failed_labels = {} }

local function check(label, cond, detail)
	if cond then
		tester.passed = tester.passed + 1
		print("[PASS] " .. label)
	else
		tester.failed = tester.failed + 1
		tester.failed_labels[#tester.failed_labels + 1] = label
		print("[FAIL] " .. label .. (detail ~= nil and ("  | " .. tostring(detail)) or ""))
	end
end

local function result_of(ok, res)
	if ok and type(res) == "table" then return tostring(res.result) end
	return "EXC:" .. tostring(res)
end

local function expect_ok(label, fn)
	local ok, res = pcall(fn)
	check(label, result_of(ok, res) == "OK", result_of(ok, res))
	return ok and res or nil
end

local function expect_err(label, fn, msgpat)
	local ok, res = pcall(fn)
	local msg = type(res) == "table" and tostring(res.message) or tostring(res)
	check(label, result_of(ok, res) == "ERR" and msg:find(msgpat, 1, true) ~= nil, msg)
end

local function expect_cmds(label, log, expect, field)
	local f = field or "cmd"
	local got = {}
	for _, w in ipairs(log or {}) do got[#got + 1] = w[f] end
	local same = #got == #expect
	for i = 1, #expect do
		if same and (got[i] or -1) ~= expect[i] then same = false end
	end
	check(label, same, table.concat(got, ",") .. " expect " .. table.concat(expect, ","))
end

local function summary(tag)
	print(string.format("%s: %d 通过, %d 失败",
		tag or "结果", tester.passed, tester.failed))
	if tester.failed > 0 then
		print("失败用例:")
		for _, l in ipairs(tester.failed_labels) do print("  - " .. l) end
	end
	-- 完成标记（P0-2 假绿治理）：run_all.sh 以「未见 [DONE] 或 [PASS] 计数为 0」
	-- 识别早退/守卫短路/零断言文件——summary 跑到头必须留痕，须先于 os.exit 打印
	print("[DONE] " .. tostring(tag or ""))
	if tester.failed > 0 then
		os.exit(1)
	end
end

tester.check, tester.result_of = check, result_of
tester.expect_ok, tester.expect_err = expect_ok, expect_err
tester.expect_cmds = expect_cmds
tester.summary = summary
rawset(_G, "tester", tester)
return tester