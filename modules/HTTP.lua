-- HTTP 端点（网络总线矩阵）
--
-- 与 I2C/SPI/UART 同级的第四种总线资源：声明一个 HTTP 服务端点会话。
-- open 不建连（HTTP 无持久连接），只做 URL 与超时校验；实际请求由引用本
-- 变量的设备驱动（如 Qsont），或本模块 call 的透传模式逐次发起。
-- 安全口径与串口 loop:// 同源：回环（127.0.0.1 / localhost / [::1]）默认
-- 可用，其余主机需要 --allow-hardware（宿主 runtime 门，Lua 侧不重复判定）。

--
-- 标准前导：HAL/print_table（部分驱动含 drv_common）经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bus = dofile(mpath.resolve("lib/bus_contract.lua"))
local json = dofile(mpath.resolve("lib/json.lua"))

-- 会话句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局）
local fd = -1

-- build 时缓存的端点 URL 与超时（call 随 fd 返回给引用本变量的设备驱动；
-- 透传请求也用 build 时的会话，不信任 call 元数据里的 base）
local base_url = nil
local timeout_ms = 10000

-- fd 回滚（C-M3'）：build 中途抛 Lua error 时由 guard_build 调用（幂等）
local function rollback_fd()
	if fd ~= nil and fd >= 0 then
		http_close(fd)
		fd = -1
	end
	base_url = nil
end

-- headers 入参兼容两种形态：表 {k=v, ...} 或竖线串 "k=v|k2=v2"（.mt 单元格文本）
local function header_table(spec)
	if spec == nil or spec == "-" or spec == "" then return nil end
	local out = {}
	if type(spec) == "table" then
		for k, v in pairs(spec) do
			out[tostring(k)] = tostring(v)
		end
		return out
	end
	if type(spec) ~= "string" then return nil end
	for pair in spec:gmatch("[^|]+") do
		local k, v = pair:match("^%s*([^=|]+)%s*=%s*(.-)%s*$")
		if k == nil or k == "" then return nil end
		out[k] = v
	end
	return out
end

local function build_impl(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- HTTP.lua builder func get a table --------", data)

	local base = data.base
	if base == nil or not bus.http_url_ok(base) then
		return err("Invalid Arguments: base (credential-free http(s):// URL)")
	end

	local tmo = finite_of(data.timeout)
	if tmo == nil then tmo = 10000 end
	if tmo < 1 or tmo > bus.HTTP_TIMEOUT_MAX_MS then
		return err("Invalid Arguments: timeout (1.." .. tostring(bus.HTTP_TIMEOUT_MAX_MS) .. " ms)")
	end

	-- 重复 build 先关旧会话再开新（与 I2C/UART/SPI 的守卫一致）
	if fd ~= nil and fd >= 0 then
		http_close(fd)
		fd = -1
	end

	local opened = http_open(base, tmo)
	if opened == nil or opened < 0 then
		return err("Failed to open HTTP endpoint")
	end

	fd = opened
	base_url = base
	timeout_ms = tmo

	return {  result = "OK"  }

end

-- build 全程守卫：异常折成 ERR 契约并回滚已打开的会话（drv_common.guard_build）
function build(data)
	return guard_build(rollback_fd, build_impl, data)
end

-- 【销毁HTTP会话】句柄只是校验过的端点配置（无持久连接），close 即注销。
-- 释放先行（沿 UART.lua 的 M3 顺序）：任何早退（含 arg_table 拒绝）都不得
-- 跳过 http_close，否则句柄滞留 HAL 表中。
function destroy(data)

	dbg_table("-------- HTTP.lua ender func get a table --------", data)

	if fd ~= nil and fd >= 0 then
		http_close(fd)
		fd = -1
	end

	local ok, e = arg_table(data)
	if not ok then
		return e	-- 非表：ERR（会话已尽力释放）
	end

	return {  result = "OK"  }

end

-- 【调用HTTP】两种身份：
--   1) 无请求参数 → 交出会话句柄（fd/base/timeout 经引用机制流入 Qsont
--      等设备驱动的元数据，与 UART 的 fd/baud/path 同一通道）
--   2) 给了 method 或 path → 透传执行一次 HTTP 请求（HTTP 总线可脱离设备
--      驱动在 .mt 里独立使用，如 `http.method http.path; GET /devices;`）
--      · method 缺省 GET；headers 支持 "k=v|k2=v2" 串或表
--      · body 为裸文本；json 为表时经 lib/json.lua 编码并缺省
--        Content-Type: application/json
--      · 返回 http_request 的 {result, status, body, headers} 原样
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- HTTP.lua caller func get a table --------", data)

	if fd == nil or fd < 0 then
		return err("HTTP endpoint not opened (build first)")
	end

	if data.method == nil and data.path == nil then
		return {
			result  = "OK",
			fd      = fd,
			base    = base_url,
			timeout = timeout_ms
		}
	end

	local method = data.method or "GET"
	local headers = header_table(data.headers)
	local body = data.body
	if data.json ~= nil and type(data.json) == "table" then
		local encoded = json.encode(data.json)
		if encoded == nil then
			return err("Invalid Arguments: json (not encodable)")
		end
		body = encoded
		headers = headers or {}
		if headers["Content-Type"] == nil and headers["content-type"] == nil then
			headers["Content-Type"] = "application/json"
		end
	end

	return http_request(fd, method, data.path or "", headers, body)

end
