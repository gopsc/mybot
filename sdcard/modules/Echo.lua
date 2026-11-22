-- P1-B 第二个纯 Lua 驱动：不加载 drv_common，专门验证每设备 env 隔离。
-- 如果 Relay 和 Echo 共用全局环境，两者会互相覆盖 build/call/destroy。

function build(data)
    print("Echo: build")
    return { result = "OK" }
end

function call(data)
    local value = data.test or 0
    print("Echo: call test=" .. tostring(value))
    return { result = "OK", value = value * 2 }
end

function destroy(data)
    print("Echo: destroy")
    return { result = "OK" }
end
