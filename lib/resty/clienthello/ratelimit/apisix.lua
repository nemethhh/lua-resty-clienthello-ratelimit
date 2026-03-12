-- =============================================================================
-- tls-clienthello-limiter APISIX adapter
--
-- Thin wrapper: reads plugin_attr config, bridges APISIX prometheus for metrics,
-- monkey-patches apisix.ssl_client_hello_phase with core.check().
-- =============================================================================

local core_mod = require("resty.clienthello.ratelimit")
local config_mod = require("resty.clienthello.ratelimit.config")
local apisix_core = require("apisix.core")
local plugin = require("apisix.plugin")

local ngx      = ngx
local ngx_exit = ngx.exit

local plugin_name = "tls-clienthello-limiter"

local _M = {
    name     = plugin_name,
    version  = 0.3,
    priority = 0,
    schema   = {
        type = "object",
        properties = {},
    },
}

-- Instance state
local lim                            -- core limiter object
local original_ssl_client_hello_phase


function _M.check_schema(conf)
    -- Validate APISIX route-level schema (empty — no per-route config)
    local ok, err = apisix_core.schema.check(_M.schema, conf)
    if not ok then return false, err end
    return true
end


--- Build a metrics adapter that bridges to APISIX's prometheus.
local function build_metrics_adapter()
    local ok, prometheus_mod = pcall(require, "apisix.plugins.prometheus.exporter")
    if not ok or not prometheus_mod then
        return nil
    end

    local counters = {}

    return {
        inc_counter = function(name, labels)
            local p = prometheus_mod.get_prometheus()
            if not p then return end

            if not counters[name] then
                local label_names = {}
                if labels then
                    for k in pairs(labels) do
                        label_names[#label_names + 1] = k
                    end
                    table.sort(label_names)
                end
                counters[name] = p:counter(name, name, label_names)
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


function _M.init()
    -- Read plugin_attr configuration
    local attr = plugin.plugin_attr(plugin_name)
    local core_opts = {}
    if attr then
        core_opts.per_ip = attr.per_ip
        core_opts.per_domain = attr.per_domain
    end

    -- Build metrics adapter
    local metrics_adapter = build_metrics_adapter()

    -- Create core limiter
    local limiter, warnings_or_err = core_mod.new(core_opts, metrics_adapter)
    if not limiter then
        apisix_core.log.error("tls-clienthello-limiter: config error: ", tostring(warnings_or_err))
        return
    end

    -- Log any warnings
    if warnings_or_err then
        for _, w in ipairs(warnings_or_err) do
            apisix_core.log.warn("tls-clienthello-limiter: ", w)
        end
    end

    lim = limiter

    -- Monkey-patch apisix.ssl_client_hello_phase
    if apisix and apisix.ssl_client_hello_phase then
        original_ssl_client_hello_phase = apisix.ssl_client_hello_phase
        apisix.ssl_client_hello_phase = function()
            local rejected = lim:check()
            if rejected then
                return ngx_exit(ngx.ERROR)
            end
            return original_ssl_client_hello_phase()
        end
        apisix_core.log.warn("tls-clienthello-limiter: wrapped ssl_client_hello_phase")
    else
        apisix_core.log.error("tls-clienthello-limiter: apisix.ssl_client_hello_phase not found, "
            .. "plugin will not provide TLS rate limiting")
    end
end


function _M.destroy()
    if original_ssl_client_hello_phase and apisix then
        apisix.ssl_client_hello_phase = original_ssl_client_hello_phase
        apisix_core.log.warn("tls-clienthello-limiter: restored original ssl_client_hello_phase")
    end
end


return _M
