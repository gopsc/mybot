function build(data)
    print("P5Check: build value=" .. tostring(data.value) ..
          " name=" .. tostring(data.name) ..
          " item=" .. tostring(data.item) ..
          " angle=" .. tostring(data.angle))
    return { result = "OK" }
end

function call(data)
    print("P5Check: call value=" .. tostring(data.value) ..
          " name=" .. tostring(data.name) ..
          " item=" .. tostring(data.item) ..
          " angle=" .. tostring(data.angle))
    return { result = "OK" }
end

function destroy(data)
    print("P5Check: destroy")
    return { result = "OK" }
end
