-- =============================================================================
-- resty.clienthello.ratelimit — Platform-agnostic TLS ClientHello rate limiter
--
-- Multi-layer rate limiting for TLS ClientHello:
--   T0: IP blocklist (shared dict, binary keys)
--   T1: Per-IP rate (resty.limit.req, binary keys)
--   T2: Per-SNI-domain rate (resty.limit.req)
--
-- Usage:
--   local limiter = require("resty.clienthello.ratelimit")
--   local lim, warnings = limiter.new({
--       per_ip = { rate = 2, burst = 4, block_ttl = 10 },
--       per_domain = { rate = 5, burst = 10 },
--   }, my_metrics_adapter)
--   local rejected, reason = lim:check()
-- =============================================================================

local limit_req   = require("resty.limit.req")
local ssl_clt     = require("ngx.ssl.clienthello")
local ffi         = require("ffi")
local C           = ffi.C
local ffi_str     = ffi.string
local ffi_cast    = ffi.cast
local ffi_new     = ffi.new
local get_request = require("resty.core.base").get_request
local config      = require("resty.clienthello.ratelimit.config")

local ngx         = ngx
local ngx_log     = ngx.log
local ngx_ERR     = ngx.ERR

-- FFI declarations (pcall guards against redefinition)
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
  int ngx_http_lua_ffi_ssl_raw_client_addr(ngx_http_request_t *r,
      char **addr, size_t *addrlen, int *addrtype, char **err);
]])

-- Pre-allocated FFI output buffers (reused per-worker, single-thread safe)
local addr_pp  = ffi_new("char*[1]")
local sizep    = ffi_new("size_t[1]")
local typep    = ffi_new("int[1]")
local errmsgp  = ffi_new("char*[1]")

local ADDR_TYPE_INET  = 1
local ADDR_TYPE_INET6 = 2

-- Pre-allocated label tables (metrics adapter must not mutate these)
local LABELS_BLOCKLIST    = {reason = "blocklist"}
local LABELS_LAYER_IP     = {layer = "per_ip"}
local LABELS_LAYER_DOMAIN = {layer = "per_domain"}

-- Hardcoded shared dict names
local DICT_PER_IP    = "tls-hello-per-ip"
local DICT_PER_DOMAIN = "tls-hello-per-domain"
local DICT_BLOCKLIST  = "tls-ip-blocklist"


--- Extract binary client IP via FFI.
--- Returns binary key string (4 bytes IPv4, 16 bytes IPv6) or nil.
local function extract_client_ip()
    local r = get_request()
    if not r then return nil end

    local rc = C.ngx_http_lua_ffi_ssl_raw_client_addr(r, addr_pp, sizep, typep, errmsgp)
    if rc ~= 0 then return nil end

    local atype = typep[0]
    if atype == ADDR_TYPE_INET then
        local sa = ffi_cast("struct sockaddr_in*", addr_pp[0])
        return ffi_str(sa.sin_addr, 4)
    elseif atype == ADDR_TYPE_INET6 then
        local sa6 = ffi_cast("struct sockaddr_in6*", addr_pp[0])
        return ffi_str(sa6.sin6_addr, 16)
    end
    return nil
end


local _M = {}

-- Test hook: allows unit tests to replace extract_client_ip
function _M._set_extract_client_ip(fn)
    extract_client_ip = fn
end


--- Create a new rate limiter instance.
--- @param opts table|nil Config with optional per_ip and per_domain tables
--- @param metrics table|nil Metrics adapter with inc_counter(name, labels)
--- @return table|nil Limiter object, or nil on validation error
--- @return table|string Warnings list on success, or error string on failure
function _M.new(opts, metrics)
    local cfg, err = config.validate(opts)
    if not cfg then
        return nil, err
    end

    local self = {
        metrics = metrics,
        per_ip_enabled = cfg.per_ip ~= nil,
        per_domain_enabled = cfg.per_domain ~= nil,
        blocklist_dict = nil,
        block_ttl = nil,
        lim_ip = nil,
        lim_dom = nil,
    }

    if cfg.per_ip then
        self.block_ttl = cfg.per_ip.block_ttl
        self.blocklist_dict = ngx.shared[DICT_BLOCKLIST]

        local lim_ip, lerr = limit_req.new(DICT_PER_IP, cfg.per_ip.rate, cfg.per_ip.burst)
        if not lim_ip then
            ngx_log(ngx_ERR, "tls-limiter: failed to create per-ip limiter: ", lerr)
        end
        self.lim_ip = lim_ip
    end

    if cfg.per_domain then
        local lim_dom, lerr = limit_req.new(DICT_PER_DOMAIN, cfg.per_domain.rate, cfg.per_domain.burst)
        if not lim_dom then
            ngx_log(ngx_ERR, "tls-limiter: failed to create per-domain limiter: ", lerr)
        end
        self.lim_dom = lim_dom
    end

    local warnings = #cfg.warnings > 0 and cfg.warnings or nil
    return setmetatable(self, {__index = _M}), warnings
end


--- Check the current request against all rate limiting layers.
--- Must be called in ssl_client_hello_by_lua* context.
--- @return boolean rejected
--- @return string|nil reason ("blocklist", "per_ip", "per_domain")
function _M:check()
    -- Short-circuit if no tiers enabled (no-op limiter)
    if not self.per_ip_enabled and not self.per_domain_enabled then
        return false
    end

    local metrics = self.metrics

    -- Extract binary client IP
    local bin_key = extract_client_ip()
    if not bin_key then
        return false
    end

    -- T0: Blocklist (binary key, fast path)
    if self.per_ip_enabled and self.blocklist_dict and self.blocklist_dict:get(bin_key) then
        if metrics then
            metrics.inc_counter("tls_clienthello_blocked_total", LABELS_BLOCKLIST)
        end
        return true, "blocklist"
    end

    -- Extract SNI (deferred past blocklist)
    local sni = ssl_clt.get_client_hello_server_name()

    -- T1: Per-IP rate limit (binary key)
    if self.per_ip_enabled and self.lim_ip then
        local delay, rerr = self.lim_ip:incoming(bin_key, true)
        if not delay then
            if rerr == "rejected" then
                -- Auto-block
                if self.blocklist_dict then
                    self.blocklist_dict:set(bin_key, true, self.block_ttl)
                end
                if metrics then
                    metrics.inc_counter("tls_clienthello_rejected_total", LABELS_LAYER_IP)
                    metrics.inc_counter("tls_ip_autoblock_total")
                end
                return true, "per_ip"
            end
            ngx_log(ngx_ERR, "tls-limiter per_ip: ", rerr)
        else
            if metrics then
                metrics.inc_counter("tls_clienthello_passed_total", LABELS_LAYER_IP)
            end
        end
    end

    -- T2: Per-SNI rate limit
    if self.per_domain_enabled then
        if sni then
            if self.lim_dom then
                local delay, rerr = self.lim_dom:incoming(sni, true)
                if not delay then
                    if rerr == "rejected" then
                        if metrics then
                            metrics.inc_counter("tls_clienthello_rejected_total", LABELS_LAYER_DOMAIN)
                        end
                        return true, "per_domain"
                    end
                    ngx_log(ngx_ERR, "tls-limiter per_domain: ", rerr)
                else
                    if metrics then
                        metrics.inc_counter("tls_clienthello_passed_total", LABELS_LAYER_DOMAIN)
                    end
                end
            end
        else
            if metrics then
                metrics.inc_counter("tls_clienthello_no_sni_total")
            end
        end
    end

    return false
end


return _M
