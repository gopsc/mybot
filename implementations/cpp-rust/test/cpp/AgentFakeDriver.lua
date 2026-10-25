-- AgentFakeDriver.lua —— test/cpp/test_agentdriver.cpp 用的假 LLM 协议驱动
--
-- 不联网：把收到的规范化请求特征回显成 content，用来断言 C++ 侧的
-- ChatTransport 适配器确实把请求递到了驱动、并把驱动的响应解析回来。
-- model 传 "fail" 时走 ERR 契约，用于覆盖错误回传路径。
-- model 传 "netfail-once" 时：**仅首次**返回可重试的网络类 ERR（消息含
-- "curl error"，命中宿主的 isRetriableError），用来覆盖重试循环与日志 sink；
-- "netfail-always" 则每次都失败，用来钉住「max_retries = 0 也要发一次」。

local netfail_once_calls = 0
local noid_calls = 0

function build(data)
	return { result = "OK" }
end

function destroy(data)
	return { result = "OK" }
end

function call(data)
	if data.model == "fail" then
		return { result = "ERR", message = "假驱动故意失败" }
	end
	if data.model == "netfail-once" then
		netfail_once_calls = netfail_once_calls + 1
		if netfail_once_calls == 1 then
			return { result = "ERR", message = "curl error 7: 网络不可达（假驱动，仅首次）" }
		end
	end
	if data.model == "netfail-always" then
		return { result = "ERR", message = "curl error 7: 网络不可达（假驱动，始终）" }
	end
	-- SAN-6：模拟"漏 tool_call id 的网关"。宿主必须为每一轮合成**跨轮唯一**的 id
	-- （call_<turn>_<i>）——驱动合成的 call_<i> 每轮从 1 重来，会让第二轮与第一轮
	-- 撞车（真机 400 answered more than once）。第二轮回一句最终回答收尾
	-- （否则工具循环跑到轮次上限）。
	if data.model == "noid" then
		noid_calls = noid_calls + 1
		if noid_calls > 2 then
			return { result = "OK", content = "收尾" }
		end
		return {
			result = "OK",
			content = "调用工具（无 id）",
			tool_calls = { { id = "", name = "list_hardware", arguments = "{}" } },
		}
	end

	local nmsgs = 0
	for _ in ipairs(data.messages or {}) do nmsgs = nmsgs + 1 end
	local ntools = 0
	for _ in ipairs(data.tools or {}) do ntools = ntools + 1 end

	local first = (data.messages or {})[1] or {}
	return {
		result = "OK",
		content = string.format("msgs=%d tools=%d model=%s endpoint=%s first=%s",
			nmsgs, ntools, tostring(data.model), tostring(data.endpoint),
			tostring(first.content)),
		tool_calls = { { id = "c1", name = "list_hardware", arguments = "{}" } },
		extras = { reasoning_content = "fake-think" },
	}
end
