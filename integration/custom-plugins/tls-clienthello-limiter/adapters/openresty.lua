-- =============================================================================
-- tls-clienthello-limiter OpenResty adapter
--
-- For vanilla OpenResty deployments (no APISIX).
-- Creates nginx-lua-prometheus counters with TTL expiration.
--
-- Usage:
--   init_worker_by_lua_block { require("...adapters.openresty").init() }
--   ssl_client_hello_by_lua_block { require("...adapters.openresty").check() }
-- =============================================================================

local core_mod = require("tls-clienthello-limiter.core")

local ngx      = ngx
local ngx_exit = ngx.exit

local _M = {}

local lim  -- core limiter instance


--- Build metrics adapter from nginx-lua-prometheus counters.
local function build_metrics_adapter(prometheus, exptime)
    local counters = {}

    return {
        inc_counter = function(name, labels)
            if not counters[name] then
                local label_names = {}
                if labels then
                    for k in pairs(labels) do
                        label_names[#label_names + 1] = k
                    end
                    table.sort(label_names)
                end
                counters[name] = prometheus:counter(name, name, label_names, exptime)
            end

            if labels then
                local label_names = {}
                for k in pairs(labels) do
                    label_names[#label_names + 1] = k
                end
                table.sort(label_names)
                local vals = {}
                for _, k in ipairs(label_names) do
                    vals[#vals + 1] = labels[k]
                end
                counters[name]:inc(1, vals)
            else
                counters[name]:inc(1)
            end
        end,
    }
end


--- Initialize the limiter. Call once in init_worker_by_lua_block.
--- @param opts table|nil Config overrides + optional prometheus/exptime fields
function _M.init(opts)
    opts = opts or {}

    local p = opts.prometheus
    local metrics_adapter = nil

    if p then
        metrics_adapter = build_metrics_adapter(p, opts.metrics_exptime or 300)
    else
        local ok, prometheus_lib = pcall(require, "prometheus")
        if ok then
            local dict_name = opts.prometheus_dict or "prometheus-metrics"
            p = prometheus_lib.init(dict_name)
            if p then
                metrics_adapter = build_metrics_adapter(p, opts.metrics_exptime or 300)
            end
        end
    end

    _M.prometheus = p  -- expose for metrics endpoint
    opts.metrics = metrics_adapter
    lim = core_mod.new(opts)
end


--- Check the current request. Call in ssl_client_hello_by_lua_block.
--- Rejects with ngx_exit(ngx.ERROR) if rate limited; returns normally if allowed.
function _M.check()
    if not lim then return end
    local rejected = lim:check()
    if rejected then
        return ngx_exit(ngx.ERROR)
    end
end


return _M
