-- Camera lifecycle shim. Python (PyAV capture, Pillow codecs) owns devices, encoding and source validation.
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local HAL = dofile(mpath.resolve("lib/HAL.lua"))
local handle, defaults = nil, {}
local function failure(message) return { result = "ERR", message = message } end
local function options(data)
    if type(data) ~= "table" then return nil, "Invalid Arguments Type: table" end
    if (data.width == nil) ~= (data.height == nil) then
        return nil, "width and height must be given together"
    end
    local out = {}
    for k, v in pairs(defaults) do out[k] = v end
    for k, v in pairs(data) do out[k] = v end
    return out
end
local function open(data)
    local fd = HAL.camera_open(data.path or data.device or 0, data.width or 640, data.height or 480)
    if fd == nil or fd < 0 then return nil, HAL.last_error() end
    return fd
end
function build(data)
    if handle ~= nil then HAL.camera_close(handle); handle = nil end
    defaults = {}
    local opts, message = options(data)
    if opts == nil then return failure(message) end
    local fd, open_error = open(opts)
    if fd == nil then return failure(open_error) end
    handle = fd
    -- Explicit file sources are validated at build; physical devices remain lazy.
    if opts.src ~= nil and opts.src ~= "" then
        local checked = HAL.camera_capture(handle, opts)
        if checked.result ~= "OK" then
            HAL.camera_close(handle); handle = nil
            return checked
        end
    end
    defaults = opts
    return { result = "OK" }
end
function call(data)
    local opts, message = options(data)
    if opts == nil then return failure(message) end
    if handle == nil then
        local fd, open_error = open(opts)
        if fd == nil then return failure(open_error) end
        handle = fd
    end
    return HAL.camera_capture(handle, opts)
end
function read(data) return call(data) end
function destroy(data)
    local result = 0
    if handle ~= nil then result = HAL.camera_close(handle); handle = nil end
    defaults = {}
    if result ~= 0 then return failure(HAL.last_error()) end
    return { result = "OK" }
end
