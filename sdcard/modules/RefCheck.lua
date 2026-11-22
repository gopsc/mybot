-- P2-B 引用/别名检查驱动：不碰真实硬件，只验证传入的元数据。
function build(data)
    print("RefCheck: build fd=" .. tostring(data.fd) ..
          " address=" .. tostring(data.address) ..
          " note=" .. tostring(data.note))
    return { result = "OK" }
end

function call(data)
    print("RefCheck: call fd=" .. tostring(data.fd) ..
          " angle=" .. tostring(data.angle) ..
          " n=" .. tostring(data.n))
    return { result = "OK", fd = data.fd, angle = data.angle, n = data.n }
end

function destroy(data)
    print("RefCheck: destroy fd=" .. tostring(data.fd))
    return { result = "OK" }
end
