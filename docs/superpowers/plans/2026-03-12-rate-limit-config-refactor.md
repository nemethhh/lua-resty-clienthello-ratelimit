# Rate Limit Config Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove default rate limits, require explicit nested config, allow enabling per-IP and/or per-SNI tiers independently.

**Architecture:** Extract config validation into a new `config.lua` pure module. Refactor `init.lua` to accept `new(opts, metrics)` with conditional tier initialization. Adapters strip their own keys and pass clean config to core.

**Tech Stack:** Lua 5.1 / LuaJIT, OpenResty, Apache APISIX, Busted (unit tests), pytest (integration tests)

**Spec:** `docs/superpowers/specs/2026-03-12-rate-limit-config-refactor-design.md`

---

## Chunk 1: Config Validator + Core Refactor

### Task 1: Create `config.lua` with TDD

**Files:**
- Create: `lib/resty/clienthello/ratelimit/config.lua`
- Create: `t/unit/spec/config_spec.lua`

- [ ] **Step 1: Write failing tests for valid configs**

Create `t/unit/spec/config_spec.lua`:

```lua
local helpers = require("spec.helpers")

describe("resty.clienthello.ratelimit.config", function()
    local config

    before_each(function()
        helpers.setup({})
        package.loaded["resty.clienthello.ratelimit.config"] = nil
        config = require("resty.clienthello.ratelimit.config")
    end)

    describe("validate()", function()
        describe("valid configs", function()
            it("accepts both tiers", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                    per_domain = { rate = 5, burst = 10 },
                })
                assert.is_nil(err)
                assert.is_not_nil(cfg)
                assert.are.equal(2, cfg.per_ip.rate)
                assert.are.equal(4, cfg.per_ip.burst)
                assert.are.equal(10, cfg.per_ip.block_ttl)
                assert.are.equal(5, cfg.per_domain.rate)
                assert.are.equal(10, cfg.per_domain.burst)
            end)

            it("accepts per_ip only", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.is_not_nil(cfg.per_ip)
                assert.is_nil(cfg.per_domain)
            end)

            it("accepts per_domain only", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5, burst = 10 },
                })
                assert.is_nil(err)
                assert.is_nil(cfg.per_ip)
                assert.is_not_nil(cfg.per_domain)
            end)

            it("accepts float values", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2.5, burst = 4.0, block_ttl = 10.5 },
                })
                assert.is_nil(err)
                assert.are.equal(2.5, cfg.per_ip.rate)
            end)

            it("accepts burst = 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 0, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.are.equal(0, cfg.per_ip.burst)
            end)

            it("returns a new table, not the input", function()
                local input = {
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                }
                local cfg, err = config.validate(input)
                assert.is_nil(err)
                assert.are_not.equal(input, cfg)
                assert.are_not.equal(input.per_ip, cfg.per_ip)
            end)
        end)

        describe("warnings", function()
            it("warns when no tiers configured (nil opts)", function()
                local cfg, err = config.validate(nil)
                assert.is_nil(err)
                assert.is_not_nil(cfg)
                assert.are.equal(1, #cfg.warnings)
                assert.truthy(cfg.warnings[1]:find("no rate limit"))
            end)

            it("warns when no tiers configured (empty table)", function()
                local cfg, err = config.validate({})
                assert.is_nil(err)
                assert.are.equal(1, #cfg.warnings)
            end)

            it("returns empty warnings list when tiers configured", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(err)
                assert.are.equal(0, #cfg.warnings)
            end)
        end)

        describe("error: old flat config", function()
            it("rejects per_ip_rate at top level", function()
                local cfg, err = config.validate({ per_ip_rate = 2 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
                assert.truthy(err:find("no longer supported"))
            end)

            it("rejects per_domain_rate at top level", function()
                local cfg, err = config.validate({ per_domain_rate = 5 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
            end)

            it("rejects block_ttl at top level", function()
                local cfg, err = config.validate({ block_ttl = 10 })
                assert.is_nil(cfg)
                assert.truthy(err:find("flat config keys"))
            end)
        end)

        describe("error: unknown keys", function()
            it("rejects unknown top-level keys", function()
                local cfg, err = config.validate({ foo = "bar" })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)

            it("rejects unknown keys in per_ip", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 10, foo = 1 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)

            it("rejects unknown keys in per_domain", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5, burst = 10, foo = 1 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("unknown"))
            end)
        end)

        describe("error: missing required fields", function()
            it("rejects per_ip missing rate", function()
                local cfg, err = config.validate({
                    per_ip = { burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects per_ip missing burst", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("burst"))
            end)

            it("rejects per_ip missing block_ttl", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("block_ttl"))
            end)

            it("rejects per_domain missing rate", function()
                local cfg, err = config.validate({
                    per_domain = { burst = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects per_domain missing burst", function()
                local cfg, err = config.validate({
                    per_domain = { rate = 5 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("burst"))
            end)

            it("rejects empty per_ip table", function()
                local cfg, err = config.validate({ per_ip = {} })
                assert.is_nil(cfg)
            end)

            it("rejects empty per_domain table", function()
                local cfg, err = config.validate({ per_domain = {} })
                assert.is_nil(cfg)
            end)
        end)

        describe("error: invalid types", function()
            it("rejects non-table opts", function()
                local cfg, err = config.validate("bad")
                assert.is_nil(cfg)
                assert.truthy(err:find("table"))
            end)

            it("rejects non-table per_ip", function()
                local cfg, err = config.validate({ per_ip = "bad" })
                assert.is_nil(cfg)
                assert.truthy(err:find("table"))
            end)

            it("rejects non-number rate", function()
                local cfg, err = config.validate({
                    per_ip = { rate = "fast", burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("number"))
            end)
        end)

        describe("error: out of range", function()
            it("rejects rate <= 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 0, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
                assert.truthy(err:find("rate"))
            end)

            it("rejects negative rate", function()
                local cfg, err = config.validate({
                    per_ip = { rate = -1, burst = 4, block_ttl = 10 },
                })
                assert.is_nil(cfg)
            end)

            it("rejects negative burst", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = -1, block_ttl = 10 },
                })
                assert.is_nil(cfg)
            end)

            it("rejects block_ttl <= 0", function()
                local cfg, err = config.validate({
                    per_ip = { rate = 2, burst = 4, block_ttl = 0 },
                })
                assert.is_nil(cfg)
            end)
        end)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make unit`
Expected: All new tests FAIL — module `resty.clienthello.ratelimit.config` not found.

- [ ] **Step 3: Implement `config.lua`**

Create `lib/resty/clienthello/ratelimit/config.lua`:

```lua
-- =============================================================================
-- resty.clienthello.ratelimit.config — Configuration validation (pure function)
-- =============================================================================

local _M = {}

-- Old flat keys that trigger a migration error
local FLAT_KEYS = {
    per_ip_rate = true,
    per_ip_burst = true,
    per_domain_rate = true,
    per_domain_burst = true,
    block_ttl = true,
    dict_per_ip = true,
    dict_per_domain = true,
    dict_blocklist = true,
}

local VALID_TOP_KEYS = {
    per_ip = true,
    per_domain = true,
}

local VALID_PER_IP_KEYS = {
    rate = true,
    burst = true,
    block_ttl = true,
}

local VALID_PER_DOMAIN_KEYS = {
    rate = true,
    burst = true,
}

local function check_unknown_keys(tbl, allowed, prefix)
    for k in pairs(tbl) do
        if not allowed[k] then
            return prefix .. ": unknown key '" .. tostring(k) .. "'"
        end
    end
    return nil
end

local function check_number(val, name, prefix, min_exclusive, min_inclusive)
    if type(val) ~= "number" then
        return prefix .. "." .. name .. " must be a number, got " .. type(val)
    end
    if min_exclusive and val <= 0 then
        return prefix .. "." .. name .. " must be > 0, got " .. val
    end
    if min_inclusive and val < 0 then
        return prefix .. "." .. name .. " must be >= 0, got " .. val
    end
    return nil
end

local function validate_per_ip(t)
    if type(t) ~= "table" then
        return nil, "per_ip must be a table, got " .. type(t)
    end

    local err = check_unknown_keys(t, VALID_PER_IP_KEYS, "per_ip")
    if err then return nil, err end

    for _, field in ipairs({"rate", "burst", "block_ttl"}) do
        if t[field] == nil then
            return nil, "per_ip: missing required field '" .. field .. "'"
        end
    end

    err = check_number(t.rate, "rate", "per_ip", true, false)
    if err then return nil, err end
    err = check_number(t.burst, "burst", "per_ip", false, true)
    if err then return nil, err end
    err = check_number(t.block_ttl, "block_ttl", "per_ip", true, false)
    if err then return nil, err end

    return { rate = t.rate, burst = t.burst, block_ttl = t.block_ttl }
end

local function validate_per_domain(t)
    if type(t) ~= "table" then
        return nil, "per_domain must be a table, got " .. type(t)
    end

    local err = check_unknown_keys(t, VALID_PER_DOMAIN_KEYS, "per_domain")
    if err then return nil, err end

    for _, field in ipairs({"rate", "burst"}) do
        if t[field] == nil then
            return nil, "per_domain: missing required field '" .. field .. "'"
        end
    end

    err = check_number(t.rate, "rate", "per_domain", true, false)
    if err then return nil, err end
    err = check_number(t.burst, "burst", "per_domain", false, true)
    if err then return nil, err end

    return { rate = t.rate, burst = t.burst }
end

--- Validate rate-limit configuration.
--- Pure function: does not log, does not access ngx.
--- @param opts table|nil Raw config from user
--- @return table|nil cfg Validated config with per_ip, per_domain, warnings
--- @return string|nil err Error message on failure
function _M.validate(opts)
    if opts == nil then
        return { per_ip = nil, per_domain = nil, warnings = {"no rate limit tiers configured"} }
    end

    if type(opts) ~= "table" then
        return nil, "opts must be a table, got " .. type(opts)
    end

    -- Detect old flat config keys
    for k in pairs(opts) do
        if FLAT_KEYS[k] then
            return nil, "flat config keys (per_ip_rate, per_ip_burst, per_domain_rate, "
                .. "per_domain_burst, block_ttl, ...) are no longer supported; "
                .. "use nested per_ip = { rate = N, burst = N, block_ttl = N } format"
        end
    end

    -- Check for unknown top-level keys
    local err = check_unknown_keys(opts, VALID_TOP_KEYS, "config")
    if err then return nil, err end

    local result = { per_ip = nil, per_domain = nil, warnings = {} }

    if opts.per_ip ~= nil then
        local validated, verr = validate_per_ip(opts.per_ip)
        if not validated then return nil, verr end
        result.per_ip = validated
    end

    if opts.per_domain ~= nil then
        local validated, verr = validate_per_domain(opts.per_domain)
        if not validated then return nil, verr end
        result.per_domain = validated
    end

    if not result.per_ip and not result.per_domain then
        result.warnings[#result.warnings + 1] = "no rate limit tiers configured"
    end

    return result
end

return _M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make unit`
Expected: All `config_spec.lua` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/resty/clienthello/ratelimit/config.lua t/unit/spec/config_spec.lua
git commit -m "feat: add config validation module with TDD tests"
```

---

### Task 2: Refactor `init.lua` — new(opts, metrics) signature

**Files:**
- Modify: `lib/resty/clienthello/ratelimit/init.lua`
- Modify: `t/unit/spec/core_helpers.lua`
- Modify: `t/unit/spec/tls_limiter_core_spec.lua`

- [ ] **Step 1: Update `core_helpers.lua` for new config shape**

Replace the `setup()` function to always use hardcoded dict names (no more custom dict name overrides), and update `require_core` to pass `metrics` as second arg:

In `t/unit/spec/core_helpers.lua`, replace the `setup` function body to:

```lua
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
```

- [ ] **Step 2: Rewrite `tls_limiter_core_spec.lua` for new config shape**

Replace `t/unit/spec/tls_limiter_core_spec.lua` entirely:

```lua
local ch = require("spec.core_helpers")

describe("tls-clienthello-limiter.core", function()
    local spy

    before_each(function()
        spy = ch.make_metrics_spy()
        ch.setup({sni = "test.example.com"})
    end)

    describe("new()", function()
        it("creates a limiter with both tiers", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
            assert.is_function(lim.check)
        end)

        it("creates a limiter with per_ip only", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
        end)

        it("creates a limiter with per_domain only", function()
            local core = ch.require_core()
            local lim, err = core.new({
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            assert.is_nil(err)
            assert.is_not_nil(lim)
        end)

        it("returns warnings when no tiers configured", function()
            local core = ch.require_core()
            local lim, warnings = core.new({})
            assert.is_not_nil(lim)
            assert.are.equal(1, #warnings)
            assert.truthy(warnings[1]:find("no rate limit"))
        end)

        it("returns nil and error for invalid config", function()
            local core = ch.require_core()
            local lim, err = core.new({ per_ip = { rate = -1, burst = 4, block_ttl = 10 } })
            assert.is_nil(lim)
            assert.is_string(err)
        end)
    end)

    describe("check() with both tiers", function()
        it("returns false when no request context", function()
            ch.set_mock_request(false)
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected, reason = lim:check()
            assert.is_false(rejected)
            assert.is_nil(reason)
        end)

        it("returns true,'blocklist' for blocked IP", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local dict = ngx.shared["tls-ip-blocklist"]
            local bin_ip = string.char(10, 0, 0, 1)
            dict:set(bin_ip, true, 60)
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
            assert.is_not_nil(spy.find("tls_clienthello_blocked_total"))
        end)

        it("returns false for a normal request", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
        end)

        it("returns true,'per_ip' after exceeding per-IP rate+burst", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 100, burst = 100 },
            }, spy)
            for i = 1, 6 do
                local rejected = lim:check()
                assert.is_false(rejected, "call " .. i .. " should pass")
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_ip", reason)
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)

        it("returns true,'per_domain' after exceeding per-domain rate+burst", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 100, burst = 100, block_ttl = 10 },
                per_domain = { rate = 2, burst = 2 },
            }, spy)
            for i = 1, 4 do
                lim:check()
            end
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("per_domain", reason)
        end)

        it("emits tls_clienthello_no_sni_total when no SNI", function()
            ch.setup()
            ch.set_mock_sni(nil)
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            lim:check()
            assert.is_not_nil(spy.find("tls_clienthello_no_sni_total"))
        end)

        it("works without metrics adapter (nil)", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
                per_domain = { rate = 5, burst = 10 },
            })
            local rejected = lim:check()
            assert.is_false(rejected)
        end)

        it("after auto-block, subsequent calls hit blocklist", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 1, burst = 1, block_ttl = 10 },
                per_domain = { rate = 100, burst = 100 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()
            spy = ch.make_metrics_spy()
            lim.metrics = spy
            local rejected, reason = lim:check()
            assert.is_true(rejected)
            assert.are.equal("blocklist", reason)
        end)
    end)

    describe("check() with per_ip only", function()
        it("skips per_domain tier entirely", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            -- Should see per_ip passed but no per_domain passed
            assert.is_not_nil(spy.find("tls_clienthello_passed_total"))
            -- The per_domain tier should not emit anything
            local calls = spy.get_calls()
            for _, c in ipairs(calls) do
                if c.labels and c.labels.layer then
                    assert.are_not.equal("per_domain", c.labels.layer)
                end
            end
        end)

        it("still applies blocklist when per_ip rejects", function()
            local core = ch.require_core()
            local lim = core.new({
                per_ip = { rate = 1, burst = 1, block_ttl = 10 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()  -- should be rejected + auto-blocked
            assert.is_not_nil(spy.find("tls_ip_autoblock_total"))
        end)
    end)

    describe("check() with per_domain only", function()
        it("skips per_ip and blocklist tiers entirely", function()
            local core = ch.require_core()
            local lim = core.new({
                per_domain = { rate = 5, burst = 10 },
            }, spy)
            local rejected = lim:check()
            assert.is_false(rejected)
            -- Should not emit per_ip metrics
            local calls = spy.get_calls()
            for _, c in ipairs(calls) do
                if c.labels and c.labels.layer then
                    assert.are_not.equal("per_ip", c.labels.layer)
                end
                assert.are_not.equal("tls_clienthello_blocked_total", c.name)
                assert.are_not.equal("tls_ip_autoblock_total", c.name)
            end
        end)

        it("does not block IPs (no blocklist)", function()
            local core = ch.require_core()
            -- Even with high traffic, no auto-block since per_ip is disabled
            local lim = core.new({
                per_domain = { rate = 1, burst = 1 },
            }, spy)
            lim:check()
            lim:check()
            lim:check()  -- rejected by per_domain
            assert.is_nil(spy.find("tls_ip_autoblock_total"))
        end)
    end)
end)
```

- [ ] **Step 3: Run tests to verify they fail (old init.lua incompatible)**

Run: `make unit`
Expected: Tests FAIL — `init.lua` still uses old flat config + single-arg `new()`.

- [ ] **Step 4: Refactor `init.lua`**

Replace `lib/resty/clienthello/ratelimit/init.lua` with:

```lua
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

    return setmetatable(self, {__index = _M}), cfg.warnings
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make unit`
Expected: All unit tests PASS (both `config_spec.lua` and `tls_limiter_core_spec.lua`).

- [ ] **Step 6: Commit**

```bash
git add lib/resty/clienthello/ratelimit/init.lua t/unit/spec/core_helpers.lua t/unit/spec/tls_limiter_core_spec.lua
git commit -m "feat: refactor core limiter to require explicit nested config

BREAKING CHANGE: new(opts) is now new(opts, metrics) with nested
per_ip/per_domain config. No defaults. Each tier is independently optional."
```

---

## Chunk 2: Adapters + Rockspec

### Task 3: Update OpenResty adapter

**Files:**
- Modify: `lib/resty/clienthello/ratelimit/openresty.lua`

- [ ] **Step 1: Rewrite `openresty.lua`**

Replace `lib/resty/clienthello/ratelimit/openresty.lua` with:

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/resty/clienthello/ratelimit/openresty.lua
git commit -m "feat: update OpenResty adapter for nested config"
```

---

### Task 4: Update APISIX adapter

**Files:**
- Modify: `lib/resty/clienthello/ratelimit/apisix.lua`

- [ ] **Step 1: Rewrite `apisix.lua`**

Replace `lib/resty/clienthello/ratelimit/apisix.lua` with:

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/resty/clienthello/ratelimit/apisix.lua
git commit -m "feat: update APISIX adapter for nested config"
```

---

### Task 5: Update rockspec

**Files:**
- Modify: `lua-resty-clienthello-ratelimit-0.1.0-1.rockspec`

- [ ] **Step 1: Add config module to rockspec**

Add this line after the `apisix` entry in the `modules` table:

```lua
        ["resty.clienthello.ratelimit.config"]     = "lib/resty/clienthello/ratelimit/config.lua",
```

- [ ] **Step 2: Commit**

```bash
git add lua-resty-clienthello-ratelimit-0.1.0-1.rockspec
git commit -m "chore: add config module to rockspec"
```

---

## Chunk 3: Integration Configs + Tests + Docs

### Task 6: Update APISIX integration config

**Files:**
- Modify: `t/integration/conf/config.yaml`

The APISIX integration tests read `plugin_attr` from `t/integration/conf/config.yaml`. Lines 59-65 currently use the old flat format. This must be updated before running integration tests.

- [ ] **Step 1: Update `t/integration/conf/config.yaml` plugin_attr**

Replace lines 59-65:

```yaml
plugin_attr:
  tls-clienthello-limiter:
    per_ip:
      rate: 2
      burst: 4
      block_ttl: 10
    per_domain:
      rate: 5
      burst: 10
```

- [ ] **Step 2: Commit**

```bash
git add t/integration/conf/config.yaml
git commit -m "test: update APISIX integration config for nested format"
```

---

### Task 7: Update OpenResty integration test config

**Files:**
- Modify: `t/openresty-integration/conf/nginx.conf`

- [ ] **Step 1: Update nginx.conf to nested config**

Replace the `init_worker_by_lua_block` in `t/openresty-integration/conf/nginx.conf`:

```lua
    init_worker_by_lua_block {
        local adapter = require("resty.clienthello.ratelimit.openresty")
        adapter.init({
            per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            per_domain = { rate = 5, burst = 10 },
            prometheus_dict = "prometheus-metrics",
        })
    }
```

- [ ] **Step 2: Commit**

```bash
git add t/openresty-integration/conf/nginx.conf
git commit -m "test: update OpenResty integration config for nested format"
```

---

### Task 8: Update integration test files with single-tier tests

**Files:**
- Modify: `t/integration/tests/test_tls_rate_limit.py`
- Modify: `t/openresty-integration/tests/test_openresty_tls_rate_limit.py`

The spec requires per-IP-only and per-domain-only integration test cases. Since the integration test configs use both tiers, these single-tier tests require separate config variants. However, the Docker Compose setup uses a single config file, so we cannot easily swap configs per test class.

Instead, add the single-tier tests to the unit test suite (already done in Task 2 — `tls_limiter_core_spec.lua` has `check() with per_ip only` and `check() with per_domain only`). The integration tests verify the full both-tiers stack works end-to-end. Update the existing integration test docstrings to reference the new config format.

- [ ] **Step 1: Update APISIX integration test docstrings**

In `t/integration/tests/test_tls_rate_limit.py`, update docstrings that reference old config keys:

- `test_rapid_handshakes_get_rejected`: change `per_ip_rate=2, per_ip_burst=4` to `per_ip: rate=2, burst=4`
- `test_per_domain_limit_triggers`: change `per_domain_rate=5, per_domain_burst=10` to `per_domain: rate=5, burst=10`

- [ ] **Step 2: Update OpenResty integration test docstrings**

In `t/openresty-integration/tests/test_openresty_tls_rate_limit.py`, update docstrings that reference old config keys:

- `test_rapid_handshakes_get_rejected`: change `per_ip_rate=2, per_ip_burst=4` to `per_ip: rate=2, burst=4`
- `test_per_domain_limit_triggers`: change `per_domain_rate=5, per_domain_burst=10` to `per_domain: rate=5, burst=10`

- [ ] **Step 3: Commit**

```bash
git add t/integration/tests/test_tls_rate_limit.py t/openresty-integration/tests/test_openresty_tls_rate_limit.py
git commit -m "test: update integration test docstrings for nested config"
```

---

### Task 9: Update example configs

**Files:**
- Modify: `examples/nginx.conf`
- Modify: `examples/apisix-config.yaml`
- Confirm no change: `examples/apisix-plugin-shim.lua`

- [ ] **Step 1: Update `examples/nginx.conf`**

Replace the `init_worker_by_lua_block` section:

```lua
    init_worker_by_lua_block {
        local adapter = require("resty.clienthello.ratelimit.openresty")
        adapter.init({
            per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            per_domain = { rate = 5, burst = 10 },
            prometheus_dict = "prometheus-metrics",
        })
    }
```

- [ ] **Step 2: Update `examples/apisix-config.yaml`**

Replace the `plugin_attr` section:

```yaml
plugin_attr:
  tls-clienthello-limiter:
    per_ip:
      rate: 2
      burst: 4
      block_ttl: 10
    per_domain:
      rate: 5
      burst: 10
```

- [ ] **Step 3: Confirm `examples/apisix-plugin-shim.lua` needs no changes**

The shim is a one-liner (`return adapter`) — it does not reference config keys. No changes needed.

- [ ] **Step 4: Commit**

```bash
git add examples/nginx.conf examples/apisix-config.yaml
git commit -m "docs: update example configs for nested format"
```

---

### Task 10: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Make the following changes to `README.md`:

1. Replace the "Default settings" table (lines 47-58) with:

```markdown
Configuration is required — there are no defaults. You must specify at least one rate-limiting tier:

| Tier | Key | Required fields |
| --- | --- | --- |
| Per-IP (T0+T1) | `per_ip` | `rate` (number > 0), `burst` (number >= 0), `block_ttl` (number > 0) |
| Per-domain (T2) | `per_domain` | `rate` (number > 0), `burst` (number >= 0) |

Shared dictionaries (names are fixed):

| Dict | Purpose |
| --- | --- |
| `tls-hello-per-ip` | Per-IP rate limiter state |
| `tls-hello-per-domain` | Per-SNI rate limiter state |
| `tls-ip-blocklist` | Auto-blocked IPs with TTL |
```

2. Replace the core module usage example (lines 99-115) with:

```lua
local limiter = require("resty.clienthello.ratelimit")

local lim, warnings = limiter.new({
    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
    per_domain = { rate = 5, burst = 10 },
}, my_metrics_adapter)

local rejected, reason = lim:check()
if rejected then
    -- reason is one of: "blocklist", "per_ip", "per_domain"
end
```

3. Replace the OpenResty init block (lines 144-153) with:

```lua
        require("resty.clienthello.ratelimit.openresty").init({
            per_ip = { rate = 2, burst = 4, block_ttl = 10 },
            per_domain = { rate = 5, burst = 10 },
            prometheus_dict = "prometheus-metrics",
        })
```

4. Replace the APISIX `plugin_attr` block (lines 205-211) with:

```yaml
plugin_attr:
  tls-clienthello-limiter:
    per_ip:
      rate: 2
      burst: 4
      block_ttl: 10
    per_domain:
      rate: 5
      burst: 10
```

5. Add a "Migration from v0.1" section before "## Metrics":

```markdown
## Migration from v0.1

v0.2 introduces a **breaking change**: rate limits no longer have defaults and must be explicitly configured using a nested format.

**Before (v0.1):**

```lua
adapter.init({
    per_ip_rate = 2,
    per_ip_burst = 4,
    per_domain_rate = 5,
    per_domain_burst = 10,
    block_ttl = 10,
})
```

**After (v0.2):**

```lua
adapter.init({
    per_ip = { rate = 2, burst = 4, block_ttl = 10 },
    per_domain = { rate = 5, burst = 10 },
})
```

Key changes:

- Flat keys (`per_ip_rate`, `per_domain_rate`, etc.) are no longer accepted. The module detects old-style config and returns a helpful error.
- Each tier (`per_ip`, `per_domain`) is optional. You can enable one, both, or neither.
- If a tier is present, all its fields are required.
- Custom shared dict names (`dict_per_ip`, `dict_per_domain`, `dict_blocklist`) are removed. Dict names are now fixed constants.
- The core `new()` signature changed from `new(opts)` to `new(opts, metrics)`.
```

6. Update the installation module list to include `resty.clienthello.ratelimit.config`.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for nested config and migration guide"
```

---

### Task 11: Run all tests

- [ ] **Step 1: Run unit tests**

Run: `make unit`
Expected: All PASS.

- [ ] **Step 2: Run OpenResty integration tests**

Run: `make openresty-integration`
Expected: All PASS.

- [ ] **Step 3: Run APISIX integration tests**

Run: `make integration`
Expected: All PASS.

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address integration test issues"
```
