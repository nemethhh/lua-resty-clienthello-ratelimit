-- =============================================================================
-- tls-clienthello-limiter OpenResty adapter
--
-- For vanilla OpenResty deployments (no APISIX).
-- Creates nginx-lua-prometheus counters with TTL expiration.
--
-- Usage:
--   init_worker_by_lua_block {
--       require("resty.clienthello.ratelimit.openresty").init({
--           per_ip = { rate = 2, burst = 4, block_ttl = 10 },
--           per_domain = { rate = 5, burst = 10 },
--           prometheus_dict = "prometheus-metrics",
--       })
--   }
--   ssl_client_hello_by_lua_block {
--       require("resty.clienthello.ratelimit.openresty").check()
--   }
-- =============================================================================

local core_mod = require("resty.clienthello.ratelimit")

local ngx      = ngx
local ngx_exit = ngx.exit
local ngx_log  = ngx.log
local ngx_WARN = ngx.WARN

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
--- @param opts table Config: per_ip, per_domain tables + optional prometheus_dict, prometheus, metrics_exptime
function _M.init(opts)
    opts = opts or {}

    -- Extract adapter-specific keys before passing to core
    local p = opts.prometheus
    local prometheus_dict = opts.prometheus_dict
    local metrics_exptime = opts.metrics_exptime
    local metrics_adapter = nil

    if p then
        metrics_adapter = build_metrics_adapter(p, metrics_exptime or 300)
    else
        local ok, prometheus_lib = pcall(require, "prometheus")
        if ok then
            local dict_name = prometheus_dict or "prometheus-metrics"
            p = prometheus_lib.init(dict_name)
            if p then
                metrics_adapter = build_metrics_adapter(p, metrics_exptime or 300)
            end
        end
    end

    _M.prometheus = p  -- expose for metrics endpoint

    -- Pass only rate-limit config to core (strip adapter keys)
    local core_opts = {
        per_ip = opts.per_ip,
        per_domain = opts.per_domain,
    }

    local limiter, warnings_or_err = core_mod.new(core_opts, metrics_adapter)
    if not limiter then
        error("tls-clienthello-limiter: " .. tostring(warnings_or_err))
    end

    -- Log any warnings
    if warnings_or_err then
        for _, w in ipairs(warnings_or_err) do
            ngx_log(ngx_WARN, "tls-clienthello-limiter: ", w)
        end
    end

    lim = limiter
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
