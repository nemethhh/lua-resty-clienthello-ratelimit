-- bench/mocks.lua — Minimal mocks for JIT trace benchmarks
--
-- Provides lightweight replacements for OpenResty modules that
-- require nginx request context. Designed for use with `resty`
-- (real LuaJIT/FFI available, but no active HTTP request).
local ffi      = require("ffi")
local ffi_new  = ffi.new
local ffi_cast = ffi.cast
local ffi_str  = ffi.string

-- Ensure sockaddr structs are defined (init.lua uses pcall for these too,
-- but we need them available before init.lua is loaded for make_ffi_extract_fn)
pcall(ffi.cdef, [[
  struct sockaddr_in {
      unsigned short  sin_family;
      unsigned short  sin_port;
      unsigned char   sin_addr[4];
      unsigned char   sin_zero[8];
  };
  struct sockaddr_in6 {
      unsigned short  sin6_family;
      unsigned short  sin6_port;
      unsigned int    sin6_flowinfo;
      unsigned char   sin6_addr[16];
      unsigned int    sin6_scope_id;
  };
]])

local _M = {}

-- ========================================================================
-- Shared Dict Mock (pure Lua table, no TTL/eviction)
-- ========================================================================
local SharedDict = {}
SharedDict.__index = SharedDict

function SharedDict.new()
    return setmetatable({ _store = {} }, SharedDict)
end

function SharedDict:get(key)
    local v = self._store[key]
    if v == nil then return nil end
    return v, 0
end

function SharedDict:set(key, value, exptime, flags)
    self._store[key] = value
    return true, nil, false
end

function SharedDict:delete(key)
    self._store[key] = nil
end

-- ========================================================================
-- resty.limit.req Mock
-- ========================================================================
-- incoming_results maps dict_name -> { delay_or_nil, err_or_nil }
local incoming_results = {}

local LimitReq = {}
LimitReq.__index = LimitReq

function LimitReq.new(dict_name, rate, burst)
    return setmetatable({ _dict_name = dict_name }, LimitReq)
end

function LimitReq:incoming(key, commit)
    local r = incoming_results[self._dict_name]
    if r then return r[1], r[2] end
    return 0  -- default: allow
end

-- ========================================================================
-- Setup Functions
-- ========================================================================

--- Install mock shared dicts into ngx.shared.
--- Must be called before requiring the rate limiter module.
function _M.setup_shared_dicts()
    ngx.shared["tls-hello-per-ip"]    = SharedDict.new()
    ngx.shared["tls-hello-per-domain"] = SharedDict.new()
    ngx.shared["tls-ip-blocklist"]    = SharedDict.new()
end

--- Install mock modules into package.loaded.
--- Must be called before requiring the rate limiter module.
function _M.setup_modules()
    package.loaded["resty.limit.req"] = LimitReq
    package.loaded["ngx.ssl.clienthello"] = {
        get_client_hello_server_name = function()
            return "bench.example.com"
        end,
    }
end

--- Configure what lim:incoming() returns per shared-dict name.
--- @param results table  e.g. { ["tls-hello-per-ip"] = { nil, "rejected" } }
function _M.set_incoming_results(results)
    incoming_results = results
end

--- Reset incoming results to default (allow all).
function _M.reset_incoming_results()
    incoming_results = {}
end

--- Get the blocklist shared dict mock for seeding.
function _M.get_blocklist_dict()
    return ngx.shared["tls-ip-blocklist"]
end

-- ========================================================================
-- extract_client_ip replacements (used with _set_extract_client_ip)
-- ========================================================================

--- Creates a function that exercises real FFI operations (ffi_cast, ffi_str)
--- on a pre-allocated sockaddr_in struct. For path 1 (JIT trace of FFI ops).
function _M.make_ffi_extract_fn()
    local sa = ffi_new("struct sockaddr_in")
    sa.sin_family = 2  -- AF_INET
    sa.sin_addr[0] = 127
    sa.sin_addr[1] = 0
    sa.sin_addr[2] = 0
    sa.sin_addr[3] = 1

    local sa_ptr = ffi_cast("char*", sa)

    return function()
        local cast_sa = ffi_cast("struct sockaddr_in*", sa_ptr)
        return ffi_str(cast_sa.sin_addr, 4)
    end
end

--- Simple binary IP return (for paths 2-6 where FFI is not the focus).
local MOCK_BIN_IP = string.char(127, 0, 0, 1)

function _M.make_simple_extract_fn()
    return function()
        return MOCK_BIN_IP
    end
end

--- Return the binary IP used by make_simple_extract_fn (for blocklist seeding).
function _M.get_mock_bin_ip()
    return MOCK_BIN_IP
end

-- ========================================================================
-- No-op metrics adapter
-- ========================================================================
function _M.make_metrics()
    return {
        inc_counter = function() end,
    }
end

--- Force-reload the rate limiter module (clears cached upvalues).
function _M.reload_limiter()
    package.loaded["resty.clienthello.ratelimit"] = nil
    package.loaded["resty.clienthello.ratelimit.config"] = nil
    return require("resty.clienthello.ratelimit")
end

return _M
