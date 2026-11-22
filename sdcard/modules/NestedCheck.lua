-- P60: returns nested tables for the ? print cell.
function build(data)
    print("NestedCheck: build")
    return { result = "OK" }
end

function call(data)
    print("NestedCheck: call")
    return {
        result = "OK",
        data = { temp = 21, name = "x", arr = {1, 2} },
        flag = true,
        n = 3.5,
    }
end

function destroy(data)
    print("NestedCheck: destroy")
    return { result = "OK" }
end
