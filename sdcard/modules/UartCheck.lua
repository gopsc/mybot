local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))

-- P3-C UART 自检：写两个字节，再读最多 4 字节（fake 总线返回 0）。
function build(data)
    print("UartCheck: build fd=" .. tostring(data.fd) ..
          " baud=" .. tostring(data.baud))
    return { result = "OK" }
end

function call(data)
    local wr = uart_write(data.fd, {0x41, 0x42})
    local rd = uart_read(data.fd, 4, 50)
    local text = {}
    if type(rd) == "table" then
        for _, b in ipairs(rd) do text[#text + 1] = string.format("%02X", b) end
    end
    print("UartCheck: write=" .. tostring(wr) ..
          " read=" .. tostring(#text) .. " [" .. table.concat(text, ",") .. "]")
    return { result = "OK", wrote = wr, read = #text }
end

function destroy(data)
    print("UartCheck: destroy fd=" .. tostring(data.fd))
    return { result = "OK" }
end
