-- drv_common.lua - 驱动公共样板（modules/lib/）
-- bot4cj 仓颉语言机器人框架
--
-- 收敛 Low 项"样板重复"：各 I2C 驱动内联重复的开头样板：
--   1. type(data) ~= "table" 参数校验（build/call/destroy 每函数一份）
--   2. fd/address 存在性 + i2c_set_addr 校验（build 与 call 双份）
--   3. { result = "ERR", message = ... } 返回表构造
-- 行为与各驱动旧内联版本等价；调用点语义不变。
-- 驱动顶部在 HAL 之后 dofile 加载；依赖 i2c_set_addr（HAL）在此运行时可解析。
-- 幂等：同状态机内只定义一次（多个驱动文件 dofile 本库时安全）。
-- 用本库私有标记判断重复加载——若用 arg_table 等全局函数的存在性判断，
-- 状态机「先定义了同名全局函数但缺 err/i2c_pair」时会整体 return，消费者则崩溃。
if __BOT4CJ_DRV_COMMON_LOADED ~= nil then return end
__BOT4CJ_DRV_COMMON_LOADED = true

-- 统一 ERR 返回契约（与各驱动旧内联 {result="ERR",message=...} 一致）
function err(msg)
	return {  result = "ERR",  message = msg  }
end

-- 请求参数必须是表；否则返回 ERR
-- 用法：local ok, e = arg_table(data); if not ok then return e end
function arg_table(data)
	if type(data) ~= "table" then
		return false, err("Invalid Arguments Type: table")
	end
	return true, nil
end

-- I2C 传感器 build/call 公共前置：fd/address 存在性 + set_addr
-- 用法：local fd, addr, e = i2c_pair(data); if fd == nil then return e end
-- 返回：成功 => (fd, addr, nil)；失败 => (nil, -1, err表)
-- 原各驱动 build 与 call 双份校验语义一致，统一于此
function i2c_pair(data)
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return nil, -1, err("Invalid Argument: fd or address")
	end
	if not i2c_set_addr(fd, addr) then
		return nil, -1, err("Invalid Argument: fd or address (set_addr failed)")
	end
	return fd, addr, nil
end