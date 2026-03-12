-- =============================================================================
-- tls-clienthello-limiter.core — Platform-agnostic TLS ClientHello rate limiter
--
-- Multi-layer rate limiting for TLS ClientHello:
--   T0: IP blocklist (shared dict, binary keys)
--   T1: Per-IP rate (resty.limit.req, binary keys)
--   T2: Per-SNI-domain rate (resty.limit.req)
--
-- Usage:
--   local limiter = require("tls-clienthello-limiter.core")
--   local lim = limiter.new({ metrics = my_adapter })
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

-- Default configuration
local DEFAULTS = {
    per_ip_rate       = 2,
    per_ip_burst      = 4,
    per_domain_rate   = 5,
    per_domain_burst  = 10,
    block_ttl         = 10,
    dict_per_ip       = "tls-hello-per-ip",
    dict_per_domain   = "tls-hello-per-domain",
    dict_blocklist    = "tls-ip-blocklist",
}


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
--- @param opts table|nil Configuration overrides (all fields optional)
--- @return table Limiter object with check() method
function _M.new(opts)
    opts = opts or {}
    local conf = {}
    for k, v in pairs(DEFAULTS) do
        conf[k] = opts[k] or v
    end

    local self = {
        conf = conf,
        metrics = opts.metrics,
        blocklist_dict = ngx.shared[conf.dict_blocklist],
        lim_ip = nil,
        lim_dom = nil,
    }

    -- Create rate limiter objects (once, cached for all requests)
    local err
    self.lim_ip, err = limit_req.new(conf.dict_per_ip, conf.per_ip_rate, conf.per_ip_burst)
    if not self.lim_ip then
        ngx_log(ngx_ERR, "tls-limiter: failed to create per-ip limiter: ", err)
    end

    self.lim_dom, err = limit_req.new(conf.dict_per_domain, conf.per_domain_rate, conf.per_domain_burst)
    if not self.lim_dom then
        ngx_log(ngx_ERR, "tls-limiter: failed to create per-domain limiter: ", err)
    end

    return setmetatable(self, {__index = _M})
end


--- Check the current request against all rate limiting layers.
--- Must be called in ssl_client_hello_by_lua* context.
--- @return boolean rejected
--- @return string|nil reason ("blocklist", "per_ip", "per_domain")
function _M:check()
    local metrics = self.metrics

    -- Extract binary client IP
    local bin_key = extract_client_ip()
    if not bin_key then
        return false
    end

    -- T0: Blocklist (binary key, fast path)
    if self.blocklist_dict and self.blocklist_dict:get(bin_key) then
        if metrics then
            metrics.inc_counter("tls_clienthello_blocked_total", LABELS_BLOCKLIST)
        end
        return true, "blocklist"
    end

    -- Extract SNI (deferred past blocklist)
    local sni = ssl_clt.get_client_hello_server_name()

    -- T1: Per-IP rate limit (binary key)
    if self.lim_ip then
        local delay, rerr = self.lim_ip:incoming(bin_key, true)
        if not delay then
            if rerr == "rejected" then
                -- Auto-block
                if self.blocklist_dict then
                    self.blocklist_dict:set(bin_key, true, self.conf.block_ttl)
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

    return false
end


return _M
