-- P46: alternates the returned parameter name so action headers can be
-- re-evaluated between rows.
local count = 0

function build(data)
    print("Switch: build")
    return { result = "OK" }
end

function call(data)
    count = count + 1
    local name = (count % 2 == 1) and "angle" or "item"
    print("Switch: pick=" .. name)
    return { result = "OK", param = name }
end

function destroy(data)
    print("Switch: destroy")
    return { result = "OK" }
end
