-- test_driver_contract.lua — 驱动入口契约 sweep（2026-09-20 重构阶段 4.5）
--
-- 背景：驱动入口的约定此前只有一条 **grep lint**（run_all.sh 的 lint 段断言
-- build/call 里不出现内联 `type(data) ~= "table"`）。grep 只能抓一种写法，
-- 抓不到「漏写 destroy」「build 恒返回非表」「非表入参不返 ERR 契约」等形态；
-- 而 59 个模块是全仓最大的一个「靠约定维系」的面。
--
-- 本 sweep 把约定变成可执行断言：**逐个真的加载**每个 modules/*.lua，然后
--   ① 可加载（顺带守住模块路径引导 —— 阶段 2 的 __mpath 迁移若写错，
--      这一步就会红，无需等到 E2E）；
--   ② 驱动入口三件套 build/call/destroy 均为函数（纯 Lua 库除外，见豁免表）；
--   ③ 非表入参必须返回 {result="ERR", message=...} 的 ERR 契约，而不是抛 Lua
--      error、也不是静默成功（这是 arg_table 的语义出口，跨语言边界上
--      「抛」与「返 ERR」对宿主的处理路径完全不同）。
--
-- 豁免（都在文件头注声明过理由，此处集中列举，避免 grep 式的隐式豁免）：
--   bitcompat  纯 Lua 库：只 return 一个表，无驱动入口
--   Camera     全仓唯一不挂 arg_table 样板的驱动（可选外设，build 不碰设备，
--              入参走内联类型守卫；见 modules/Camera.lua 头注与 run_all.sh lint 段）
--
-- 用法（项目根目录）：luajit test/test_driver_contract.lua（run_all.sh 自动纳入）

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local LIB_ONLY = { bitcompat = true }
local NO_ARG_TABLE = { Camera = true }

-- 枚举模块（测试进程不在驱动沙箱内，io.popen 可用；run_all.sh 亦依赖 coreutils）
local function listModules()
	local out = {}
	local p = io.popen("ls modules/*.lua 2>/dev/null")
	if not p then return out end
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	return out
end

local mods = listModules()
-- 2026-09-25 #8：Lua 协议驱动轨道（LlmOpenAI/DeepSeek/Anthropic）删除后
-- modules/*.lua = 58；此下限防「枚举悄悄失效」（popen 失败/glob 改动），
-- 删除模块驱动文件须同步下调并在此留痕。
check("sweep 枚举到全部 modules/*.lua", #mods >= 58, "枚举到 " .. tostring(#mods))

for _, path in ipairs(mods) do
	local name = path:match("([^/]+)%.lua$") or path
	-- 驱动以全局 build/call/destroy 暴露入口——同一进程里逐个加载时会互相
	-- 继承上一份定义，故每次加载前先清空，断言才真的对应本模块（否则
	-- 「漏写 build」会被上一个驱动掩盖成通过）。
	build, call, destroy = nil, nil, nil
	read = nil		-- 同上：read 也是模块级全局，不清会让「本模块没定义 read」被上一份掩盖
	local ok, err = pcall(dofile, path)
	check(name .. " 可加载", ok, tostring(err))
	if ok then
		if LIB_ONLY[name] then
			check(name .. " 为纯库（不定义驱动入口）", type(build) ~= "function")
		else
			check(name .. " 定义 build", type(build) == "function")
			check(name .. " 定义 call", type(call) == "function")
			check(name .. " 定义 destroy", type(destroy) == "function")
			if not NO_ARG_TABLE[name] then
				-- 非表入参：必须是 ERR 契约表（不是抛错、不是 nil）。
				-- 用 pcall 包住：一旦某驱动抛 Lua error，sweep 必须把它记成
				-- 失败并继续扫下一个模块，而不是整个用例中途夭折
				--（首版就踩过：LlmDeepSeek.call(nil) 抛错，后面的模块全没扫到）。
				local pok, rb = pcall(build, nil)
				check(name .. ".build 非表入参返 ERR 契约（不抛错）",
					pok and type(rb) == "table" and rb.result == "ERR",
					pok and (type(rb) == "table" and tostring(rb.result) or type(rb))
						or ("raised: " .. tostring(rb)))
				local cok, rc = pcall(call, nil)
				check(name .. ".call 非表入参返 ERR 契约（不抛错）",
					cok and type(rc) == "table" and rc.result == "ERR",
					cok and (type(rc) == "table" and tostring(rc.result) or type(rc))
						or ("raised: " .. tostring(rc)))
				-- D2-1（2026-09-20 审计 / 2026-09-21 落地）：destroy 同样必须收
				-- arg_table 守卫——`destroy(nil)` 返回 "OK" 属「静默成功」绕过，
				-- 会让 teardown 在资源缺失时被当成正常完成掩盖。与 build/call
				-- 同一语义出口：非表入参返回 ERR 契约而非抛错/静默成功。
				local dok, rd = pcall(destroy, nil)
				check(name .. ".destroy 非表入参返 ERR 契约（不抛错）",
					dok and type(rd) == "table" and rd.result == "ERR",
					dok and (type(rd) == "table" and tostring(rd.result) or type(rd))
						or ("raised: " .. tostring(rd)))
				-- D2-7/F1-9（2026-09-21）：可选 read(data) 入口此前既无契约条目
				-- 也无任何覆盖（docs/drivers.md 现已登记）。宿主对 read 走
				-- **不过 ensureOk** 的路径（src/luavar.cpp:189-201）——读是数据流
				-- 而非动作，返回值可以是标量（Ema/Kalman/Monitor 返回 last）。
				-- 故这里只钉两条现状：不抛错、不返回 nil；有 ERR 表时字段齐备。
				-- 反过来说：把 read(nil) 改成抛错或返回 nil，本断言即红。
				if type(read) == "function" then
					local rok, rr = pcall(read, nil)
					local shapeOk = rok and rr ~= nil
					if shapeOk and type(rr) == "table" then
						shapeOk = (rr.result == nil) or (rr.result == "ERR" and rr.message ~= nil)
							or (rr.result == "OK")
					end
					check(name .. ".read(nil) 不抛错且非 nil（宿主 read 路径不过 ensureOk）",
						shapeOk,
						rok and ("返回 " .. type(rr) .. ": " .. tostring(rr)) or ("raised: " .. tostring(rr)))
				end
			end
		end
	end
end

-- ---- 全局 err 构造器健康检查（2026-09-21 审计 AG-2）----
--
-- 背景：err 是 drv_common 定义在 **lua_State 全局**上的 ERR 表构造器，全体驱动
-- 共用。任何驱动只要在函数体里把 `err` 当普通变量赋值（`payload, err = grab_one()`），
-- 就会把它覆盖成 nil 或字符串——此后**同一个 lua_State 里所有驱动**的
-- `err(...)` 全部变成 "attempt to call a nil/string value"，驱动对宿主抛裸 Lua
-- error 而不是返回 ERR 契约。
--
-- 实测案例：modules/Camera.lua 抓帧重试循环误写全局 err（AG-2），成功路径把它
-- 赋成 nil、失败路径赋成字符串。既有 sweep 逐个加载模块却从不检查「加载完
-- 全局被谁动过」，所以这条缺陷一直是隐形的。下面把「加载完全部驱动后 err 仍是
-- 可用的构造函数」变成断言——单条断言覆盖全部模块，后续任何驱动再犯同样的错
-- 都会在这里红。
do
	local err_now = _G.err
	check("全局 err 构造器未被任何驱动覆盖（AG-2）", type(err_now) == "function",
		"type(err)=" .. type(err_now) .. "（有驱动把它当普通变量赋值了）")
	if type(err_now) == "function" then
		local probe = err_now("sweep-probe")
		check("全局 err 仍返回 ERR 契约表（AG-2）",
			type(probe) == "table" and probe.result == "ERR" and probe.message == "sweep-probe",
			tostring(type(probe) == "table" and probe.result or probe))
	end
end

-- ---- 单笔 I2C 写字节数 sweep（2026-09-20 审计 P0 防回归）----
--
-- 背景：bus_contract 的 I2C_IO_MAX_BYTES 曾被照搬 SPI 侧的 64，直接拒掉
-- VL53L4CD 的默认配置流（一次写 91 数据字节 + 2 字节指针），全量守门红两条；
-- 而那次提交只跑了「相关」测试子集，恰好漏掉唯一受害的驱动。
-- 根子在于：**收紧常量与扫描全体调用方之间没有任何机制**，只能靠人记得。
-- 这里把该机制补成断言——静态估算每个 i2c_write_multi / i2c_write_reg16
-- 调用点的数据字节数（HAL 的判据是 #data-1 / #data，两者都只数寄存器指针
-- 之后的数据字节），断言 ≤ I2C_IO_MAX_BYTES。
--
-- 能静态定尺寸的只有两种形态：字面变参、`unpack(同文件内的表字面量)`。
-- 其余（跨模块传入、循环拼装、`unpack` 别的表）列入「未定尺寸」清单打印出来，
-- **不做断言**——宁可少判，不可假绿。为防「匹配数为零也算通过」，
-- 末尾另有一条断言要求 sweep 确实看到 VL53L4CD 的 91 字节配置流。
--
-- 局限（有意接受）：这是源码级 lint，不是执行级测量。去行注释、平衡括号、
-- 实参切分都按最朴素规则做，遇到长字符串/长注释会失配——失配的后果是
-- 该点进「未定尺寸」清单，不会误判为通过。

local bus = dofile("modules/lib/bus_contract.lua")
local I2C_CAP = bus.I2C_IO_MAX_BYTES

local function readAll(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- 去掉字符串外的行注释（`--` 到行尾）。长括号串/长注释不处理：
-- modules/*.lua 里没有这种写法，一旦出现只会让该调用点落入未定尺寸清单。
local function stripLineComments(src)
	local out, j, inStr = {}, 1, nil
	while j <= #src do
		local c = src:sub(j, j)
		if inStr then
			out[#out + 1] = c
			if c == "\\" and j < #src then
				j = j + 1
				out[#out + 1] = src:sub(j, j)
			elseif c == inStr then
				inStr = nil
			end
		elseif c == "'" or c == '"' then
			inStr = c
			out[#out + 1] = c
		elseif src:sub(j, j + 1) == "--" then
			while j <= #src and src:sub(j, j) ~= "\n" do j = j + 1 end
			j = j - 1	-- 保留换行（行号计数依赖它）
		else
			out[#out + 1] = c
		end
		j = j + 1
	end
	return table.concat(out)
end

-- 取 src 第 i 个字符（open）起、到配对 close 之间的内容；跨字符串不计数
local function balanced(src, i, open, close)
	if src:sub(i, i) ~= open then return nil end
	local depth, j, inStr = 0, i, nil
	while j <= #src do
		local c = src:sub(j, j)
		if inStr then
			if c == "\\" then j = j + 1
			elseif c == inStr then inStr = nil end
		elseif c == "'" or c == '"' then inStr = c
		elseif c == open then depth = depth + 1
		elseif c == close then
			depth = depth - 1
			if depth == 0 then return src:sub(i + 1, j - 1) end
		end
		j = j + 1
	end
	return nil
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- 按顶层逗号切实参（括号/花括号/方括号内的逗号不切）
local function splitArgs(s)
	local args, depth, cur, j, inStr = {}, 0, {}, 1, nil
	while j <= #s do
		local c = s:sub(j, j)
		if inStr then
			cur[#cur + 1] = c
			if c == "\\" and j < #s then
				j = j + 1
				cur[#cur + 1] = s:sub(j, j)
			elseif c == inStr then inStr = nil end
		elseif c == "'" or c == '"' then inStr = c; cur[#cur + 1] = c
		elseif c == "(" or c == "{" or c == "[" then depth = depth + 1; cur[#cur + 1] = c
		elseif c == ")" or c == "}" or c == "]" then depth = depth - 1; cur[#cur + 1] = c
		elseif c == "," and depth == 0 then
			args[#args + 1] = trim(table.concat(cur)); cur = {}
		else cur[#cur + 1] = c end
		j = j + 1
	end
	if #cur > 0 then args[#args + 1] = trim(table.concat(cur)) end
	return args
end

-- 同文件内 `local NAME = { ... }` 的顶层元素个数；含嵌套表即返 nil（不定尺寸）。
-- 按「顶层逗号切分后的非空字段」计数，不是「逗号数+1」——表字面量常带
-- trailing comma（VL53L4CD 的 CONFIG_TABLE 就是），后者会多数一个。
local function flatTableSize(src, name)
	local i = src:find("local%s+" .. name .. "%s*=%s*{")
	if not i then return nil end
	local brace = src:find("{", i, true)
	local body = balanced(src, brace, "{", "}")
	if body == nil or body:find("{", 1, true) then return nil end
	local n = 0
	for _, field in ipairs(splitArgs(body)) do
		if field ~= "" then n = n + 1 end
	end
	return n
end

local WRITE_FNS = { "i2c_write_multi", "i2c_write_reg16" }
local sized, unsized = {}, {}	-- 模块名 -> {行号, 字节数} / {行号, 实参串}
local globalMax, globalMaxSite = 0, nil

local function lineOf(src, pos)
	local n = 1
	for j = 1, pos - 1 do if src:sub(j, j) == "\n" then n = n + 1 end end
	return n
end

for _, path in ipairs(mods) do
	local name = path:match("([^/]+)%.lua$") or path
	local raw = readAll(path)
	if raw then
		local src = stripLineComments(raw)
		for _, fn in ipairs(WRITE_FNS) do
			local pos = 1
			while true do
				local s = src:find(fn, pos, true)
				if not s then break end
				pos = s + #fn
				-- 只认真正的调用点（后随 '('），跳过注释里/字符串里的同名出现
				local paren = src:find("^%s*%(", pos)
				if paren then
					local body = balanced(src, paren, "(", ")")
					local line = lineOf(src, s)
					if body == nil then
						unsized[name] = unsized[name] or {}
						unsized[name][#unsized[name] + 1] = { line, fn .. "(括号不配对)" }
					else
						local args = splitArgs(body)
						-- args[1]=fd，args[2]=寄存器指针（1 或 2 字节），都不计入判据
						local n, ok = 0, #args >= 2
						for k = 3, #args do
							local un = args[k]:match("^unpack%s*%(%s*([%w_]+)%s*%)$")
							if un then
								local sz = flatTableSize(src, un)
								if sz then n = n + sz else ok = false end
							else
								n = n + 1
							end
						end
						if ok then
							sized[name] = sized[name] or {}
							sized[name][#sized[name] + 1] = { line, n }
							if n > globalMax then
								globalMax, globalMaxSite = n, name .. ".lua:" .. line
							end
						else
							unsized[name] = unsized[name] or {}
							unsized[name][#unsized[name] + 1] = { line, trim(body) }
						end
					end
				end
			end
		end
	end
end

local sizedMods, unsizedMods = 0, 0
for name, sites in pairs(sized) do
	sizedMods = sizedMods + 1
	local worst, worstLine = -1, nil
	for _, e in ipairs(sites) do
		if e[2] > worst then worst, worstLine = e[2], e[1] end
	end
	check(string.format("%s 单笔 I2C 写 ≤ %d 字节（最大 %d，%s:%d）",
		name, I2C_CAP, worst, name .. ".lua", worstLine),
		worst <= I2C_CAP, worst .. " > " .. I2C_CAP)
end
for name, sites in pairs(unsized) do
	unsizedMods = unsizedMods + 1
	for _, e in ipairs(sites) do
		print(string.format("  [未定尺寸] %s.lua:%d  %s", name, e[1], e[2]))
	end
end

-- 防假绿：sweep 必须真的看见那个把守门打红的调用点
check("sweep 覆盖到 VL53L4CD 的 91 字节配置流",
	sized["VL53L4CD"] ~= nil and globalMax >= 91,
	"全仓静态最大单笔 = " .. tostring(globalMax) .. "（" .. tostring(globalMaxSite) .. "）")
check("sweep 匹配到调用点（非空扫）", sizedMods + unsizedMods > 10,
	string.format("定尺寸 %d 个模块 / 未定尺寸 %d 个模块", sizedMods, unsizedMods))

-- ---- SINGLE_CONSUMER 声明者集合的双向钉住（审计 1.3 补救）----
-- 判据的开关在**驱动源**里（行首 SINGLE_CONSUMER），而"哪些器件需要单消费者"这条
-- 知识同时写在 docs/drivers.md 与 docs/faq.md。三处任一方漂移都**没有运行期症状**：
-- 漏标 = 双消费者静默数据错乱（错误高度 / 漏报闪电 / 读错寄存器），
-- 多标 = 白白禁掉一种安全且常用的形态（直连 + 守护同址）。
-- 所以必须由守门钉住：① 扫出的集合 == 下面的期望集合（加/删声明必须同步改这里）；
-- ② 每个声明者都在 docs/drivers.md 里出现（文档不得漏项）。
local EXPECT_SINGLE_CONSUMER = {
	AS3935 = true, AS7262 = true, MS5611 = true, VL53L0X = true, VL53L4CD = true,
}

local declared = {}
for _, path in ipairs(mods) do
	local name = path:match("([^/]+)%.lua$") or path
	local src = readAll(path)
	if src then
		-- 与宿主 src/hw_factory.cpp 的 declaresSingleConsumer 同判据：
		-- 行首（允许前导空白）才算声明，注释里的偶提不算。
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			if line:match("^%s*SINGLE_CONSUMER") then
				declared[name] = true
				break
			end
		end
	end
end

local missing, unregistered = {}, {}
for n in pairs(EXPECT_SINGLE_CONSUMER) do
	if not declared[n] then missing[#missing + 1] = n end
end
for n in pairs(declared) do
	if not EXPECT_SINGLE_CONSUMER[n] then unregistered[#unregistered + 1] = n end
end
table.sort(missing)
table.sort(unregistered)
check("SINGLE_CONSUMER 声明者集合与期望一致",
	#missing == 0 and #unregistered == 0,
	"源里漏标: [" .. table.concat(missing, ",")
		.. "] 未登记进期望集合: [" .. table.concat(unregistered, ",") .. "]")

local docsrc = readAll("docs/drivers.md") or ""
local absent = {}
for n in pairs(declared) do
	if not docsrc:find(n, 1, true) then absent[#absent + 1] = n end
end
table.sort(absent)
check("每个 SINGLE_CONSUMER 声明者都在 docs/drivers.md 里出现", #absent == 0,
	"文档缺: [" .. table.concat(absent, ",") .. "]")

tester.summary("test_driver_contract")
return 0
