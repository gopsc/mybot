-- P4 control-flow test driver: increments a counter per call.
local reading = 0

function build(data)
    print("Counter: build")
    return { result = "OK" }
end

function call(data)
    reading = reading + 1
    print("Counter: reading=" .. tostring(reading))
    return { result = "OK", reading = reading }
end

function destroy(data)
    print("Counter: destroy")
    return { result = "OK" }
end
