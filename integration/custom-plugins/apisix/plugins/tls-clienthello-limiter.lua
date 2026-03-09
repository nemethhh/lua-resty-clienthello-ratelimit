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
local ffi          = require("ffi")
local C            = ffi.C
local ffi_str      = ffi.string
local ffi_cast     = ffi.cast
local ffi_new      = ffi.new
local get_request  = require("resty.core.base").get_request
local str_format   = string.format
local concat       = table.concat

local ngx          = ngx
local ngx_log      = ngx.log
local ngx_ERR      = ngx.ERR
local ngx_exit     = ngx.exit

-- FFI declarations for direct raw_client_addr access
ffi.cdef[[
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
  int ngx_http_lua_ffi_ssl_raw_client_addr(ngx_http_request_t *r,
      char **addr, size_t *addrlen, int *addrtype, char **err);
]]

-- Pre-allocated FFI output buffers (reused across requests, safe: single-thread per worker)
local addr_pp  = ffi_new("char*[1]")
local sizep    = ffi_new("size_t[1]")
local typep    = ffi_new("int[1]")
local errmsgp  = ffi_new("char*[1]")

-- addr_type constants from lua-resty-core (ngx/ssl.lua)
local ADDR_TYPE_INET  = 1
local ADDR_TYPE_INET6 = 2


--- Extract binary client IP via FFI. Returns (addr_ptr, addr_len, addr_type) or nil.
--- addr_ptr is a cdata pointer into the sockaddr — valid only for the current request.
local function extract_client_ip()
    local r = get_request()
    if not r then return nil end

    local rc = C.ngx_http_lua_ffi_ssl_raw_client_addr(r, addr_pp, sizep, typep, errmsgp)
    if rc ~= 0 then return nil end

    local atype = typep[0]
    if atype == ADDR_TYPE_INET then
        local sa = ffi_cast("struct sockaddr_in*", addr_pp[0])
        return sa.sin_addr, 4, atype
    elseif atype == ADDR_TYPE_INET6 then
        local sa6 = ffi_cast("struct sockaddr_in6*", addr_pp[0])
        return sa6.sin6_addr, 16, atype
    end
    return nil
end


--- Format binary IP address to text string (lazy — only called after blocklist miss).
local function binary_to_text_ip(addr_ptr, addr_len, addr_type)
    local b = ffi_cast("unsigned char*", addr_ptr)
    if addr_type == ADDR_TYPE_INET then
        return b[0] .. "." .. b[1] .. "." .. b[2] .. "." .. b[3]
    elseif addr_type == ADDR_TYPE_INET6 then
        local t = {}
        for i = 0, 14, 2 do
            t[#t + 1] = str_format("%x", b[i] * 256 + b[i + 1])
        end
        return concat(t, ":")
    end
    return nil
end

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

-- Cached objects (populated in init)
local cached_blocklist_dict   -- ngx.shared[DICT_BLOCKLIST]
local cached_lim_ip           -- limit_req object for per-IP
local cached_lim_dom          -- limit_req object for per-domain

-- Metrics library (resolved in init_worker only)
local metrics


function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end


--- Rate-limited ssl_client_hello_phase wrapper (optimized hot path)
local function rate_limited_ssl_client_hello_phase()
    -- FFI: extract binary client IP (no text formatting, no Lua string for sockaddr)
    local addr_ptr, addr_len, addr_type = extract_client_ip()
    if not addr_ptr then
        return original_ssl_client_hello_phase()
    end

    -- Binary key for blocklist (4 bytes IPv4, 16 bytes IPv6 — minimal allocation)
    local bin_key = ffi_str(addr_ptr, addr_len)

    -- Extract SNI before any checks (needed for per-domain limiting and metrics)
    local sni = ssl_clt.get_client_hello_server_name()
    local domain = sni or "no_sni"

    -- T0: TLS IP blocklist (fast path — binary key, no text formatting)
    if cached_blocklist_dict and cached_blocklist_dict:get(bin_key) then
        if metrics then
            metrics.inc_counter("tls_clienthello_blocked_total", {reason = "blocklist"})
        end
        return ngx_exit(ngx.ERROR)
    end

    -- Past blocklist — now we need text IP for whitelist and rate limiting
    local ip_text = binary_to_text_ip(addr_ptr, addr_len, addr_type)
    if not ip_text then
        return original_ssl_client_hello_phase()
    end

    -- Whitelist bypass (Lua-native ipmatcher — geo/map vars not available in TLS phase)
    if whitelist_matcher and whitelist_matcher:match(ip_text) then
        if metrics then
            metrics.inc_counter("tls_clienthello_whitelisted_total")
            metrics.inc_counter("tls_clienthello_total", {domain = domain})
        end
        return original_ssl_client_hello_phase()
    end

    -- T1: Per-IP ClientHello rate (cached limiter object)
    if cached_lim_ip then
        local delay, rerr = cached_lim_ip:incoming(ip_text, true)
        if not delay then
            if rerr == "rejected" then
                -- Auto-block this IP with binary key
                if cached_blocklist_dict then
                    cached_blocklist_dict:set(bin_key, true, conf.block_ttl)
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

    -- T2: Per-SNI-domain ClientHello rate (cached limiter object)
    if sni then
        if cached_lim_dom then
            local delay, rerr = cached_lim_dom:incoming(sni, true)
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

    -- Cache shared dict references
    cached_blocklist_dict = ngx.shared[DICT_BLOCKLIST]

    -- Cache limit_req objects (created once, not per-request)
    local err
    cached_lim_ip, err = limit_req.new(DICT_PER_IP, conf.per_ip_rate, conf.per_ip_burst)
    if not cached_lim_ip then
        core.log.error("tls-clienthello-limiter: failed to create per-ip limiter: ", err)
    end

    cached_lim_dom, err = limit_req.new(DICT_PER_DOMAIN, conf.per_domain_rate, conf.per_domain_burst)
    if not cached_lim_dom then
        core.log.error("tls-clienthello-limiter: failed to create per-domain limiter: ", err)
    end

    -- Wrap the global apisix.ssl_client_hello_phase
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
