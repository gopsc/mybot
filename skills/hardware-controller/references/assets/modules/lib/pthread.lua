-- Portable daemon IPC: historical API, no native pointers or mutex ABI.
-- __daemon_call is a Lua closure converting primitive arguments/results.
-- Python owns slots and locks; Lua sees opaque integer IDs and table proxies.
if rawget(_G, "__BOT4CJ_PTHREAD") ~= nil then return _G.__BOT4CJ_PTHREAD end
local call = assert(rawget(_G, "__daemon_call"), "pthread requires the Python daemon bridge")
local P = {}
local layout = rawget(_G, "DAEMON_SLOT_LAYOUT") or { maxvals = 64 }
P.SLOT_MAXVALS = layout.maxvals or 64
local handles = setmetatable({}, { __mode = "k" })

local function id(slot)
    local value = type(slot) == "table" and handles[slot] or slot
    if type(value) ~= "number" or value <= 0 or value >= 2^53 or value % 1 ~= 0 then
        error("daemon slot must be an opaque positive integer ID or a slot table", 3)
    end
    return value
end

function P.assert_layout()
    -- Protocol check, not an emulation of the old native ABI.
    if layout.protocol ~= nil and layout.protocol ~= "python-slots-v1" then
        error("unsupported daemon slot bridge protocol")
    end
    if type(P.SLOT_MAXVALS) ~= "number" or P.SLOT_MAXVALS < 1
            or P.SLOT_MAXVALS > 1024 or P.SLOT_MAXVALS % 1 ~= 0 then
        error("invalid daemon slot capacity")
    end
    return true
end

function P.slot_attach(address)
    local key = id(address)
    call("capacity", key) -- validate capability before exposing a proxy
    local values = setmetatable({}, {
        __index = function(_, index)
            if type(index) ~= "number" or index < 0 or index % 1 ~= 0 then return nil end
            return call("read_sample", key).values[index + 1]
        end,
        __newindex = function() error("slot values are read-only; use publish") end,
        __metatable = false,
    })
    local record = setmetatable({}, {
        __index = function(_, field)
            if field == "values" then return values end
            if field == "capacity" then return call("capacity", key) end
            if field == "status" then return call("get_status", key) end
            if field == "stop" then return call("should_stop", key) and 1 or 0 end
            if field == "quiesce" then return call("quiesced", key) and 1 or 0 end
            if field == "count" or field == "nvals" then return call("read_sample", key)[field] end
        end,
        __newindex = function(_, field, value)
            if field == "status" then call("set_status", key, value)
            elseif field == "stop" and value == 1 then call("signal_stop", key)
            elseif field == "quiesce" and value == 1 then call("quiesce", key)
            else error("slot fields are read-only; use the pthread API") end
        end,
        __metatable = false,
    })
    -- Preserve slot[0].capacity / slot[0].stop for older pure-Lua chunks.
    local slot = setmetatable({}, {
        __index = function(_, field)
            if field == 0 then return record end
            return record[field]
        end,
        __newindex = function(_, field, value) record[field] = value end,
        __metatable = false,
    })
    handles[slot] = key
    return slot
end

function P.ptr(address, ctype) return P.slot_attach(address) end
function P.addr(slot) return id(slot) end
function P.capacity(slot) return call("capacity", id(slot)) end
function P.slot_new(capacity)
    return P.slot_attach(call("slot_new", capacity or P.SLOT_MAXVALS))
end
function P.mutex_init(slot) return call("init_slot", id(slot)) end
P.init_slot = P.mutex_init

function P.publish(slot, vals)
    if type(vals) ~= "table" then error("publish: vals must be a table") end
    local copy = {}
    local n = math.min(#vals, P.capacity(slot))
    for i = 1, n do
        local value = vals[i]
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            error("publish: vals[" .. i .. "] must be a finite number")
        end
        copy[i] = value
    end
    return call("publish", id(slot), copy)
end

function P.read_sample(slot) return call("read_sample", id(slot)) end
function P.latest(slot)
    local sample = P.read_sample(slot)
    return sample.values, sample.count
end
function P.should_stop(slot) return call("should_stop", id(slot)) end
function P.signal_stop(slot) return call("signal_stop", id(slot)) end
function P.get_status(slot) return call("get_status", id(slot)) end
function P.set_status(slot, code) return call("set_status", id(slot), code) end
function P.quiesced(slot) return call("quiesced", id(slot)) end
function P.quiesce(slot) return call("quiesce", id(slot)) end

P.assert_layout()
_G.__BOT4CJ_PTHREAD = P
return P
