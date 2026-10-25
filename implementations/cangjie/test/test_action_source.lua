-- test/test_action_source.lua
-- ActionSource 工厂离线桩测试（仓颉侧逻辑等价验证）
--
-- 本测试验证 ActionSource.cj 的工厂优先级与文件源逻辑。
-- 仓颉 stdlib 的 TCP API 无法在 Lua 离线桩中模拟，
-- 本测试聚焦：
--   1. 工厂优先级：tcp > input > stdin（模拟 Map 键存在性）
--   2. 文件源：从 .mt 文件读取 → 与 stdin 管道等价
--
-- TCP 端到端用 scripts/tcp_e2e.sh（Python 客户端 → TCP → 服务端）真机验证。

local pass = 0
local fail = 0
local function check(name, cond, detail)
	if cond then pass = pass + 1
	else
		fail = fail + 1
		io.write("  [FAIL] " .. name .. (detail and " (" .. detail .. ")" or "") .. "\n")
	end
end

-- ---- 1. 工厂优先级模拟 ----
local function mockOptions(tcp, input)
	local opts = {}
	if tcp then opts.tcp = tostring(tcp) end
	if input then opts.input = input end
	return opts
end

local function mockOpenActionSource(opts)
	-- 模拟 ActionSource.cj 的 openActionSource 优先级
	if opts.tcp then
		local port = tonumber(opts.tcp)
		if port and port >= 1 and port <= 65535 then
			return "tcp:" .. port
		else
			return nil
		end
	end
	if opts.input then
		local f = io.open(opts.input, "r")
		if f then f:close() return "file:" .. opts.input
		else return nil end
	end
	return "stdin"
end

do
	-- tcp 优先级最高
	local src = mockOpenActionSource(mockOptions(8080, "a.mt"))
	check("tcp 优先于 input", src == "tcp:8080", src)

	-- input 次之（文件存在时）：用本测试自身文件作为探针
	local selfFile = arg and arg[0] or "./test_action_source.lua"
	local src = mockOpenActionSource(mockOptions(nil, selfFile))
	check("input 次之（文件存在）", src == "file:" .. selfFile, src)

	-- input 文件不存在 → nil（仓颉侧：打不开即报错退出，不 fallback stdin）
	local src = mockOpenActionSource(mockOptions(nil, "/tmp/nonexistent_xyz.mt"))
	check("input 文件不存在返回 nil", src == nil, tostring(src))

	-- stdin 缺省
	local src = mockOpenActionSource(mockOptions())
	check("stdin 缺省", src == "stdin", src)

	-- 无效端口 → nil
	local src = mockOpenActionSource(mockOptions(99999))
	check("无效端口返回 nil", src == nil, tostring(src))
end

-- ---- 2. 文件源等价性：文件读 vs stdin 管道 ----
do
	local tmpMt = "/tmp/test_action_source.mt"
	local f = io.open(tmpMt, "w")
	f:write("Action\nrelay.power\n1\n\n")
	f:close()

	local ff = io.open(tmpMt, "r")
	local content = ff:read("a")
	ff:close()
	check("文件源读取 .mt 内容", content:find("relay.power") ~= nil,
		"content=" .. tostring(content))

	local pipe = io.popen('echo "Action" && echo "relay.power" && echo "1" && echo ""')
	local piped = pipe:read("a")
	pipe:close()
	check("stdin 管道等价", piped:find("relay.power") ~= nil,
		"piped=" .. tostring(piped))

	os.remove(tmpMt)
end

print(string.rep("-", 44))
print("ActionSource 工厂离线桩测试")
print(string.rep("-", 44))
print(string.format("通过: %d  失败: %d", pass, fail))
if fail > 0 then os.exit(1) end