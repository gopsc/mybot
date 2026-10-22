-- Qsont 云端网关驱动（qsont iot-server 的 IoT 设备客户端）
--
-- 依赖：HTTP 总线变量（HTTP 列以 $会话 引用，与 UART 列引用串口同构）。
-- build 时用 user/pass 调 /users/login 换取 JWT（服务端 24h 有效），此后
-- 每次 call 携带 Bearer 头；遇 401 自动重登一次再重试（凭据常驻行元数据，
-- 重登不依赖动作参数）。device 列 = 服务器上已注册的设备 ID——本驱动不在
-- build 里静默注册账号或创建设备（那会向服务端写隐藏状态）。
--
-- op 分派（mode/result/message 是宿主保留键，动作列只能叫 op）：
--   push     推单条数据（key 列给出时可为缺省动作）：key + value
--   batch    批量推送：items = "k=v|k2=v2"
--   pull     拉取待执行指令 → {count, commands=JSON 数组串}
--   ack      回执指令状态：cmd = 指令 ID，status 缺省 executed
--   online   上报在线状态：online 缺省 1（0 = 离线）
--   devices  列出本账号设备 → {count, devices=JSON 数组串}
--   latest   读回最新数据点：key 可选（按 data_key 过滤）
--   （缺省）  autopush：把 controller 转发来的结果表剔除框架/结构键后整批
--            上推 /data/batch——传感器行写 controller1='<本变量>' 即可让
--            每次采样自动上云（T=25.3 之类数值字段原样成为数据点）
--
-- 错误口径：传输失败透传 http_request 的 {result="ERR"}；HTTP >= 400 →
-- err("HTTP <status>: <body 前 200 字>")。destroy 是空操作（不在销毁路径
-- 上做网络 I/O，服务端在线状态由 online 动作或心跳脚本显式管理）。
--
-- 无 VIRT 模型：HTTP 驱动的无硬件验证天然是本地回环假服务器（默认免
-- --allow-hardware），不走 virtbus。

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local json = dofile(mpath.resolve("lib/json.lua"))

-- 会话状态（文件级 upvalue，随本变量的 Lua 状态机生命周期）
local token = nil
local device_id = nil

-- autopush 剔除键：宿主注入键（mode）、框架返回键（result/message）、HTTP
-- 会话合并键（fd/base/timeout）、本驱动自身参数与结构列、常见总线引用/
-- 元数据键（controller 转发的 payload 是「传感器元数据 | 结果表」，会把
-- 传感器的结构列一并带过来）
local SKIP_KEYS = {
	result = true, mode = true, message = true,
	fd = true, base = true, timeout = true,
	op = true, key = true, value = true, items = true,
	cmd = true, status = true, online = true, count = true,
	user = true, pass = true, device = true, name = true,
	baud = true, path = true, delay = true, addr = true, address = true,
	proto = true, I2C = true, SPI = true, UART = true, HTTP = true,
}

local function api(ctx, method, path, payload)
	local headers = nil
	if token ~= nil then
		headers = { Authorization = "Bearer " .. token }
	end
	local body = nil
	if payload ~= nil then
		body = json.encode(payload)
		headers = headers or {}
		headers["Content-Type"] = "application/json"
	end
	local resp = http_request(ctx.fd, method, path, headers, body)
	if type(resp) ~= "table" then
		return err("Invalid HTTP response")
	end
	local decoded = nil
	if resp.result == "OK" and type(resp.body) == "string" and resp.body ~= "" then
		local ok, value = pcall(json.decode, resp.body)
		if ok then decoded = value end
	end
	return resp, decoded
end

-- 登录换取 token；成功返回 nil，失败返回 err 表
local function login(ctx, data)
	local resp, decoded = api(ctx, "POST", "/users/login",
		{ username = data.user, password = data.pass })
	if resp.result ~= "OK" then
		return resp
	end
	if resp.status ~= 200 or type(decoded) ~= "table" or decoded.access_token == nil then
		local note = type(resp.body) == "string" and resp.body or ""
		if #note > 120 then note = note:sub(1, 120) .. "..." end
		return err("login failed: HTTP " .. tostring(resp.status) .. " " .. note)
	end
	token = decoded.access_token
	return nil
end

-- api 的 401 包装：重登一次再重试；HTTP >= 400 统一折成 err
local function call_api(ctx, data, method, path, payload)	local resp, decoded = api(ctx, method, path, payload)
	if resp.result == "OK" and resp.status == 401 then
		token = nil
		local failure = login(ctx, data)
		if failure ~= nil then return failure end
		resp, decoded = api(ctx, method, path, payload)
	end
	if resp.result ~= "OK" then
		return resp
	end
	if resp.status >= 400 then
		local note = type(resp.body) == "string" and resp.body or ""
		if #note > 200 then note = note:sub(1, 200) .. "..." end
		return err("HTTP " .. tostring(resp.status) .. ": " .. note)
	end
	return resp, decoded
end

-- latest 动作的请求路径（key 可选，按 data_key 过滤）
local function latest_path(key)
	local path = "/data/" .. tostring(device_id) .. "/latest"
	if key ~= nil and key ~= "" then
		path = path .. "?data_key=" .. tostring(key)
	end
	return path
end

require_driver("http", {
	name = "Qsont",

	build = function(ctx, data)
		if data.user == nil or data.pass == nil or data.user == "" or data.pass == "" then
			return err("Invalid Arguments: user, pass")
		end
		-- ID 必须精确（int_or 是钳制语义：0 会被吸成 1，故走 finite_of 显式拒绝）
		local dev = finite_of(data.device)
		if dev == nil or dev ~= math.floor(dev) or dev < 1 then
			return err("Invalid Arguments: device (registered device id)")
		end
		dev = math.floor(dev)
		local failure = login(ctx, data)
		if failure ~= nil then
			return failure
		end
		device_id = dev
		return { result = "OK", user = tostring(data.user), device = dev }
	end,

	call = function(ctx, data)
		local op = data.op
		if op == nil and data.key ~= nil then op = "push" end

		if op == "push" then
			if data.key == nil or data.key == "" then
				return err("Invalid Arguments: key")
			end
			if data.value == nil then
				return err("Invalid Arguments: value")
			end
			local resp, decoded = call_api(ctx, data, "POST", "/data", {
				device_id = device_id,
				data_key = tostring(data.key),
				data_value = tostring(data.value),
			})
			if resp.result ~= "OK" then return resp end
			local id = nil
			if type(decoded) == "table" then id = tonumber(decoded.id) end
			return { result = "OK", id = id }

		elseif op == "batch" then
			if type(data.items) ~= "string" then
				return err("Invalid Arguments: items (k=v|k2=v2)")
			end
			local items = {}
			for pair in data.items:gmatch("[^|]+") do
				local k, v = pair:match("^%s*([^=|]+)%s*=%s*(.-)%s*$")
				if k == nil or k == "" then
					return err("Invalid Arguments: items (k=v|k2=v2)")
				end
				items[#items + 1] = { device_id = device_id, data_key = k, data_value = v }
			end
			if #items == 0 then
				return err("Invalid Arguments: items (empty)")
			end
			local resp = call_api(ctx, data, "POST", "/data/batch",
				{ device_id = device_id, items = items })
			if resp.result ~= "OK" then return resp end
			return { result = "OK", count = #items }

		elseif op == "pull" then
			local resp, decoded = call_api(ctx, data, "GET", "/commands/pending")
			if resp.result ~= "OK" then return resp end
			local n = 0
			if type(decoded) == "table" then n = #decoded end
			local encoded = "[]"
			if n > 0 then
				local ok, text = pcall(json.encode, decoded)
				if ok then encoded = text end
			end
			return { result = "OK", count = n, commands = encoded }

		elseif op == "ack" then
			local cmd = finite_of(data.cmd)
			if cmd == nil or cmd ~= math.floor(cmd) or cmd < 1 then
				return err("Invalid Arguments: cmd (command id)")
			end
			cmd = math.floor(cmd)
			local status = data.status or "executed"
			if status ~= "sent" and status ~= "executed" and status ~= "failed" then
				return err("Invalid Arguments: status (sent|executed|failed)")
			end
			local resp = call_api(ctx, data, "PUT",
				"/commands/" .. tostring(cmd) .. "/status", { status = status })
			if resp.result ~= "OK" then return resp end
			return { result = "OK", cmd = cmd, status = status }

		elseif op == "bind" then
			-- 通过 device_key 绑定他人创建的设备（跨账号关联：mobile 建设备、
			-- 机器人绑定后即可推数据/拉指令）。绑定成功即采用返回的 device_id，
			-- 本会话后续 push/pull 无需改 SQL 立即可用；持久化请同步更新 device 列。
			if data.key == nil or data.key == "" then
				return err("Invalid Arguments: key (device_key)")
			end
			local resp, decoded = call_api(ctx, data, "POST", "/devices/bind",
				{ device_key = tostring(data.key) })
			if resp.result ~= "OK" then return resp end
			local bound_id, name = nil, nil
			if type(decoded) == "table" then
				bound_id = finite_of(decoded.device_id)
				name = decoded.device_name
			end
			if bound_id ~= nil and bound_id == math.floor(bound_id) and bound_id >= 1 then
				device_id = math.floor(bound_id)
			end
			return { result = "OK", device = device_id, name = name }

		elseif op == "unbind" then
			-- 解除绑定（只能解绑绑定来的设备；自己拥有的设备走服务器端删除）
			local resp = call_api(ctx, data, "DELETE",
				"/devices/" .. tostring(device_id) .. "/unbind")
			if resp.result ~= "OK" then return resp end
			return { result = "OK", device = device_id }

		elseif op == "online" then
			local flag = data.online
			if flag == nil then flag = 1 end
			flag = finite_of(flag)
			if flag == nil or (flag ~= 0 and flag ~= 1) then
				return err("Invalid Arguments: online (0|1)")
			end
			local resp = call_api(ctx, data, "PUT",
				"/devices/" .. tostring(device_id) .. "/status",
				{ is_online = flag == 1 })
			if resp.result ~= "OK" then return resp end
			return { result = "OK", online = flag }

		elseif op == "devices" then
			local resp, decoded = call_api(ctx, data, "GET", "/devices")
			if resp.result ~= "OK" then return resp end
			local n = 0
			if type(decoded) == "table" then n = #decoded end
			local encoded = "[]"
			if n > 0 then
				local ok, text = pcall(json.encode, decoded)
				if ok then encoded = text end
			end
			return { result = "OK", count = n, devices = encoded }

		elseif op == "latest" then
			local resp, decoded = call_api(ctx, data, "GET", latest_path(data.key))
			if resp.result ~= "OK" then return resp end
			if type(decoded) ~= "table" then
				return err("no data point")
			end
			return {
				result = "OK",
				id     = tonumber(decoded.id),
				key    = decoded.data_key,
				value  = decoded.data_value,
				time   = decoded.timestamp,
			}

		elseif op == nil then
			-- autopush：controller 转发来的结果表 → 剔除框架/结构键后整批上推
			local items = {}
			for k, v in pairs(data) do
				local t = type(v)
				if not SKIP_KEYS[k] and (t == "number" or (t == "string" and v:sub(1, 1) ~= "$")) then
					items[#items + 1] = {
						device_id = device_id,
						data_key = tostring(k),
						data_value = tostring(v),
					}
				end
			end
			if #items == 0 then
				return err("Invalid Arguments: op (push|batch|pull|ack|online|devices|latest)")
			end
			local resp = call_api(ctx, data, "POST", "/data/batch",
				{ device_id = device_id, items = items })
			if resp.result ~= "OK" then return resp end
			return { result = "OK", count = #items }

		else
			return err("Invalid Arguments: op (push|batch|pull|ack|online|devices|latest)")
		end
	end,
})

-- read：$引用 / Monitor 的读取口径——拉最新数据点（只读不写；不写 read 时
-- 回落 call 会命中 autopush 分支，把行元数据当动作参数处理，故显式给出）
function read(data)
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	local fd = tonumber(data.fd)
	if fd == nil or fd < 0 then
		return err("Invalid Argument: fd (does the HTTP column reference an @HTTP variable?)")
	end
	local resp, decoded = call_api({ fd = fd }, data, "GET", latest_path(data.key))
	if resp.result ~= "OK" then return resp end
	if type(decoded) ~= "table" then
		return err("no data point")
	end
	return {
		result = "OK",
		id     = tonumber(decoded.id),
		key    = decoded.data_key,
		value  = decoded.data_value,
		time   = decoded.timestamp,
	}
end
