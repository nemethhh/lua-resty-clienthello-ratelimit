# TLS ClientHello Limiter Performance Optimization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Optimize `tls-clienthello-limiter.lua` for zero-allocation blocked-IP hot path using FFI IP extraction, binary blocklist keys, lazy text formatting, and cached objects.

**Architecture:** Replace `ngx.ssl.raw_client_addr()` Lua wrapper with direct FFI call + sockaddr cast to extract binary IP. Cache `limit_req` objects and shared dict references at init. Defer text IP formatting until after blocklist miss.

**Tech Stack:** LuaJIT FFI, OpenResty `ngx_http_lua_ffi_ssl_raw_client_addr`, `resty.limit.req`, `resty.ipmatcher`, `ngx.shared` Lua API

**Design doc:** `docs/plans/2026-03-09-tls-limiter-perf-design.md`

---

### Task 1: Add FFI declarations and IP extraction function

**Files:**
- Modify: `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua:16-23`

**Step 1: Add FFI infrastructure**

Replace the current requires/locals block (lines 16-28) with the optimized version. Add sockaddr struct definitions, pre-allocated FFI buffers, and the `extract_client_ip` helper.

```lua
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
```

**Step 2: Remove old `ssl_mod` require**

The `local ssl_mod = require("ngx.ssl")` line (old line 18) is no longer needed since we call the FFI function directly. Verify it is not present in the new code above (it isn't).

**Step 3: Verify the file loads syntactically**

Run: `docker compose -f docker-compose.unit.yml run --rm unit-tests luajit -e "local ffi=require('ffi'); print('OK')"`
Expected: `OK` (confirms LuaJIT FFI is available in the test container)

**Step 4: Commit**

```bash
git add integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "perf(tls-limiter): add FFI IP extraction with sockaddr cast"
```

---

### Task 2: Cache limit_req objects and shared dict references at init

**Files:**
- Modify: `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` — module-level locals and `_M.init()`

**Step 1: Add cached object declarations**

Replace the current module-level section (after conf table, around lines 67-76) with:

```lua
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
```

**Step 2: Update `_M.init()` to create cached objects**

Replace the current `_M.init()` function with:

```lua
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
```

**Step 3: Commit**

```bash
git add integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "perf(tls-limiter): cache limit_req objects and shared dict refs at init"
```

---

### Task 3: Rewrite hot path with binary blocklist and lazy text formatting

**Files:**
- Modify: `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` — `rate_limited_ssl_client_hello_phase()`

**Step 1: Replace the hot path function**

Replace the entire `rate_limited_ssl_client_hello_phase` function with:

```lua
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
```

**Step 2: Verify `init_worker` has no hot-path pcall**

Confirm `init_worker()` is unchanged (metrics resolved there, not in hot path). The existing `init_worker` is already correct — no changes needed.

**Step 3: Commit**

```bash
git add integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "perf(tls-limiter): binary blocklist keys and lazy text formatting in hot path"
```

---

### Task 4: Verify complete file is correct

**Files:**
- Review: `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua`

**Step 1: Read the full file and verify**

Read the complete file. Verify:
- No `require("ngx.ssl")` — removed (replaced by FFI)
- No `limit_req.new()` in hot path — only in `init()`
- No `ngx.shared[DICT_*]` in hot path — only cached refs
- No `pcall(require, "custom-metrics")` in hot path — only in `init_worker()`
- `extract_client_ip()` returns cdata pointer + length + type
- `binary_to_text_ip()` only called after blocklist miss
- Blocklist uses `bin_key` (binary) for both get and set
- `destroy()` still restores original function

**Step 2: Run a Lua syntax check**

Run: `docker compose -f docker-compose.unit.yml run --rm unit-tests luajit -bl integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua /dev/null 2>&1 || echo "SYNTAX ERROR"`

Note: This may fail due to missing APISIX requires in the unit container — that's expected. What matters is no syntax errors. Alternatively:

Run: `luajit -e "local f=loadfile('integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua'); if f then print('SYNTAX OK') else print('SYNTAX ERROR') end"`

Expected: `SYNTAX OK` (or load error from missing modules, but NOT a syntax error)

---

### Task 5: Run integration tests

**Files:**
- Test: `integration/tests/test_tls_rate_limit.py`
- Test: `integration/tests/test_whitelist.py`
- Test: `integration/tests/test_custom_metrics.py`

**Step 1: Run full integration test suite**

Run: `make integration`

Expected: All tests pass. The integration tests exercise TLS handshakes via Python `ssl` module and check metrics via HTTP — they don't care about internal key formats (binary vs text).

**Step 2: If any test fails, debug**

Check APISIX error logs:
Run: `docker compose -f docker-compose.integration.yml logs apisix 2>&1 | tail -50`

Common issues to look for:
- `ffi.cdef` duplicate definition errors — wrap in `pcall` if needed
- `get_request()` returning nil — check phase compatibility
- `sockaddr_in` struct layout mismatch — verify on Linux (the target platform)

**Step 3: Commit passing state (if any test fixes were needed)**

```bash
git add integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "fix(tls-limiter): resolve integration test issues after perf optimization"
```

---

### Task 6: Guard ffi.cdef against duplicate definitions

**Files:**
- Modify: `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` — ffi.cdef block

**Step 1: Wrap ffi.cdef in pcall**

OpenResty may load this module multiple times. Wrap the `ffi.cdef` block to avoid "attempt to redefine" errors:

```lua
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
```

Note: The `ngx_http_lua_ffi_ssl_raw_client_addr` function is already declared by lua-resty-core's `ngx/ssl.lua`. The sockaddr structs may or may not be declared elsewhere. The `pcall` wrapper is defensive and costs nothing at load time.

**Step 2: Run integration tests again**

Run: `make integration`
Expected: All tests pass.

**Step 3: Commit**

```bash
git add integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "fix(tls-limiter): guard ffi.cdef against duplicate definitions"
```
