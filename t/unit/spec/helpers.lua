-- helpers.lua — ngx.shared mock and stubs for busted unit tests
local _M = {}

-- =========================================================================
-- Mock shared dict — pure Lua implementation of ngx.shared.DICT API
-- =========================================================================
local SharedDict = {}
SharedDict.__index = SharedDict

function SharedDict.new(capacity_bytes)
    return setmetatable({
        _store = {},
        _capacity = capacity_bytes or 1048576,  -- 1MB default
        _used = 0,
    }, SharedDict)
end

function SharedDict:get(key)
    local entry = self._store[key]
    if not entry then return nil end
    return entry.value, entry.flags or 0
end

function SharedDict:set(key, value, exptime, flags)
    self._store[key] = {
        value = value,
        exptime = exptime or 0,
        flags = flags or 0,
    }
    return true, nil, false
end

function SharedDict:incr(key, value, init, init_ttl)
    local entry = self._store[key]
    if not entry then
        if init then
            self._store[key] = { value = init + value, exptime = init_ttl or 0, flags = 0 }
            return init + value, nil
        end
        return nil, "not found"
    end
    if type(entry.value) ~= "number" then
        return nil, "not a number"
    end
    entry.value = entry.value + value
    return entry.value, nil
end

function SharedDict:delete(key)
    self._store[key] = nil
end

function SharedDict:get_keys(max_count)
    local keys = {}
    local count = 0
    for k, _ in pairs(self._store) do
        count = count + 1
        if max_count > 0 and count > max_count then break end
        keys[#keys + 1] = k
    end
    return keys
end

function SharedDict:capacity()
    return self._capacity
end

function SharedDict:free_space()
    -- Approximate: count entries as 100 bytes each
    local used = 0
    for _ in pairs(self._store) do used = used + 100 end
    local free = self._capacity - used
    return free > 0 and free or 0
end

-- =========================================================================
-- ngx global mock
-- =========================================================================
local mock_time = 1000.0
local log_messages = {}
local timers = {}

local ngx_mock = {
    ERR  = 0,
    WARN = 1,
    INFO = 2,
    DEBUG = 3,

    shared = {},

    now = function()
        return mock_time
    end,

    log = function(level, ...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        log_messages[#log_messages + 1] = {
            level = level,
            message = table.concat(parts),
        }
    end,

    timer = {
        every = function(interval, callback)
            timers[#timers + 1] = { interval = interval, callback = callback }
            return true, nil
        end,
    },
}

-- =========================================================================
-- Public API
-- =========================================================================

--- Set up the ngx global with fresh shared dicts.
--- Call this in before_each() to get a clean slate.
--- @param dict_names string[] List of shared dict names to create
function _M.setup(dict_names)
    mock_time = 1000.0
    log_messages = {}
    timers = {}

    ngx_mock.shared = {}
    for _, name in ipairs(dict_names or {}) do
        ngx_mock.shared[name] = SharedDict.new()
    end

    -- Install as global
    _G.ngx = ngx_mock

    -- Clear cached module so it re-reads the ngx global
    package.loaded["resty.clienthello.ratelimit"] = nil
end

--- Advance mock time by `seconds`.
function _M.advance_time(seconds)
    mock_time = mock_time + seconds
end

--- Get all log messages captured since last setup().
function _M.get_logs()
    return log_messages
end

--- Get registered timers.
function _M.get_timers()
    return timers
end

--- Get the raw shared dict mock for direct inspection.
function _M.get_dict(name)
    return ngx_mock.shared[name]
end

return _M
