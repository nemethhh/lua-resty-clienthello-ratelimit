# TLS ClientHello Limiter Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the monolithic `tls-clienthello-limiter` APISIX plugin into a platform-agnostic core library + thin APISIX and OpenResty adapters, removing custom-metrics and IP whitelisting.

**Architecture:** Core module (`core.lua`) owns all rate-limiting logic and FFI IP extraction. Two adapter modules provide platform-specific glue: APISIX adapter (monkey-patch + plugin lifecycle) and OpenResty adapter (prometheus init + `ssl_client_hello_by_lua_block` wiring). Metrics are injected via a simple adapter table (`{inc_counter = fn}`).

**Tech Stack:** Lua/LuaJIT, OpenResty, resty.limit.req, ngx.ssl.clienthello, FFI, nginx-lua-prometheus (api7 fork with TTL), busted (unit tests), pytest (integration tests)

**Spec:** `docs/superpowers/specs/2026-03-12-tls-limiter-refactor-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|---|---|
| `integration/custom-plugins/tls-clienthello-limiter/core.lua` | Platform-agnostic rate limiting: FFI IP extraction, blocklist, per-IP and per-SNI rate limits, metrics emission |
| `integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua` | APISIX plugin wrapper: plugin_attr config, prometheus bridge, monkey-patch lifecycle |
| `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua` | OpenResty helper: prometheus init with TTL, ssl_client_hello_by_lua_block entry point |
| `unit/lua/tls-clienthello-limiter/core.lua` | Copy of core.lua for unit test runner |
| `unit/spec/tls_limiter_core_spec.lua` | Unit tests for core.lua |
| `unit/spec/core_helpers.lua` | Extended mock helpers for core.lua tests (shared dict + FFI stubs) |
| `integration/tests/test_healthz.py` | Healthz endpoint test (moved from deleted test_whitelist.py) |

### Modified Files
| File | Changes |
|---|---|
| `integration/conf/config.yaml` | Update `extra_lua_path` for new module path, remove `custom-metrics`/`custom-metrics-timestamps` shared dicts, update metrics endpoint to use APISIX prometheus |
| `integration/tests/test_tls_rate_limit.py` | Remove references to `tls_clienthello_total` metric, update metric assertions |
| `integration/tests/conftest.py` | Update `metrics_url` to use APISIX prometheus endpoint (port 9091), move healthz test from deleted test_whitelist.py |
| `docker-compose.integration.yml` | Update APISIX_METRICS_URL env var |

### Deleted Files
| File | Reason |
|---|---|
| `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua` | Overwritten with shim that delegates to `adapters/apisix.lua` |
| `integration/custom-plugins/custom-metrics.lua` | Replaced by native prometheus |
| `integration/tests/test_custom_metrics.py` | Tests custom-metrics module which is removed |
| `integration/tests/test_whitelist.py` | Whitelist feature removed; healthz test moved to `test_healthz.py` |
| `unit/lua/custom-metrics.lua` | Replaced by native prometheus |
| `unit/spec/custom_metrics_spec.lua` | Tests removed module |

---

## Chunk 1: Core Module

### Task 1: Create unit test helpers for core.lua

**Files:**
- Create: `unit/spec/core_helpers.lua`

- [ ] **Step 1: Write the core test helper module**

This extends the existing `spec.helpers` pattern with mocks for the FFI and SSL APIs that `core.lua` depends on.

```lua
-- core_helpers.lua — mocks for tls-clienthello-limiter.core unit tests
local helpers = require("spec.helpers")
local _M = {}

-- Mock state
local mock_bin_ip = nil       -- binary IP to return from extract_client_ip
local mock_sni = nil          -- SNI to return from get_client_hello_server_name
local mock_request = true     -- whether get_request() returns a request

-- =========================================================================
-- Setup: creates shared dicts and installs mocks
-- =========================================================================
function _M.setup(opts)
    opts = opts or {}
    helpers.setup({
        opts.dict_per_ip or "tls-hello-per-ip",
        opts.dict_per_domain or "tls-hello-per-domain",
        opts.dict_blocklist or "tls-ip-blocklist",
    })

    mock_bin_ip = opts.bin_ip or string.char(10, 0, 0, 1)  -- 10.0.0.1
    mock_sni = opts.sni or "test.example.com"
    mock_request = opts.has_request ~= false

    -- Stub out modules that core.lua requires
    -- resty.limit.req — use real shared dict mock
    package.loaded["resty.limit.req"] = _M.make_limit_req_mock()
    -- ngx.ssl.clienthello
    package.loaded["ngx.ssl.clienthello"] = {
        get_client_hello_server_name = function()
            return mock_sni
        end,
    }
    -- resty.core.base
    package.loaded["resty.core.base"] = {
        get_request = function()
            return mock_request and {} or nil
        end,
    }

    -- Clear cached core module
    package.loaded["tls-clienthello-limiter.core"] = nil
end

-- =========================================================================
-- limit_req mock — uses ngx.shared dict for state like the real one
-- =========================================================================
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
        -- Simple mock: track calls per key, reject after rate+burst
        local count = (self._call_count[key] or 0) + 1
        if commit then
            self._call_count[key] = count
        end
        local limit = self.rate + self.burst
        if count > limit then
            return nil, "rejected"
        end
        return 0  -- delay=0 means allowed
    end

    return limit_req
end

-- =========================================================================
-- FFI stub — core.lua uses ffi.cdef and ffi.C calls.
-- We override extract_client_ip after require by patching the module.
-- Since core.lua uses FFI internally, we need to stub at a higher level.
-- Strategy: after requiring core, replace the internal extract function.
-- =========================================================================

--- Load core.lua and patch its internal FFI to use mock data.
--- Returns the core module with extract_client_ip stubbed.
function _M.require_core()
    -- We need to handle FFI. Since core.lua calls ffi.cdef at load time,
    -- and the FFI structs won't work outside OpenResty, we create a
    -- modified loader that replaces the FFI path.
    --
    -- Approach: we set up package.preload to return a module that
    -- builds core with injected extract_client_ip.

    -- First, provide a minimal ffi mock
    if not pcall(require, "ffi") then
        package.loaded["ffi"] = _M.make_ffi_mock()
    end

    local core = require("tls-clienthello-limiter.core")
    -- Patch the internal extract function via the test hook
    if core._set_extract_client_ip then
        core._set_extract_client_ip(function()
            if not mock_request then return nil end
            return mock_bin_ip
        end)
    end
    return core
end

-- Minimal ffi mock for environments without LuaJIT
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

-- =========================================================================
-- Helpers for tests
-- =========================================================================

function _M.set_mock_ip(bin_ip)
    mock_bin_ip = bin_ip
end

function _M.set_mock_sni(sni)
    mock_sni = sni
end

function _M.set_mock_request(has_request)
    mock_request = has_request
end

--- Build a metrics spy that records all inc_counter calls.
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
```

- [ ] **Step 2: Verify helper loads without errors**

Run: `cd /home/am/Work/cdn-harden/test-harness && docker compose -f docker-compose.unit.yml build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add unit/spec/core_helpers.lua
git commit -m "test: add unit test helpers for tls-limiter core module"
```

---

### Task 2: Write core.lua

**Files:**
- Create: `integration/custom-plugins/tls-clienthello-limiter/core.lua`
- Create: `unit/lua/tls-clienthello-limiter/core.lua` (copy for unit test runner)

- [ ] **Step 1: Write failing unit test for core.new() defaults**

Create `unit/spec/tls_limiter_core_spec.lua`:

```lua
local ch = require("spec.core_helpers")

describe("tls-clienthello-limiter.core", function()
    local core, spy

    before_each(function()
        spy = ch.make_metrics_spy()
        ch.setup({sni = "test.example.com"})
    end)

    describe("new()", function()
        it("creates a limiter with defaults", function()
            local core = ch.require_core()
            local lim = core.new()
            assert.is_not_nil(lim)
            assert.is_function(lim.check)
        end)

        it("creates a limiter with custom config", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 10,
                per_ip_burst = 20,
                metrics = spy,
            })
            assert.is_not_nil(lim)
        end)

        it("creates a limiter with no shared dicts gracefully", function()
            ch.setup({dict_per_ip = "nonexistent-a", dict_per_domain = "nonexistent-b", dict_blocklist = "nonexistent-c"})
            local core = ch.require_core()
            local lim = core.new({
                dict_per_ip = "nonexistent-a",
                dict_per_domain = "nonexistent-b",
                dict_blocklist = "nonexistent-c",
            })
            assert.is_not_nil(lim)
        end)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/am/Work/cdn-harden/test-harness && docker compose -f docker-compose.unit.yml run --rm unit-tests busted spec/tls_limiter_core_spec.lua`
Expected: FAIL — module `tls-clienthello-limiter.core` not found

- [ ] **Step 3: Write core.lua implementation**

```lua
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
```

- [ ] **Step 4: Create the file and copy for unit tests**

Create `integration/custom-plugins/tls-clienthello-limiter/core.lua` with the code above.
Create `unit/lua/tls-clienthello-limiter/core.lua` as a copy.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /home/am/Work/cdn-harden/test-harness && docker compose -f docker-compose.unit.yml run --rm unit-tests busted spec/tls_limiter_core_spec.lua`
Expected: 3 passing tests

- [ ] **Step 6: Commit**

```bash
git add integration/custom-plugins/tls-clienthello-limiter/core.lua \
        unit/lua/tls-clienthello-limiter/core.lua \
        unit/spec/tls_limiter_core_spec.lua
git commit -m "feat: add tls-clienthello-limiter core module with unit tests"
```

---

### Task 3: Unit tests for core.check() — all decision paths

**Files:**
- Modify: `unit/spec/tls_limiter_core_spec.lua`

- [ ] **Step 1: Add check() tests for each path**

Append to `tls_limiter_core_spec.lua`:

```lua
    describe("check()", function()
        it("returns false when no request context", function()
            ch.set_mock_request(false)
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            local rejected, reason = lim:check()
            assert.is_false(rejected)
            assert.is_nil(reason)
        end)

        it("returns true,'blocklist' for blocked IP", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            -- Pre-populate blocklist
            local dict = ngx.shared["tls-ip-blocklist"]
            local bin_ip = string.char(10, 0, 0, 1)
            dict:set(bin_ip, true, 60)
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
            assert.is_not_nil(spy.find("tls_clienthello_blocked_total"))
        end)

        it("returns false for a normal request", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            local rejected = lim:check()
            assert.is_false(rejected)
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
        end)

        it("returns true,'per_ip' after exceeding per-IP rate+burst", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 2,
                per_ip_burst = 4,
                metrics = spy,
            })
            -- rate+burst = 6, so 7th call should be rejected
            for i = 1, 6 do
                local rejected = lim:check()
                assert.is_false(rejected, "call " .. i .. " should pass")
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_ip", reason)
            -- Should have auto-blocked
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)

        it("returns true,'per_domain' after exceeding per-domain rate+burst", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            -- High per-IP limit so it doesn't trigger first
            local lim = core.new({
                per_ip_rate = 100,
                per_ip_burst = 100,
                per_domain_rate = 2,
                per_domain_burst = 2,
                metrics = spy,
            })
            for i = 1, 4 do
                lim:check()
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_domain", reason)
        end)

        it("emits tls_clienthello_no_sni_total when no SNI", function()
            ch.setup({sni = nil})
            local core = ch.require_core()
            local lim = core.new({metrics = spy})
            lim:check()
            assert.is_not_nil(spy.find("tls_clienthello_no_sni_total"))
        end)

        it("works without metrics adapter (nil)", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new()  -- no metrics
            local rejected = lim:check()
            assert.is_false(rejected)
        end)

        it("after auto-block, subsequent calls hit blocklist", function()
            ch.setup({sni = "test.example.com"})
            local core = ch.require_core()
            local lim = core.new({
                per_ip_rate = 1,
                per_ip_burst = 1,
                metrics = spy,
            })
            -- Exhaust: 2 pass, 3rd rejected + auto-blocked
            lim:check()
            lim:check()
            lim:check()
            -- Now should hit blocklist path
            spy = ch.make_metrics_spy()
            lim.metrics = spy
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
        end)
    end)
```

- [ ] **Step 2: Run tests**

Run: `cd /home/am/Work/cdn-harden/test-harness && docker compose -f docker-compose.unit.yml run --rm unit-tests busted spec/tls_limiter_core_spec.lua`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add unit/spec/tls_limiter_core_spec.lua
git commit -m "test: add check() unit tests for all core decision paths"
```

---

## Chunk 2: Adapters and Integration

### Task 4: Write APISIX adapter

**Files:**
- Create: `integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua`

- [ ] **Step 1: Write the APISIX adapter**

```lua
-- =============================================================================
-- tls-clienthello-limiter APISIX adapter
--
-- Thin wrapper: reads plugin_attr config, bridges APISIX prometheus for metrics,
-- monkey-patches apisix.ssl_client_hello_phase with core.check().
-- =============================================================================

local core_mod = require("tls-clienthello-limiter.core")
local apisix_core = require("apisix.core")
local plugin = require("apisix.plugin")

local ngx      = ngx
local ngx_exit = ngx.exit

local plugin_name = "tls-clienthello-limiter"

local _M = {
    name     = plugin_name,
    version  = 0.2,
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
    return apisix_core.schema.check(_M.schema, conf)
end


--- Build a metrics adapter that bridges to APISIX's prometheus.
local function build_metrics_adapter()
    local ok, prometheus_mod = pcall(require, "apisix.plugins.prometheus.exporter")
    if not ok or not prometheus_mod then
        return nil
    end

    -- The APISIX prometheus exporter exposes a prometheus object.
    -- We create counters lazily on first use.
    local counters = {}

    return {
        inc_counter = function(name, labels)
            -- Use APISIX's prometheus instance if available
            local p = prometheus_mod.get_prometheus()
            if not p then return end

            if not counters[name] then
                -- Collect label names from the labels table
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
    local opts = {}
    if attr then
        for k, v in pairs(attr) do
            opts[k] = v
        end
    end

    -- Build metrics adapter
    opts.metrics = build_metrics_adapter()

    -- Create core limiter
    lim = core_mod.new(opts)

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
        apisix_core.log.warn("tls-clienthello-limiter: wrapped ssl_client_hello_phase"
            .. " (per_ip_rate=", opts.per_ip_rate or 2,
            ", per_domain_rate=", opts.per_domain_rate or 5,
            ", block_ttl=", opts.block_ttl or 10, ")")
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
```

- [ ] **Step 2: Commit**

```bash
git add integration/custom-plugins/tls-clienthello-limiter/adapters/apisix.lua
git commit -m "feat: add APISIX adapter for tls-clienthello-limiter"
```

---

### Task 5: Write OpenResty adapter

**Files:**
- Create: `integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua`

- [ ] **Step 1: Write the OpenResty adapter**

```lua
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

    -- Set up prometheus metrics adapter if prometheus instance provided
    local metrics_adapter = nil
    if opts.prometheus then
        metrics_adapter = build_metrics_adapter(opts.prometheus, opts.metrics_exptime or 300)
    else
        -- Try to create prometheus instance from shared dict
        local ok, prometheus_lib = pcall(require, "prometheus")
        if ok then
            local dict_name = opts.prometheus_dict or "prometheus-metrics"
            local p = prometheus_lib.init(dict_name)
            if p then
                metrics_adapter = build_metrics_adapter(p, opts.metrics_exptime or 300)
            end
        end
    end

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
```

- [ ] **Step 2: Commit**

```bash
git add integration/custom-plugins/tls-clienthello-limiter/adapters/openresty.lua
git commit -m "feat: add OpenResty adapter for tls-clienthello-limiter"
```

---

### Task 6: Update APISIX config for new module path

**Files:**
- Modify: `integration/conf/config.yaml`

- [ ] **Step 1: Update config.yaml**

Changes needed:
1. Update `extra_lua_path` to resolve `tls-clienthello-limiter.core` and `tls-clienthello-limiter.adapters.apisix`. The current path `/usr/local/apisix/custom-plugins/?.lua` already handles `require("tls-clienthello-limiter.core")` since it maps to `custom-plugins/tls-clienthello-limiter/core.lua`. But the APISIX plugin loader looks for `apisix.plugins.<name>`, so the adapter must be at `apisix/plugins/tls-clienthello-limiter.lua` OR we create a shim.

   The simplest approach: keep a shim file at `apisix/plugins/tls-clienthello-limiter.lua` that just returns the adapter:
   ```lua
   return require("tls-clienthello-limiter.adapters.apisix")
   ```

2. Remove `custom-metrics` and `custom-metrics-timestamps` shared dicts.

3. Remove the custom `/metrics` endpoint (custom-metrics serialization). Keep the `/healthz` endpoint on port 9092.

4. Enable the APISIX prometheus plugin's standalone export server on port 9091 (`enable_export_server: true`). This makes metrics available at `http://apisix:9091/apisix/prometheus/metrics` without needing the control API.

5. Remove the `geo`/`map` nginx snippet — it was only used for the HTTP-level whitelist which is separate from the TLS plugin. The TLS plugin's whitelist is removed in this refactor, and the HTTP-level geo/map is not used by the TLS limiter. **Note:** If the geo/map is used by other `limit_req_zone` directives or HTTP-level rate limiting outside this plugin, keep it. For this test harness it is unused, so we remove it.

Updated `config.yaml`:

```yaml
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml

apisix:
  node_listen:
    - port: 80
  ssl:
    enable: true
    listen:
      - port: 443
  extra_lua_path: "/usr/local/apisix/custom-plugins/?.lua"

# Root-level plugins list (replaces defaults — must include all needed plugins)
plugins:
  - tls-clienthello-limiter       # custom plugin
  - proxy-rewrite
  - prometheus
  - real-ip
  - limit-conn
  - limit-count
  - limit-req
  - redirect
  - response-rewrite
  - grpc-transcode
  - grpc-web
  - public-api
  - serverless-pre-function
  - serverless-post-function
  - ext-plugin-pre-req
  - ext-plugin-post-req
  - ext-plugin-post-resp
  - ip-restriction
  - ua-restriction
  - key-auth
  - basic-auth
  - jwt-auth
  - consumer-restriction

nginx_config:
  http:
    custom_lua_shared_dict:
      tls-hello-per-ip: 1m
      tls-hello-per-domain: 1m
      tls-ip-blocklist: 1m

  http_end_configuration_snippet: |
    server {
        listen 0.0.0.0:9092;
        server_name _;

        location = /healthz {
            access_log off;
            return 200 'ok';
        }
    }

plugin_attr:
  tls-clienthello-limiter:
    per_ip_rate: 2
    per_ip_burst: 4
    per_domain_rate: 5
    per_domain_burst: 10
    block_ttl: 10
  prometheus:
    enable_export_server: true
    export_addr:
      ip: "0.0.0.0"
      port: 9091
```

- [ ] **Step 2: Create the APISIX plugin shim**

Create `integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua`:

```lua
-- Shim: APISIX plugin loader expects apisix.plugins.<name>
-- Delegates to the actual adapter module
return require("tls-clienthello-limiter.adapters.apisix")
```

- [ ] **Step 3: Commit**

```bash
git add integration/conf/config.yaml \
        integration/custom-plugins/apisix/plugins/tls-clienthello-limiter.lua
git commit -m "feat: update APISIX config for new module structure"
```

---

### Task 7: Update integration tests

**Files:**
- Modify: `integration/tests/test_tls_rate_limit.py`
- Modify: `integration/tests/conftest.py`
- Delete: `integration/tests/test_custom_metrics.py`
- Delete: `integration/tests/test_whitelist.py`

- [ ] **Step 1: Update conftest.py**

The metrics URL now points to APISIX's built-in prometheus endpoint. APISIX prometheus plugin exposes metrics on its admin/control API or a dedicated port. With `enable_export_server: false` the metrics are on the control API. For simplicity, we'll use the APISIX prometheus public-api approach or keep the 9092 port for healthz only.

Actually, the simplest approach: APISIX prometheus plugin can expose metrics via a route with `public-api` plugin. But for test harness simplicity, we keep the existing 9092 server for `/healthz` and use APISIX's built-in prometheus endpoint at `http://apisix:9091/apisix/prometheus/metrics` (control API).

Update `conftest.py`:

```python
import os
import ssl
import socket
import time

import pytest
import requests


APISIX_HTTP_URL = os.environ.get("APISIX_HTTP_URL", "http://apisix:80")
APISIX_HTTPS_HOST = os.environ.get("APISIX_HTTPS_HOST", "apisix")
APISIX_HTTPS_PORT = int(os.environ.get("APISIX_HTTPS_PORT", "443"))
APISIX_METRICS_URL = os.environ.get(
    "APISIX_METRICS_URL", "http://apisix:9091/apisix/prometheus/metrics"
)
TEST_DOMAIN = os.environ.get("TEST_DOMAIN", "test.example.com")
CERT_PATH = "/certs/server.crt"


@pytest.fixture(scope="session")
def apisix_http_url():
    return APISIX_HTTP_URL


@pytest.fixture(scope="session")
def apisix_https_host():
    return APISIX_HTTPS_HOST


@pytest.fixture(scope="session")
def apisix_https_port():
    return APISIX_HTTPS_PORT


@pytest.fixture(scope="session")
def metrics_url():
    return APISIX_METRICS_URL


@pytest.fixture(scope="session")
def test_domain():
    return TEST_DOMAIN


@pytest.fixture(scope="session")
def ssl_context():
    """SSL context that trusts the self-signed test cert."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(CERT_PATH)
    return ctx


def tls_handshake(host, port, sni, ctx=None, timeout=5):
    """Perform a TLS handshake and return True on success, False on failure."""
    if ctx is None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    ssl_sock = ctx.wrap_socket(sock, server_hostname=sni)
    try:
        ssl_sock.connect((host, port))
        return True
    except (ssl.SSLError, ConnectionResetError, ConnectionRefusedError, OSError):
        return False
    finally:
        ssl_sock.close()


@pytest.fixture(scope="session")
def do_tls_handshake(apisix_https_host, apisix_https_port):
    """Returns a callable that performs a TLS handshake to APISIX."""
    def _handshake(sni=TEST_DOMAIN, timeout=5):
        return tls_handshake(apisix_https_host, apisix_https_port, sni, timeout=timeout)
    return _handshake


def fetch_metrics(url=None):
    """Fetch and return the raw metrics text from the prometheus endpoint."""
    resp = requests.get(url or APISIX_METRICS_URL, timeout=5)
    resp.raise_for_status()
    return resp.text


@pytest.fixture
def get_metrics(metrics_url):
    """Returns a callable that fetches metrics text."""
    def _fetch():
        return fetch_metrics(metrics_url)
    return _fetch
```

- [ ] **Step 2: Update test_tls_rate_limit.py**

Remove references to `tls_clienthello_total`. The `tls_clienthello_whitelisted_total` references are already gone (only in test_whitelist.py which is deleted).

```python
"""Integration tests for TLS ClientHello rate limiting."""

import time

import requests


class TestTlsPerIpRateLimit:
    def test_normal_handshake_succeeds(self, do_tls_handshake):
        """A single TLS handshake should succeed."""
        assert do_tls_handshake() is True

    def test_rapid_handshakes_get_rejected(self, do_tls_handshake):
        """Flooding TLS handshakes beyond per_ip_rate+burst should fail.

        Config: per_ip_rate=2, per_ip_burst=4.
        The leaky bucket allows rate+burst=6 before rejecting.
        We send 20 rapid handshakes and expect some to fail.
        """
        results = []
        for _ in range(20):
            results.append(do_tls_handshake(timeout=2))

        successes = sum(1 for r in results if r)
        failures = sum(1 for r in results if not r)

        # At least some should succeed (the first few)
        assert successes > 0, "Expected at least some successful handshakes"
        # At least some should be rejected
        assert failures > 0, "Expected at least some rejected handshakes"

    def test_rejected_ip_gets_auto_blocked(self, do_tls_handshake, get_metrics):
        """After rejection, the IP should be auto-blocked.

        The tls_ip_autoblock_total counter should increment.
        """
        # Flood to trigger auto-block
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert "tls_ip_autoblock_total" in metrics or "tls_clienthello_rejected_total" in metrics

    def test_blocked_handshakes_fail_immediately(self, do_tls_handshake):
        """Once IP is blocked, handshakes should fail immediately."""
        # First flood to trigger block
        for _ in range(30):
            do_tls_handshake(timeout=1)

        # Now all should fail (blocked)
        time.sleep(0.5)
        results = [do_tls_handshake(timeout=2) for _ in range(5)]
        failures = sum(1 for r in results if not r)
        assert failures >= 3, f"Expected mostly failures after block, got {failures}/5"

    def test_block_expires_after_ttl(self, do_tls_handshake):
        """After block_ttl (10s), the IP should be unblocked."""
        # Flood to trigger block
        for _ in range(30):
            do_tls_handshake(timeout=1)

        # Wait for block to expire (block_ttl=10)
        time.sleep(12)

        # Should succeed again
        assert do_tls_handshake() is True


class TestTlsPerDomainRateLimit:
    def test_per_domain_limit_triggers(self, do_tls_handshake, get_metrics):
        """Flooding a single domain should trigger per-domain rejection.

        Config: per_domain_rate=5, per_domain_burst=10.
        """
        # Wait for any previous per-IP block to clear
        time.sleep(12)

        for _ in range(30):
            do_tls_handshake(sni="test.example.com", timeout=1)

        metrics = get_metrics()
        # Should see per_domain rejections in metrics
        assert "tls_clienthello_rejected_total" in metrics


class TestTlsMetricsCounters:
    def test_passed_counter_increments(self, do_tls_handshake, get_metrics):
        """Successful handshakes should increment passed counter."""
        # Wait for any blocks to expire
        time.sleep(12)

        do_tls_handshake()
        metrics = get_metrics()
        assert "tls_clienthello_passed_total" in metrics

    def test_blocked_counter_increments(self, do_tls_handshake, get_metrics):
        """After flooding, blocked counter should appear."""
        for _ in range(30):
            do_tls_handshake(timeout=1)

        metrics = get_metrics()
        assert ("tls_clienthello_blocked_total" in metrics
                or "tls_clienthello_rejected_total" in metrics)
```

- [ ] **Step 3: Create test_healthz.py (preserved from deleted test_whitelist.py)**

```python
"""Integration test for the healthz endpoint (Docker healthcheck)."""

import requests


class TestHealthz:
    def test_healthz_endpoint_works(self, metrics_url):
        """The /healthz endpoint (used for Docker healthcheck) should respond."""
        # Healthz is on port 9092, metrics is on 9091 — derive base from env
        import os
        healthz_url = "http://" + os.environ.get("APISIX_HTTPS_HOST", "apisix") + ":9092/healthz"
        resp = requests.get(healthz_url, timeout=5)
        assert resp.status_code == 200
        assert resp.text.strip() == "ok"
```

- [ ] **Step 4: Delete removed test files**

```bash
rm integration/tests/test_custom_metrics.py
rm integration/tests/test_whitelist.py
```

- [ ] **Step 5: Update docker-compose.integration.yml**

Update the `APISIX_METRICS_URL` environment variable to point at the prometheus export server on port 9091:

```yaml
      APISIX_METRICS_URL: "http://apisix:9091/apisix/prometheus/metrics"
```

- [ ] **Step 6: Commit**

```bash
git add integration/tests/conftest.py \
        integration/tests/test_tls_rate_limit.py \
        integration/tests/test_healthz.py \
        docker-compose.integration.yml
git rm integration/tests/test_custom_metrics.py \
       integration/tests/test_whitelist.py
git commit -m "test: update integration tests for core/adapter split"
```

---

### Task 8: Clean up removed files

**Files:**
- Delete: `integration/custom-plugins/custom-metrics.lua`
- Delete: `unit/lua/custom-metrics.lua`
- Delete: `unit/spec/custom_metrics_spec.lua`

- [ ] **Step 1: Remove old files**

```bash
git rm integration/custom-plugins/custom-metrics.lua \
       unit/lua/custom-metrics.lua \
       unit/spec/custom_metrics_spec.lua
```

- [ ] **Step 2: Update unit test helpers**

In `unit/spec/helpers.lua`, the `setup()` function clears `package.loaded["custom-metrics"]`. This should be updated to clear the new module instead. Edit line 135:

Change:
```lua
    package.loaded["custom-metrics"] = nil
```
To:
```lua
    package.loaded["custom-metrics"] = nil
    package.loaded["tls-clienthello-limiter.core"] = nil
```

- [ ] **Step 3: Commit**

```bash
git add unit/spec/helpers.lua
git rm integration/custom-plugins/custom-metrics.lua \
       unit/lua/custom-metrics.lua \
       unit/spec/custom_metrics_spec.lua
git commit -m "refactor: remove custom-metrics module and its tests"
```

---

## Chunk 3: Verification

### Task 9: Run full test suite

- [ ] **Step 1: Run unit tests**

```bash
cd /home/am/Work/cdn-harden/test-harness
make unit
```

Expected: All unit tests pass (only `tls_limiter_core_spec.lua` remains).

- [ ] **Step 2: Run integration tests**

```bash
cd /home/am/Work/cdn-harden/test-harness
make integration
```

Expected: All integration tests pass. Watch for:
- APISIX starts successfully with the new plugin structure
- TLS rate limiting works (handshakes rejected after flooding)
- Metrics appear on APISIX prometheus endpoint
- Healthz endpoint still works

- [ ] **Step 3: Fix any issues found**

If tests fail, debug and fix. Common issues to watch for:
- Module path resolution: ensure `extra_lua_path` correctly resolves `tls-clienthello-limiter.core` and `tls-clienthello-limiter.adapters.apisix`
- APISIX plugin shim: ensure `apisix/plugins/tls-clienthello-limiter.lua` correctly delegates to the adapter
- Prometheus metrics adapter: the APISIX prometheus exporter API may differ — check if `get_prometheus()` exists or if the prometheus object is accessed differently

- [ ] **Step 4: Final commit if fixes were needed**

```bash
git add -A
git commit -m "fix: resolve test failures from refactor"
```
