-- Test copy (hardcoded values)
-- =============================================================================
-- tls-clienthello-limiter — APISIX plugin for TLS ClientHello rate limiting
--
-- Wraps apisix.ssl_client_hello_phase() to add multi-layer rate limiting:
--   T0: TLS IP blocklist (shared dict fast-path)
--   T1: Per-IP ClientHello rate (resty.limit.req)
--   T2: Per-SNI-domain ClientHello rate (resty.limit.req)
--
-- Whitelist bypass: Lua-native IP whitelist (ngx.var.is_whitelisted from geo/map
--   is NOT available in ssl_client_hello phase). Uses resty.ipmatcher for CIDR.
-- Metrics: emits counters via custom-metrics library
-- Configuration: reads plugin_attr.tls-clienthello-limiter from config.yaml
-- =============================================================================

local limit_req    = require("resty.limit.req")
local ssl_clt      = require("ngx.ssl.clienthello")
local core         = require("apisix.core")
local plugin       = require("apisix.plugin")
local ipmatcher    = require("resty.ipmatcher")

local ngx          = ngx
local ngx_log      = ngx.log
local ngx_ERR      = ngx.ERR
local ngx_exit     = ngx.exit

local plugin_name  = "tls-clienthello-limiter"

-- Lua-native IP whitelist (built from Ansible apisix_whitelist_ips)
-- ngx.var.is_whitelisted (geo/map) is NOT available in ssl_client_hello phase
local whitelist_matcher
do
    local whitelist_ips = {
        "127.0.0.1",
        "::1",
    }
    local matcher, err = ipmatcher.new(whitelist_ips)
    if matcher then
        whitelist_matcher = matcher
    else
        ngx.log(ngx.ERR, "tls-clienthello-limiter: failed to create whitelist matcher: ", err or "unknown")
    end
end

local _M = {
    name     = plugin_name,
    version  = 0.1,
    priority = 0,
    schema   = {
        type = "object",
        properties = {},
    },
}

-- Default configuration (overridden by plugin_attr)
local conf = {
    per_ip_rate       = 2,
    per_ip_burst      = 4,
    per_domain_rate   = 5,
    per_domain_burst  = 10,
    block_ttl         = 10,
}

-- Shared dict names
local DICT_PER_IP     = "tls-hello-per-ip"
local DICT_PER_DOMAIN = "tls-hello-per-domain"
local DICT_BLOCKLIST  = "tls-ip-blocklist"

-- Will hold the original function
local original_ssl_client_hello_phase

-- Metrics library (loaded lazily to handle require order)
local metrics


function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end


--- Rate-limited ssl_client_hello_phase wrapper
local function rate_limited_ssl_client_hello_phase()
    -- Lazy-load metrics on first call (init_worker must have run)
    if not metrics then
        local ok, m = pcall(require, "custom-metrics")
        if ok then
            metrics = m
        end
    end

    -- In ssl_client_hello phase, ngx.var.binary_remote_addr may not be available.
    -- Use ngx.var.remote_addr (text IP) as the rate-limit key instead.
    local ip_text = ngx.var.remote_addr
    if not ip_text then
        -- Cannot identify client — let APISIX handle it
        return original_ssl_client_hello_phase()
    end

    -- Extract SNI before any checks (needed for per-domain limiting)
    local sni, err = ssl_clt.get_client_hello_server_name()
    local domain   = sni or "no_sni"

    -- Whitelist bypass (Lua-native ipmatcher — geo/map vars not available in TLS phase)
    if whitelist_matcher and whitelist_matcher:match(ip_text) then
        if metrics then
            metrics.inc_counter("tls_clienthello_whitelisted_total")
            metrics.inc_counter("tls_clienthello_total", {domain = domain})
        end
        return original_ssl_client_hello_phase()
    end

    -- T0: TLS IP blocklist (fast path, keyed on text IP)
    local tbl = ngx.shared[DICT_BLOCKLIST]
    if tbl and tbl:get(ip_text) then
        if metrics then
            metrics.inc_counter("tls_clienthello_blocked_total", {reason = "blocklist"})
        end
        return ngx_exit(ngx.ERROR)
    end

    -- T1: Per-IP ClientHello rate
    local lim_ip, lerr = limit_req.new(DICT_PER_IP, conf.per_ip_rate, conf.per_ip_burst)
    if lim_ip then
        local delay, rerr = lim_ip:incoming(ip_text, true)
        if not delay then
            if rerr == "rejected" then
                -- Auto-block this IP
                if tbl then
                    tbl:set(ip_text, true, conf.block_ttl)
                end
                if metrics then
                    metrics.inc_counter("tls_clienthello_rejected_total", {layer = "per_ip"})
                    metrics.inc_counter("tls_ip_autoblock_total")
                end
                return ngx_exit(ngx.ERROR)
            end
            ngx_log(ngx_ERR, "tls hello per_ip: ", rerr)
        else
            if metrics then
                metrics.inc_counter("tls_clienthello_passed_total", {layer = "per_ip"})
            end
        end
    end

    -- T2: Per-SNI-domain ClientHello rate
    if sni then
        local lim_dom, lerr = limit_req.new(DICT_PER_DOMAIN, conf.per_domain_rate, conf.per_domain_burst)
        if lim_dom then
            local delay, rerr = lim_dom:incoming(sni, true)
            if not delay then
                if rerr == "rejected" then
                    if metrics then
                        metrics.inc_counter("tls_clienthello_rejected_total", {layer = "per_domain"})
                    end
                    return ngx_exit(ngx.ERROR)
                end
                ngx_log(ngx_ERR, "tls hello per_domain: ", rerr)
            else
                if metrics then
                    metrics.inc_counter("tls_clienthello_passed_total", {layer = "per_domain"})
                end
            end
        end
    else
        if metrics then
            metrics.inc_counter("tls_clienthello_no_sni_total")
        end
    end

    if metrics then
        metrics.inc_counter("tls_clienthello_total", {domain = domain})
    end

    -- All checks passed — call original APISIX phase
    return original_ssl_client_hello_phase()
end


function _M.init()
    -- Read plugin_attr configuration
    local attr = plugin.plugin_attr(plugin_name)
    if attr then
        if attr.per_ip_rate then conf.per_ip_rate = attr.per_ip_rate end
        if attr.per_ip_burst then conf.per_ip_burst = attr.per_ip_burst end
        if attr.per_domain_rate then conf.per_domain_rate = attr.per_domain_rate end
        if attr.per_domain_burst then conf.per_domain_burst = attr.per_domain_burst end
        if attr.block_ttl then conf.block_ttl = attr.block_ttl end
    end

    -- Wrap the global apisix.ssl_client_hello_phase
    -- `apisix` is a global set in init_by_lua_block (ngx_tpl.lua:512)
    if apisix and apisix.ssl_client_hello_phase then
        original_ssl_client_hello_phase = apisix.ssl_client_hello_phase
        apisix.ssl_client_hello_phase = rate_limited_ssl_client_hello_phase
        core.log.warn("tls-clienthello-limiter: wrapped ssl_client_hello_phase "
            .. "(per_ip_rate=", conf.per_ip_rate, ", per_domain_rate=", conf.per_domain_rate, ")")
    else
        core.log.error("tls-clienthello-limiter: apisix.ssl_client_hello_phase not found, "
            .. "plugin will not provide TLS rate limiting")
    end
end


function _M.init_worker()
    -- Start the custom metrics TTL sweeper
    local ok, m = pcall(require, "custom-metrics")
    if ok then
        metrics = m
        m.start_sweeper()
        core.log.warn("tls-clienthello-limiter: started custom-metrics sweeper "
            .. "(ttl=", m.default_ttl, "s, interval=", m.sweep_interval, "s)")
    else
        core.log.error("tls-clienthello-limiter: failed to load custom-metrics: ", m)
    end
end


function _M.destroy()
    -- Restore original function on plugin unload
    if original_ssl_client_hello_phase and apisix then
        apisix.ssl_client_hello_phase = original_ssl_client_hello_phase
        core.log.warn("tls-clienthello-limiter: restored original ssl_client_hello_phase")
    end
end


return _M
