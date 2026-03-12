-- core_helpers.lua — mocks for tls-clienthello-limiter.core unit tests
local helpers = require("spec.helpers")
local _M = {}

-- Mock state
local mock_bin_ip = nil
local mock_sni = nil
local mock_request = true

function _M.setup(opts)
    opts = opts or {}
    helpers.setup({
        "tls-hello-per-ip",
        "tls-hello-per-domain",
        "tls-ip-blocklist",
    })

    mock_bin_ip = opts.bin_ip or string.char(10, 0, 0, 1)
    mock_sni = opts.sni or "test.example.com"
    mock_request = opts.has_request ~= false

    package.loaded["resty.limit.req"] = _M.make_limit_req_mock()
    package.loaded["ngx.ssl.clienthello"] = {
        get_client_hello_server_name = function()
            return mock_sni
        end,
    }
    package.loaded["resty.core.base"] = {
        get_request = function()
            return mock_request and {} or nil
        end,
    }

    package.loaded["resty.clienthello.ratelimit"] = nil
    package.loaded["resty.clienthello.ratelimit.config"] = nil
end

function _M.make_limit_req_mock()
    local limit_req = {}
    limit_req.__index = limit_req

    function limit_req.new(dict_name, rate, burst)
        local dict = ngx.shared[dict_name]
        if not dict then
            return nil, "shared dict not found"
        end
        return setmetatable({
            dict = dict,
            rate = rate,
            burst = burst,
            _call_count = {},
        }, limit_req)
    end

    function limit_req:incoming(key, commit)
        local count = (self._call_count[key] or 0) + 1
        if commit then
            self._call_count[key] = count
        end
        local limit = self.rate + self.burst
        if count > limit then
            return nil, "rejected"
        end
        return 0
    end

    return limit_req
end

function _M.require_core()
    if not pcall(require, "ffi") then
        package.loaded["ffi"] = _M.make_ffi_mock()
    end

    local core = require("resty.clienthello.ratelimit")
    if core._set_extract_client_ip then
        core._set_extract_client_ip(function()
            if not mock_request then return nil end
            return mock_bin_ip
        end)
    end
    return core
end

function _M.make_ffi_mock()
    return {
        cdef = function() end,
        new = function(ct) return {} end,
        string = function(ptr, len) return ptr end,
        cast = function(ct, val) return val end,
        C = setmetatable({}, {
            __index = function(_, k)
                return function() return -1 end
            end,
        }),
    }
end

function _M.set_mock_ip(bin_ip)
    mock_bin_ip = bin_ip
end

function _M.set_mock_sni(sni)
    mock_sni = sni
end

function _M.set_mock_request(has_request)
    mock_request = has_request
end

function _M.make_metrics_spy()
    local calls = {}
    return {
        inc_counter = function(name, labels)
            calls[#calls + 1] = {name = name, labels = labels}
        end,
        get_calls = function() return calls end,
        find = function(metric_name)
            for _, c in ipairs(calls) do
                if c.name == metric_name then return c end
            end
            return nil
        end,
        count = function(metric_name)
            local n = 0
            for _, c in ipairs(calls) do
                if c.name == metric_name then n = n + 1 end
            end
            return n
        end,
    }
end

return _M
