-- P3 I2C 自检驱动：验证真实总线 open + scan，不依赖具体器件。
function build(data)
    print("P3Check: build fd=" .. tostring(data.fd))
    return { result = "OK" }
end

function call(data)
    local found = i2c_scan(data.fd)
    local text = {}
    if type(found) == "table" then
        for _, addr in ipairs(found) do
            text[#text + 1] = string.format("0x%02X", addr)
        end
    end
    print("P3Check: scan fd=" .. tostring(data.fd) ..
          " found=" .. tostring(#text) ..
          " [" .. table.concat(text, ",") .. "]")
    return { result = "OK", found = #text }
end

function destroy(data)
    print("P3Check: destroy fd=" .. tostring(data.fd))
    return { result = "OK" }
end
